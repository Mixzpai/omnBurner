## Non-interactive mode (no TTY, or --interactive never): everything comes
## from the command line, and progress is printed as plain lines on stderr.

import std/[monotimes, options, os, posix, strformat, strutils, times]
import byteseries, cli, compression, desktop, device, fetch, hash, herder, image,
       sig, theme, tools, writer

type PlainError* = object of CatchableError

proc fail(msg: string) {.noreturn.} = raise newException(PlainError, msg)

var th*: Theme

proc say*(segs: openArray[(string, Style)]) =
  var s = ""
  for (t, st) in segs: s.add paint(t, st)
  stderr.writeLine s

proc say*(text: string) = say([(text, fgs(th.fg))])

proc note(k, v: string) = say([(k.alignLeft(12), fgs(th.accent)), (v, fgs(th.fg))])

proc progressLine(label: string, ratio: float, extra: string) =
  ## A bar redrawn in place on a terminal, or a line every few seconds.
  let pct = int(clamp(ratio, 0.0, 1.0) * 100)
  if isatty(2) != 0:
    let w = 30
    let filled = int(clamp(ratio, 0.0, 1.0) * float(w))
    stderr.write "\r\e[K" & paint(label.alignLeft(10), fgs(th.accent, bold = true)) & " " &
      paint("█".repeat(filled), fgs(th.yellow)) & paint("░".repeat(w - filled), fgs(th.dim)) &
      &" {pct:>3}%  " & extra
  else:
    stderr.writeLine &"{label} {pct}% {extra}"

proc endProgress() =
  if isatty(2) != 0: stderr.write "\n"

proc download(r: Resolved): Download =
  result = startDownload(r)
  if result.phase == dlFailed: fail("Download failed: " & result.error)
  note("Downloading", r.url)
  var last = getMonoTime() - initDuration(seconds = 10)
  let tty = isatty(2) != 0
  result.runBlocking(proc (d: Download) =
    if tty or (getMonoTime() - last).inSeconds >= 5:
      let ratio = if d.total > 0: float(d.bytesDone) / float(d.total) else: 0.0
      progressLine("Download", ratio, formatBytes(d.bytesDone) & "  " & formatSpeed(d.speed))
      last = getMonoTime())
  endProgress()
  if result.phase == dlFailed: fail("Download failed: " & result.error)
  note("Saved to", result.dest)

proc startOrEscalate(action: Action, targets: seq[WriteTarget], logPath: string,
                     root: UseSudo): (Child, Job) =
  var job = newJob(action.op, targets)
  var child = spawnHerder(logPath)
  if child.start(action, job): return (child, job)
  child.reap()
  if not job.needsRoot: fail($job.error)
  let (found, m) = detectEscalation()
  if not found: fail($job.error & " Couldn't become root: no sudo, doas, run0 or su found.")
  if root != usAlways:
    fail($job.error & " Run again with --root always (or as root) to let omnBurn use " & $m & ".")
  job = newJob(action.op, targets)
  child = spawnHerder(logPath, some(m))
  if child.start(action, job): return (child, job)
  child.reap()
  fail($job.error)

proc follow(child: var Child, job: var Job, onHash: proc (j: var Job): bool) =
  var lastPhase = job.phase
  var last = getMonoTime() - initDuration(seconds = 10)
  let tty = isatty(2) != 0
  while not job.isFinished:
    var pfd = TPollfd(fd: child.outFd, events: POLLIN)
    if poll(addr pfd, 1, 200) > 0:
      if not child.pump(): job.onEof(getMonoTime())
    var line: string
    while child.popLine(line):
      let hadHash = job.fileHash.len > 0
      job.onLine(getMonoTime(), line)
      if line.startsWith("fail "):
        endProgress()
        let i = parseInt(line.split(' ')[1])
        say([("✗ ", fgs(th.red, bold = true)), (job.targets[i].target.name & ": " & $job.targets[i].error, fgs(th.fg))])
      if not hadHash and job.fileHash.len > 0 and onHash != nil and not onHash(job):
        child.reap(kill = true)
        endProgress()
        return
    if job.phase != lastPhase and lastPhase in {phWrite, phVerify}: endProgress()
    lastPhase = job.phase
    if job.isFinished: break
    if not tty and (getMonoTime() - last).inSeconds < 5: continue
    last = getMonoTime()
    let t = job.targets[0]
    case job.phase
    of phWrite:
      if job.op == opFormat:
        progressLine("Restore", job.step / max(job.steps, 1), job.stepText)
      elif job.op == opWindows and job.step < 2:
        progressLine("Preparing", 0.0, job.stepText)
      elif job.op == opWindows:
        progressLine("Copying", job.writeRatio(t), job.stepText & "  " & formatSpeed(t.write.totalAvgSpeed) &
                     "  " & formatEta(job.writeEta))
      else:
        progressLine(if job.op == opBackup: "Backing up" else: "Burning", job.writeRatio(t),
                     formatSpeed(if job.op == opBackup: job.readHist.totalAvgSpeed else: t.write.totalAvgSpeed) &
                     "  " & formatEta(job.writeEta))
    of phVerify:
      progressLine("Verifying", job.verifyRatio(t),
                   formatSpeed(t.verify.totalAvgSpeed) & "  " & formatEta(job.verifyEta))
    else: discard
  endProgress()
  child.reap()

proc summary(job: Job): int =
  if job.ok:
    say([("✓ Done.", fgs(th.green, bold = true))])
    return 0
  if job.phase == phDone:
    say([("⚠ ", fgs(th.yellow, bold = true)), (&"{job.okCount} of {job.targets.len} disks OK.", fgs(th.fg))])
  else:
    say([("✗ ", fgs(th.red, bold = true)), ($job.error, fgs(th.fg))])
  1

proc powerOffAll(targets: seq[WriteTarget]) =
  for t in targets:
    if t.targetType != ttDisk: continue
    let (ok, msg) = powerOff(t)
    if ok: say([("⏏ ", fgs(th.green)), (t.name & " powered off; you can pull it out.", fgs(th.fg))])
    else: say([("✗ ", fgs(th.red)), (t.name & " couldn't be powered off: " & msg, fgs(th.fg))])

proc targetsFrom(outputs: seq[string], force: bool): seq[WriteTarget] =
  for o in outputs:
    let t = try: fromPath(o)
            except DeviceNotFound as e: fail(e.msg)
    if t.system: fail(t.devnode & " holds the running system. omnBurn won't overwrite it in " &
                      "non-interactive mode.")
    if t.targetType != ttFile and not t.isRemovable and not force:
      fail(t.devnode & " isn't removable. Pass --force if you really mean it.")
    result.add t

proc runBurn*(args: BurnArgs, logPath: string): int =
  if args.outputs.len == 0: fail("Non-interactive mode needs at least one -o <disk>.")
  if not args.common.force:
    fail("Non-interactive mode won't destroy a disk without --force.")
  var image = args.image
  var dl: Download
  if args.preset == some(psWindows):
    fail("Microsoft hands out Windows download links only on its website. Download the ISO " &
         "there, in a browser (" & WindowsPage & "), then burn it with: omnburn burn " &
         "~/Downloads/Win11_….iso -o <disk>")
  if args.preset.isSome:
    let p = args.preset.get
    note("Looking up", "the latest " & p.displayName & " (" & p.edition & ")")
    dl = download(resolvePreset(p))
  elif image.isUrl: dl = download(Resolved(url: image))
  if dl.dest.len > 0: image = dl.dest
  image = absolutePath(image)

  let forced = args.compression.associatedFormat
  let cf = if forced.isSome: forced.get else: detectFormat(image)
  let zip = if cf == cfZip: findZipEntry(image) else: ZipEntry()
  let est = estimateSize(image, cf, zip)
  let info = inspect(image, cf, zip)
  note("Image", image)
  note("Format", cf.displayName)
  note("Contents", info.summary)
  for w in info.warnings: say([("⚠ " & w, fgs(th.yellow))])
  let windows = info.windowsStick(cf)
  if windows:
    note("Windows", "builds a bootable stick from the ISO's files (FAT32, boots in UEFI mode)")
    let problem = windowsProblem()
    if problem.len > 0: fail(problem)

  var expected: Option[ExpectedHash]
  case args.hash.kind
  of haHash:
    expected = some(expectedFromInput(args.hash.alg, args.hash.expected, "the command line",
                                      args.hashOf.hashTarget))
  of haSkip: discard
  of haAsk:
    let (found, e) = if args.hashFile.len > 0: findHashInUserFile(image, args.hashFile)
                     else: findHashFor(image)
    if found: expected = some(e)
    elif args.hashFile.len > 0: fail("Couldn't find the image's hash in " & args.hashFile)
  var prechecked = false
  if expected.isNone and args.hash.kind == haAsk and info.windows and cf.isIdentity:
    # No checksum file, but Microsoft's download page lists them.
    note("Checksum", "looking the ISO up in Microsoft's published checksums")
    try:
      let table = windowsHashes()
      let r = hashImage(image, haSha256, cf, zip) do (done, total: int64):
        progressLine("Checking", if total > 0: done / total else: 1.0, formatBytes(done))
      endProgress()
      let label = windowsHashLabel(table, toHex(r.file))
      if label.len == 0:
        fail("The ISO's SHA-256 isn't one Microsoft lists for the current Windows 11 release. " &
             "If it's an older release, pass --hash skip to burn it without a checksum.")
      say([("✓ It's Microsoft's " & label & " ISO, unchanged.", fgs(th.green))])
      expected = some(expectedFromInput(haSha256, r.file, "Microsoft's website (" & label & ")", htFile))
      prechecked = true
    except FetchError as e:
      say([("⚠ Couldn't get Microsoft's checksums (" & e.msg & "); not checking the ISO.", fgs(th.yellow))])
  if expected.isSome and not prechecked:
    note("Checksum", expected.get.alg.displayName & " from " & expected.get.source)
  var sigCheck = checkImage(image)
  sigCheck.wait()
  if sigCheck.status != ssNone: note("Signature", sigCheck.describe)
  if sigCheck.status in {ssBad, ssRevoked}: fail("The image's signature is bad; not burning it.")

  let targets = targetsFrom(args.outputs, args.common.force)
  for t in targets:
    note("Target", $t)
    if est.known and t.size >= 0 and est.size > t.size:
      fail(t.devnode & " (" & t.sizeStr & ") is too small for this image (" & formatBytes(est.size) & ").")

  if (args.hashFirst or windows) and expected.isSome and not prechecked:
    let r = hashImage(image, expected.get.alg, cf, zip) do (done, total: int64):
      progressLine("Checking", if total > 0: done / total else: 1.0, formatBytes(done))
    endProgress()
    if not expected.get.matches(r): fail("The image doesn't match its checksum!")
    say([("✓ The image matches its checksum.", fgs(th.green))])
    prechecked = true

  var allowSystem = false
  let hashAlg = if expected.isSome and not prechecked: some(expected.get.alg) else: none(HashAlg)
  let action = if windows: windowsAction(image, targets, args.verify, allowSystem)
               else: burnAction(image, cf, zip, targets, args.verify, hashAlg, allowSystem)
  var (child, job) = startOrEscalate(action, targets, logPath, args.common.root)
  var mismatch = false
  follow(child, job, proc (j: var Job): bool =
    if expected.get.matches(j.hashResult):
      endProgress()
      say([("✓ The image matches its checksum.", fgs(th.green))])
      return true
    mismatch = true
    false)
  if mismatch:
    say([("✗ The image doesn't match its checksum! It may be corrupted; don't trust the disk.", fgs(th.red, bold = true))])
    notify("Burn failed", "The image doesn't match its checksum", urgent = true)
    return 1
  result = summary(job)
  notify(if job.ok: "Burn complete" else: "Burn failed", image.extractFilename & " → " & args.outputs.join(", "),
         urgent = not job.ok)
  if args.eject and job.okCount > 0: powerOffAll(targets)

proc runBackup*(args: BackupArgs, logPath: string): int =
  if args.disk.len == 0: fail("Non-interactive mode needs the disk to back up.")
  let disk = try: fromPath(args.disk) except DeviceNotFound as e: fail(e.msg)
  let dest = absolutePath(if args.output.len > 0: args.output
                          else: downloadDir() / (disk.name & "-" & now().format("yyyy-MM-dd") &
                                                 ".img" & args.compression.extension))
  if fileExists(dest) and not args.common.force:
    fail(dest & " already exists. Pass --force to replace it.")
  note("Disk", $disk)
  note("Image", dest & " (" & args.compression.displayName & ")")
  let image = WriteTarget(name: dest.extractFilename, devnode: dest, size: -1, targetType: ttFile)
  var (child, job) = startOrEscalate(backupAction(disk, dest, args.compression), @[image], logPath,
                                     args.common.root)
  follow(child, job, nil)
  result = summary(job)
  if job.ok:
    note("SHA-256", job.extra)
    notify("Backup complete", dest)

proc runRestore*(args: RestoreArgs, logPath: string): int =
  if args.disk.len == 0: fail("Non-interactive mode needs the disk to restore.")
  if not args.common.force: fail("Non-interactive mode won't erase a disk without --force.")
  let targets = targetsFrom(@[args.disk], args.common.force)
  note("Disk", $targets[0])
  note("Create", "one " & $args.fs & " partition labelled " & args.label)
  var (child, job) = startOrEscalate(formatAction(targets[0], $args.fs, args.label, false),
                                     targets, logPath, args.common.root)
  follow(child, job, nil)
  result = summary(job)
  if job.ok: notify("Stick restored", targets[0].name & " is a normal drive again")
  if args.eject and job.ok: powerOffAll(targets)
