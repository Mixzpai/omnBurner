## Windows: an installer stick built from a Windows ISO's files.
##
## Windows ISOs aren't hybrid images: copied byte for byte, they don't boot
## from USB. So each stick gets one FAT32 partition holding the ISO's files,
## which UEFI PCs boot (Secure Boot included). FAT32 can't hold a file of
## 4 GiB or more, so a big install.wim is split into install.swm parts with
## wimlib, the way Microsoft's instructions for USB installers do with DISM.

import std/[monotimes, os, osproc, posix, streams, strutils, times]
import ../[device, logging, tools]
import lowlevel, protocol

const
  FatMaxFile = 4294967295'i64
  SwmPartMiB = 3800
  CopyChunk = 4 shl 20
  SyncEvery = 64 shl 20 ## flush this often, so progress is what's on the stick

type
  WinStick = object
    dest, part, mnt: string
    fd: cint
    mounted, failed: bool
    done, checked: int64

proc isInstallImage(rel: string): bool =
  rel.toLowerAscii.replace('\\', '/') in ["sources/install.wim", "sources/install.esd"]

proc lastPercent(s: string): int =
  ## The last "NN%" in a line of wimlib's progress output, or -1.
  result = -1
  var i = s.find('%')
  while i >= 0:
    var j = i
    while j > 0 and s[j - 1] in Digits: dec j
    if j < i: result = parseInt(s[j ..< i])
    i = s.find('%', i + 1)

proc runWimlib(args: openArray[string], onPercent: proc (pct: int)) =
  ## Runs wimlib-imagex, passing on its progress. Raises on failure.
  info("Running wimlib-imagex " & args.join(" "))
  let p = startProcess(findTool("wimlib-imagex"), args = args, options = {poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream
  var line, last: string
  while true:
    let c = try: output.readChar() except IOError: '\0'
    if c == '\0' and output.atEnd: break
    if c in {'\r', '\n'}:
      if line.strip.len > 0: last = line.strip
      let pct = lastPercent(line)
      if pct >= 0: onPercent(min(pct, 100))
      line.setLen(0)
    else: line.add c
  if line.strip.len > 0: last = line.strip
  let code = p.waitForExit()
  if code != 0:
    raise wvError(ekCommand, ikUnknown, "wimlib-imagex " & args[0] & " failed: " &
                  (if last.len > 0: last else: "exit code " & $code))

proc mountFs(src, dir: string, types: openArray[string], opts: string): string {.discardable.} =
  ## Mounts with the first filesystem type that works, and returns that type.
  var why = ""
  for t in types:
    try:
      discard runTool(["mount", "-t", t, "-o", opts, src, dir])
      return t
    except WVError as e: why = e.raw
  raise wvError(ekCommand, ikUnknown, why)

proc unmountDir(dir: string) =
  try: discard runTool(["umount", dir])
  except WVError:
    warn("Lazily unmounting " & dir)
    discard execCmdEx(quoteShellCommand(["umount", "--lazy", dir]))

# ---------------------------------------------------------------------------
# Making the sticks, one phase at a time

type
  WinJob = ref object
    ## What the phases share. A ref, so every phase updates the same sticks.
    a: Action
    emit: Emit
    work, isoDir: string
    isoMounted: bool
    sticks: seq[WinStick]
    buf, buf2: pointer
    dirs, files: seq[string] ## what goes on the stick, relative to the ISO
    total: int64
    split: string            ## an install image too big for FAT32, or ""
    splitSize: int64
    swm: string              ## the name its parts get on the stick
    steps: int
    read: int64              ## bytes copied so far

proc emitBytes(j: WinJob, read: int64, verifying: bool) =
  var line = "bytes " & $read
  for s in j.sticks: line.add " " & $(if verifying: s.checked else: s.done)
  j.emit(line)

proc failStick(j: WinJob, i: int, e: ref WVError) =
  if j.sticks[i].failed: return
  j.sticks[i].failed = true
  if j.sticks[i].fd >= 0:
    discard posix.close(j.sticks[i].fd)
    j.sticks[i].fd = -1
  warn(j.sticks[i].dest & " failed: " & e.msg & " (" & e.raw & ")")
  j.emit("fail " & $i & " " & $e.kind & " " & $e.io & " " & e.raw)

proc active(j: WinJob): int =
  for s in j.sticks:
    if not s.failed: inc result

proc checkWindows(a: Action) =
  ## Refuses before anything is touched.
  if a.targets.len == 0 or a.targets.len > MaxTargets:
    raise wvError(ekUnknown, ikUnknown, "between 1 and " & $MaxTargets & " targets are supported")
  if posix.access(a.src.cstring, R_OK) != 0: raise osError(ekInputFile, "opening " & a.src)
  for t in a.targets:
    if t.targetType != ttDisk:
      raise wvError(ekRefused, ikUnknown, t.dest & " isn't a whole disk, which a Windows stick needs")
    if fromPath(t.dest).system and not a.allowSystem:
      raise wvError(ekRefused, ikUnknown, t.dest & " holds the running system; refusing to overwrite it")
  # Mounting the ISO and the sticks takes root (the parent escalates on this).
  if geteuid() != 0: raise wvError(ekOutputFile, ikPermissionDenied, "making a Windows stick needs root")
  for tool in WindowsTools:
    if tool != "wimlib-imagex" and findTool(tool).len == 0: # only needed for a big install.wim
      raise wvError(ekCommand, ikUnknown, tool & " is not installed. " & installHint([tool]))

proc mountIso(j: WinJob): string =
  ## Mounts the ISO, and returns its filesystem type.
  createDir(j.isoDir)
  # Windows ISOs keep their files in UDF; the ISO 9660 side holds just a
  # README, so a fallback to it is only good for ISOs made some other way.
  var isoFs = ""
  try: isoFs = mountFs(j.a.src, j.isoDir, ["udf", "iso9660"], "loop,ro")
  except WVError as e: raise wvError(ekInputFile, ikUnknown, "couldn't open the ISO: " & e.raw)
  j.isoMounted = true
  isoFs

proc planCopy(j: WinJob, isoFs: string) =
  ## What goes on the stick, and whether it boots and fits.
  var uefi = false
  for rel in walkDirRec(j.isoDir, yieldFilter = {pcFile, pcDir}, relative = true):
    let path = j.isoDir / rel
    if dirExists(path):
      j.dirs.add rel
      continue
    let lower = rel.toLowerAscii
    if lower.startsWith("efi/boot/boot") and lower.endsWith(".efi"): uefi = true
    let size = getFileSize(path)
    j.total += size
    if size <= FatMaxFile: j.files.add rel
    elif rel.isInstallImage and j.split.len == 0: j.split = rel
    else: raise wvError(ekInputFile, ikUnknown, rel & " is bigger than 4 GB, too big for FAT32")
  if not uefi:
    if isoFs == "iso9660" and not readsUdf():
      raise wvError(ekCommand, ikUnknown, "This Linux kernel can't read UDF, the filesystem " &
                    "Windows ISOs keep their files in.")
    raise wvError(ekRefused, ikUnknown, "This ISO has no UEFI boot loader (efi/boot/bootx64.efi), " &
                  "so a stick made from it wouldn't start.")
  j.splitSize = if j.split.len > 0: getFileSize(j.isoDir / j.split) else: 0
  j.swm = j.split.changeFileExt("swm")
  if j.split.len > 0 and findTool("wimlib-imagex").len == 0:
    raise wvError(ekCommand, ikUnknown, "wimlib-imagex is needed to split " & j.split.extractFilename &
                  " (bigger than 4 GB) for FAT32, and it isn't installed. " &
                  installHint(["wimlib-imagex"]))
  let need = j.total + j.total div 50 + (64 shl 20) # FAT32's own overhead, roughly
  for t in j.a.targets:
    let size = fromPath(t.dest).size
    if size > 0 and size < need:
      raise wvError(ekRefused, ikUnknown, t.dest & " is too small: the Windows files need " &
                    formatFloat(float(need) / 1e9, ffDecimal, 1) & " GB")
  info("Windows stick: " & $j.files.len & " files, " & $j.total & " bytes" &
       (if j.split.len > 0: ", splitting " & j.split else: ""))

proc prepareSticks(j: WinJob) =
  ## Step 1: one fresh FAT32 partition per stick, mounted, with the ISO's folders.
  j.emit("step 1 " & $j.steps & " Preparing the drive")
  for i in 0 ..< j.sticks.len:
    let label = j.a.label[0 ..< min(j.a.label.len, 11)].toUpperAscii
    try:
      let (ok, msg) = unmountAll(fromPath(j.sticks[i].dest))
      if not ok: raise wvError(ekOutputFile, ikBusy, msg)
      discard runTool(["wipefs", "--all", "--force", j.sticks[i].dest])
      discard runTool(["sfdisk", "--wipe", "always", "--wipe-partitions", "always", j.sticks[i].dest],
                      "label: dos\n,,c,*\n")
      j.sticks[i].part = waitForPartition(j.sticks[i].dest)
      discard runTool(["mkfs.fat", "-F", "32", "-n", (if label.len > 0: label else: "WINDOWS"),
                       j.sticks[i].part])
      createDir(j.sticks[i].mnt)
      mountFs(j.sticks[i].part, j.sticks[i].mnt, ["vfat"], "rw")
      j.sticks[i].mounted = true
      for d in j.dirs: createDir(j.sticks[i].mnt / d)
    except WVError as e: j.failStick(i, e)
    except OSError as e: j.failStick(i, wvError(ekOutputFile, ikUnknown, e.msg))

proc copyFiles(j: WinJob) =
  ## Step 2: every file that fits FAT32, onto all the sticks at once.
  j.emit("step 2 " & $j.steps & " Copying files")
  j.buf = alignedAlloc(CopyChunk, 4096)
  j.buf2 = alignedAlloc(CopyChunk, 4096)
  var last = getMonoTime()
  var budget = MaxData
  for rel in j.files:
    let src = posix.open((j.isoDir / rel).cstring, O_RDONLY or O_CLOEXEC)
    if src < 0: raise osError(ekInputFile, "reading " & rel)
    for i in 0 ..< j.sticks.len:
      if j.sticks[i].failed: continue
      j.sticks[i].fd = posix.open((j.sticks[i].mnt / rel).cstring,
                                  O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o644)
      if j.sticks[i].fd < 0: j.failStick(i, osError(ekOutputFile, "creating " & rel))
    var unsynced = 0
    while true:
      let n = readAll(src, j.buf, CopyChunk)
      if n < 0:
        discard posix.close(src)
        raise wvError(ekInputFile, ioKindOf(cint(-n)), osErrorText("reading " & rel, cint(-n)))
      if n == 0: break
      unsynced += n
      for i in 0 ..< j.sticks.len:
        if j.sticks[i].failed: continue
        var err = writeAll(j.sticks[i].fd, j.buf, n)
        if err == 0 and unsynced >= SyncEvery and fdatasync(j.sticks[i].fd) != 0: err = errno
        if err != 0: j.failStick(i, osError(ekOutputFile, "writing " & rel, err))
        else: j.sticks[i].done += n
      if unsynced >= SyncEvery: unsynced = 0
      emitData(j.emit, j.read, j.buf, n, budget)
      j.read += n
      if (getMonoTime() - last).inMilliseconds >= ReportMs:
        j.emitBytes(j.read, false)
        last = getMonoTime()
        budget = MaxData
      if n < CopyChunk: break
    discard posix.close(src)
    for i in 0 ..< j.sticks.len:
      if j.sticks[i].failed: continue
      if fdatasync(j.sticks[i].fd) != 0 or posix.close(j.sticks[i].fd) != 0:
        j.failStick(i, osError(ekOutputFile, "writing " & rel))
      j.sticks[i].fd = -1
    if j.active() == 0: break
  j.emitBytes(j.read, false)

proc splitInstallImage(j: WinJob) =
  ## Step 3: the install image that's too big for FAT32, split into parts.
  j.emit("step 3 " & $j.steps & " Splitting " & j.split.extractFilename & " for FAT32")
  for i in 0 ..< j.sticks.len:
    if j.sticks[i].failed: continue
    let base = j.sticks[i].done
    try:
      runWimlib(["split", j.isoDir / j.split, j.sticks[i].mnt / j.swm, $SwmPartMiB]) do (pct: int):
        j.sticks[i].done = base + j.splitSize * pct div 100
        j.emitBytes(j.read + j.splitSize * pct div 100, false)
      discard runTool(["sync", "--file-system", j.sticks[i].mnt])
      j.sticks[i].done = base + j.splitSize
    except WVError as e: j.failStick(i, e)
  j.read += j.splitSize
  j.emitBytes(j.read, false)

proc verifySticks(j: WinJob) =
  ## Reads every file back from the sticks and compares it with the ISO's.
  j.emit("step " & $j.steps & " " & $j.steps & " Verifying")
  j.emit("phase verify")
  # Unmount and drop the stick's cached blocks, so what's read back comes
  # from the stick itself.
  for i in 0 ..< j.sticks.len:
    if j.sticks[i].failed: continue
    try:
      discard runTool(["umount", j.sticks[i].mnt])
      j.sticks[i].mounted = false
      discard runTool(["blockdev", "--flushbufs", j.sticks[i].part])
      mountFs(j.sticks[i].part, j.sticks[i].mnt, ["vfat"], "ro")
      j.sticks[i].mounted = true
    except WVError as e: j.failStick(i, e)
  var checked: int64
  var last = getMonoTime()
  var budget = MaxData
  for rel in j.files:
    if j.active() == 0: break
    let src = posix.open((j.isoDir / rel).cstring, O_RDONLY or O_CLOEXEC)
    if src < 0: raise osError(ekInputFile, "reading " & rel)
    for i in 0 ..< j.sticks.len:
      if j.sticks[i].failed: continue
      j.sticks[i].fd = posix.open((j.sticks[i].mnt / rel).cstring, O_RDONLY or O_CLOEXEC)
      if j.sticks[i].fd < 0: j.failStick(i, osError(ekOutputFile, "reading back " & rel))
    while true:
      let n = readAll(src, j.buf, CopyChunk)
      if n < 0:
        discard posix.close(src)
        raise wvError(ekInputFile, ioKindOf(cint(-n)), osErrorText("reading " & rel, cint(-n)))
      for i in 0 ..< j.sticks.len:
        if j.sticks[i].failed: continue
        let m = readAll(j.sticks[i].fd, j.buf2, CopyChunk)
        if m < 0: j.failStick(i, wvError(ekOutputFile, ioKindOf(cint(-m)), osErrorText("reading back " & rel, cint(-m))))
        elif m != n or (n > 0 and cmpMem(j.buf, j.buf2, n) != 0):
          j.failStick(i, wvError(ekVerificationFailed, ikUnknown, rel & " differs on the drive"))
        else: j.sticks[i].checked += n
      emitData(j.emit, checked, j.buf, n, budget)
      checked += n
      if (getMonoTime() - last).inMilliseconds >= ReportMs:
        j.emitBytes(checked, true)
        last = getMonoTime()
        budget = MaxData
      if n < CopyChunk: break
    discard posix.close(src)
    for i in 0 ..< j.sticks.len:
      if j.sticks[i].fd >= 0:
        discard posix.close(j.sticks[i].fd)
        j.sticks[i].fd = -1
  if j.split.len > 0:
    # The parts can't be compared with install.wim, but wimlib checks
    # every byte in them against the hashes the image stores.
    for i in 0 ..< j.sticks.len:
      if j.sticks[i].failed: continue
      let base = j.sticks[i].checked
      let first = j.sticks[i].mnt / j.swm
      try:
        runWimlib(["verify", first, "--ref=" & first.changeFileExt("") & "*.swm"]) do (pct: int):
          j.sticks[i].checked = base + j.splitSize * pct div 100
          j.emitBytes(checked + j.splitSize * pct div 100, true)
        j.sticks[i].checked = base + j.splitSize
      except WVError as e:
        j.failStick(i, wvError(ekVerificationFailed, ikUnknown,
                               j.swm.extractFilename & " doesn't check out on the drive: " & e.raw))
    checked += j.splitSize
  j.emitBytes(checked, true)

proc finishSticks(j: WinJob) =
  ## Unmounting writes out whatever the sticks still have cached.
  j.emit("step " & $j.steps & " " & $j.steps & " Finishing writing to the drive")
  for i in 0 ..< j.sticks.len:
    if not j.sticks[i].mounted: continue
    try:
      discard runTool(["umount", j.sticks[i].mnt])
      j.sticks[i].mounted = false
    except WVError as e: j.failStick(i, e)

proc cleanup(j: WinJob) =
  ## Frees, unmounts and removes whatever the phases left, however far they got.
  if j.buf != nil: c_free(j.buf)
  if j.buf2 != nil: c_free(j.buf2)
  for s in j.sticks:
    if s.fd >= 0: discard posix.close(s.fd)
    if s.mounted: unmountDir(s.mnt)
    discard posix.rmdir(s.mnt.cstring) # never anything recursive: it may still be mounted
  if j.isoMounted: unmountDir(j.isoDir)
  discard posix.rmdir(j.isoDir.cstring)
  discard posix.rmdir(j.work.cstring)

proc windows*(a: Action, emit: Emit) =
  checkWindows(a)
  let work = getTempDir() / ("omnburn-windows-" & $getpid())
  let j = WinJob(a: a, emit: emit, work: work, isoDir: work / "iso")
  try:
    j.planCopy(j.mountIso())
    emit("start " & $j.total & " " & $j.total & " " & $a.targets.len)
    emit("phase write")
    for i, t in a.targets:
      j.sticks.add WinStick(dest: t.dest, mnt: work / ("stick" & $i), fd: -1)
    j.steps = if j.split.len > 0: 4 else: 3
    j.prepareSticks()
    if j.active() == 0:
      emit("done")
      return
    j.copyFiles()
    if j.split.len > 0 and j.active() > 0: j.splitInstallImage()
    if a.verify and j.active() > 0: j.verifySticks()
    j.finishSticks()
    emit("done")
  finally:
    j.cleanup()
