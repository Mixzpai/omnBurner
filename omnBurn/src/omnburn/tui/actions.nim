## What the app does for the user: loading folders, images and downloads,
## and starting, following and finishing jobs.

import std/[algorithm, monotimes, options, os, strutils, times]
from std/posix import signal, SIGINT, SIG_IGN, SIG_DFL
import ../[cli, compression, desktop, device, fetch, hash, herder, image, logging, sig, sudoauth,
           term, theme, tools, writer]
import draw, state

# ---------------------------------------------------------------------------
# Loading data

proc scanDisks*(a: App) =
  a.disks = enumerateDevices(a.showAll)
  var still: seq[string]
  for p in a.picked:
    for d in a.disks:
      if d.devnode == p: still.add p
  a.picked = still
  a.diskSel = clamp(a.diskSel, 0, max(a.disks.len - 1, 0))
  a.lastScan = getMonoTime()

proc loadDir*(a: App, dir: string) =
  a.cwd = dir
  a.listing = @[]
  a.filter = ""
  a.sel = 0
  a.top = 0
  var dirs, files: seq[Entry]
  try:
    for kind, p in walkDir(dir):
      let name = p.extractFilename
      if name.startsWith('.'): continue
      var e = Entry(name: name, path: p, dir: kind in {pcDir, pcLinkToDir})
      if not e.dir:
        try:
          let fi = getFileInfo(p)
          e.size = fi.size
          e.mtime = fi.lastWriteTime
        except OSError: continue
        files.add e
      else: dirs.add e
  except OSError as err:
    a.setStatus("Can't open " & dir.tilde & ": " & err.msg)
  dirs.sort(proc (x, y: Entry): int = cmp(x.name.toLowerAscii, y.name.toLowerAscii))
  files.sort(proc (x, y: Entry): int = cmp(y.mtime, x.mtime)) # newest first
  if dir != "/": a.listing.add Entry(name: "..", path: dir.parentDir, dir: true)
  a.listing.add dirs
  a.listing.add files

proc findExpected(a: App): Option[ExpectedHash] =
  ## The checksum to hold the image to: from the command line, a hash file,
  ## or files found next to the image.
  let fromCli = a.args.image.len > 0 and absolutePath(a.args.image) == a.image
  let target = a.args.hashOf.hashTarget
  if fromCli and a.args.hash.kind == haHash:
    return some(expectedFromInput(a.args.hash.alg, a.args.hash.expected, "the command line", target))
  if fromCli and a.args.hashFile.len > 0:
    let (found, e) = findHashInUserFile(a.image, a.args.hashFile)
    if found: return some(e)
    a.setStatus("Couldn't find the image's hash in " & a.args.hashFile)
    return
  if fromCli and a.args.hash.kind == haSkip: return
  let (found, e) = findHashFor(a.image)
  if found:
    var e = e
    if a.args.hashOf.isSome: e.target = target
    return some(e)

proc reinspect*(a: App): bool =
  try:
    a.zip = if a.fmt == cfZip: findZipEntry(a.image) else: ZipEntry()
    a.est = estimateSize(a.image, a.fmt, a.zip)
    a.info = inspect(a.image, a.fmt, a.zip)
    a.winProblem = if a.info.windowsStick(a.fmt): windowsProblem() else: ""
    true
  except CatchableError as e:
    a.info = ImageInfo(summary: "Can't read it as " & a.fmt.displayName & ": " & e.msg)
    a.est = SizeEstimate()
    false

proc loadImage*(a: App, path: string): bool =
  a.image = absolutePath(path)
  let forced = if absolutePath(a.args.image) == a.image: a.args.compression.associatedFormat
               else: none(CompressionFormat)
  try:
    a.fmt = if forced.isSome: forced.get else: detectFormat(a.image)
  except OSError as e:
    a.setStatus("Can't open " & path.tilde & ": " & e.msg)
    return false
  if not a.reinspect():
    a.setStatus(a.info.summary)
    return false
  a.status = ""
  a.expected = a.findExpected()
  a.precheck = none(bool)
  a.editHash = false
  a.sig.cancel()
  a.sig = checkImage(a.image)
  a.screen = scImage
  a.msPending = a.winFlow and a.info.windows and a.expected.isNone
  info("Image " & a.image & ": " & $a.fmt & ", " & a.info.summary)
  true

proc startFetch*(a: App, url: string, sidecars: seq[Sidecar] = @[]) =
  a.status = ""
  a.dl = startDownload(url, sidecars = sidecars)
  a.screen = scFetching
  if a.dl.phase == dlFailed:
    a.setStatus("Download failed: " & a.dl.error)
    a.screen = if a.winFlow: scWindows else: scDownload

proc findWindowsIso*(dir: string): (string, int64) =
  ## The newest finished Windows ISO in `dir`, named the way Microsoft names
  ## them (Win11_25H2_English_x64.iso), and its size.
  var newest: times.Time
  try:
    for kind, p in walkDir(dir):
      let n = p.extractFilename.toLowerAscii
      if kind notin {pcFile, pcLinkToFile} or not n.startsWith("win") or not n.endsWith(".iso"): continue
      # Browsers download into these and rename at the end (Firefox leaves
      # an empty placeholder under the final name meanwhile).
      if fileExists(p & ".part") or fileExists(p & ".crdownload"): continue
      let size = getFileSize(p)
      let mtime = getLastModificationTime(p)
      if size >= 1_000_000_000 and (result[0].len == 0 or mtime > newest):
        result = (p, size)
        newest = mtime
  except OSError: discard

proc openWindowsPage*(a: App) =
  if openUrl(WindowsPage): a.setStatus("Opened Microsoft's download page in your browser.", err = false)
  else: a.setStatus("No browser here: open " & WindowsPage & " on any device.", err = false)

proc openWindows(a: App) =
  a.winFlow = true
  a.screen = scWindows
  a.status = ""
  a.winSeen = findWindowsIso(downloadDir())[0]
  a.winIso = ""
  a.winStable = 0
  a.lastWinScan = getMonoTime()
  if a.winSeen.len == 0: a.openWindowsPage()

proc useWindowsIso*(a: App, path: string) =
  a.imageBack = scWindows
  a.winSeen = path # coming back, it's offered rather than picked up again
  discard a.loadImage(path)

proc startPreset*(a: App, p: Preset) =
  if p == psWindows:
    a.openWindows()
    return
  a.setStatus("Looking up the latest " & p.displayName & "…", err = false)
  a.screen = scDownload
  a.drawNow()
  try:
    let r = resolvePreset(p)
    a.startFetch(r.url, r.sidecars)
  except FetchError as e:
    a.setStatus("Couldn't find the latest ISO: " & e.msg)

# ---------------------------------------------------------------------------
# Jobs

proc notifyDone(a: App) =
  let j = a.job
  case j.op
  of opBurn:
    if j.ok:
      notify("Burn complete", a.image.extractFilename & " → " & a.jobTargets.names &
             (if j.hasVerify: " (verified)" else: ""))
    elif j.phase == phDone:
      notify("Burn partly failed", $j.okCount & " of " & $j.targets.len & " drives OK", urgent = true)
    else: notify("Burn failed", $j.error, urgent = true)
  of opBackup:
    if j.ok: notify("Backup complete", a.backupOut.tilde)
    else: notify("Backup failed", $j.error, urgent = true)
  of opFormat:
    if j.ok: notify("Stick restored", a.jobTargets.names & " is a normal " &
                    (if a.fs == fsFat32: "FAT32" else: "exFAT") & " drive again")
    else: notify("Restore failed", $j.error, urgent = true)
  of opWindows:
    if j.ok:
      notify("Windows stick ready", a.image.extractFilename & " → " & a.jobTargets.names &
             (if j.hasVerify: " (verified)" else: ""))
    elif j.phase == phDone:
      notify("Windows stick partly failed", $j.okCount & " of " & $j.targets.len & " drives OK", urgent = true)
    else: notify("Windows stick failed", $j.error, urgent = true)

proc powerOffAll*(a: App) =
  a.setStatus("Powering off…", err = false)
  a.drawNow()
  a.status = ""
  for t in a.powerTargets:
    let (ok, msg) = powerOff(t)
    info("Power off " & t.devnode & ": " & $ok & " " & msg)
    a.powerMsgs.add (ok, if ok: t.name & " is powered off; you can pull it out."
                         else: t.name & " couldn't be powered off: " & msg)
  a.powered = true

proc finishJob*(a: App) =
  if a.child.pid > 0: a.child.reap(kill = not a.job.isFinished)
  a.running = false
  a.hadJob = true
  if a.job.finishTime == MonoTime(): a.job.finishTime = getMonoTime()
  a.screen = scDone
  a.modal = mdNone
  info("Job finished: " & $a.job.phase & ", ok " & $a.job.ok)
  a.notifyDone()
  if a.eject and a.job.okCount > 0 and a.job.phase == phDone: a.powerOffAll()

proc started(a: App, ok: bool): bool =
  ## After `start`: on to the run screen, or clean up.
  result = ok
  if ok:
    a.running = true
    a.jobStarted = true
    a.screen = scRun
    a.focus = 0
    a.verdict = none(bool)
    a.powerMsgs = @[]
    a.powered = false
  else:
    a.child.reap()

proc launch*(a: App, esc: Option[EscalationMethod]): bool =
  ## Starts the job; with `esc`, as root, the escalation tool asking for the
  ## password on the terminal, outside the app.
  a.job = newJob(a.action.op, a.jobTargets)
  if esc.isSome:
    leaveScreen()
    stdout.write paint("omnBurn needs root permissions for " & a.jobTargets.names & ".\n",
                       fgs(a.th.accent, bold = true))
    stdout.write "Asking " & $esc.get & "; enter your password if it asks.\n"
    stdout.flushFile()
    signal(SIGINT, SIG_IGN) # Ctrl-C at the password prompt should only stop sudo
  a.child = spawnHerder(a.logPath, esc)
  let ok = a.child.start(a.action, a.job)
  if esc.isSome:
    signal(SIGINT, SIG_DFL)
    a.enterScreen()
  a.started(ok)

proc askPassword(a: App) =
  ## The password box, with a `sudo -v` behind it waiting for the password.
  a.auth = startSudoAuth()
  a.password = newStringOfCap(256) # room enough not to leave copies behind
  a.modal = mdPassword

proc becomeRoot(a: App) =
  ## sudo has the password: start the job as root, through `sudo -n`.
  a.modal = mdNone
  a.password.wipe()
  a.job = newJob(a.action.op, a.jobTargets)
  var ok: bool
  if sudoRemembers():
    a.child = spawnHerder(a.logPath, some(emSudo), noPrompt = true)
    ok = a.child.start(a.action, a.job)
    forgetSudo() # the job is root now; sudo can forget the password again
    ok = a.started(ok)
  else:
    info("sudo took the password but doesn't remember it; asking on the terminal")
    ok = a.launch(some(emSudo))
  if not ok: a.finishJob()

proc onSudoDone*(a: App) =
  ## `sudo -v` has exited. If it took the password, carry on, as root. If it
  ## needed none, ask first (`--root ask`), unless the user already pressed ⏎.
  if a.auth.ok and (a.auth.replied or a.common.root == usAlways): a.becomeRoot()

proc submitPassword*(a: App) =
  ## ⏎ in the password box.
  if a.auth.done:
    if a.auth.ok:
      a.becomeRoot()
      return
    a.auth = startSudoAuth() # sudo gave up (three wrong tries): a fresh one
  if a.password.len > 0 and not a.auth.checking: a.auth.send(a.password)

proc cancelPassword*(a: App) =
  ## esc in the password box: the job fails, as it would without root.
  let why = if a.auth.done and not a.auth.ok and a.auth.said.len > 0: a.auth.said
            else: "not allowed to become root"
  a.auth.cancel()
  a.password.wipe()
  a.modal = mdNone
  a.job.error.raw.add " (" & why & ")"
  a.finishJob()

proc startJob(a: App, action: Action, jobTargets: seq[WriteTarget]) =
  a.action = action
  a.jobStarted = false
  a.jobTargets = jobTargets
  a.modal = mdNone
  a.setStatus("Starting…", err = false)
  a.drawNow()
  a.status = ""
  info("Starting " & $action.op & " without escalation")
  if a.launch(none(EscalationMethod)): return
  if a.job.needsRoot:
    let (found, m) = detectEscalation()
    if not found:
      a.job.error.raw.add " (and no sudo, doas, run0 or su was found to become root)"
    else:
      a.escMethod = m
      if a.common.root == usNever:
        a.job.error.raw.add " (not allowed to become root: --root never)"
      elif m == emSudo:
        a.askPassword() # asking for the password is asking for permission
        return
      elif a.common.root == usAsk:
        a.modal = mdEscalate
        return
      elif a.launch(some(m)): return
  a.finishJob()

proc hashWithProgress(a: App, alg: HashAlg, title: string): Option[HashResult] =
  ## Hashes the image on the checking screen; none if canceled or it failed.
  a.screen = scHashing
  a.hashTitle = title
  a.hashDone = 0
  a.hashTotal = getFileSize(a.image)
  try:
    let r = hashImage(a.image, alg, a.fmt, a.zip) do (done, total: int64):
      a.hashDone = done
      a.hashTotal = total
      a.drawNow()
      let k = readKey(0)
      if k.kind in {kEsc, kCtrlC} or (k.kind == kChar and k.ch == "q"):
        raise newException(HashCanceled, "canceled")
    result = some(r)
  except HashCanceled:
    a.setStatus("Checksum check canceled.", err = false)
  except CatchableError as err:
    a.setStatus("Couldn't hash the image: " & err.msg)
  a.screen = scImage

proc checkWithMicrosoft*(a: App) =
  ## Microsoft publishes no checksum file, but its download page lists the
  ## SHA-256 of every language's ISO: look this one up there.
  a.setStatus("Getting Microsoft's published checksums…", err = false)
  a.drawNow()
  var table: seq[tuple[label, sha256: string]]
  try: table = windowsHashes()
  except FetchError as e:
    a.setStatus("Couldn't get Microsoft's checksums: " & e.msg)
    return
  a.status = ""
  let r = a.hashWithProgress(haSha256, "Checking SHA-256 against Microsoft's list")
  if r.isNone: return
  let hex = toHex(r.get.file)
  let label = windowsHashLabel(table, hex)
  if label.len > 0:
    a.expected = some(expectedFromInput(haSha256, r.get.file, "Microsoft's website (" & label & ")", htFile))
    a.precheck = some(true)
    a.setStatus("It's Microsoft's " & label & " ISO, unchanged.", err = false)
    # Saved next to it, so it's checked again next time without going online.
    try: writeFile(a.image & ".sha256", hex & "  " & a.image.extractFilename & "\n")
    except IOError: discard
  else:
    a.expected = some(expectedFromInput(haSha256, @[], "Microsoft's list for the current release", htFile))
    a.precheck = some(false)
    a.setStatus("It isn't on Microsoft's list for the current release. An older ISO? s skips the check.")

proc checkHashFirst*(a: App): bool =
  ## Hashes the image before burning. Returns true if it's fine to go on.
  let e = a.expected.get
  let r = a.hashWithProgress(e.alg, "Checking " & e.alg.displayName)
  if r.isNone: return false
  a.precheck = some(e.matches(r.get))
  if not a.precheck.get:
    a.setStatus("The image doesn't match its checksum! It may be corrupted or incomplete.")
    return false
  true

proc beginBurn(a: App) =
  if a.winMode:
    a.winProblem = windowsProblem()
    if a.winProblem.len > 0:
      a.screen = scImage
      a.setStatus("This system can't make a Windows stick yet (see above).")
      return
  # A Windows stick is built from the ISO's files, so its hash can't be
  # worked out along the way: it's always checked first.
  if (a.hashFirst or a.winMode) and a.expected.isSome and a.precheck.isNone and not a.checkHashFirst():
    return
  if a.precheck == some(false):
    a.screen = scImage
    a.setStatus("The image doesn't match its checksum. Press s to burn it anyway, without the check.")
    return
  var allowSystem = false
  for t in a.targets:
    if t.system: allowSystem = true # only reachable after typing its name
  if a.winMode:
    a.startJob(windowsAction(a.image, a.targets, a.verify, allowSystem), a.targets)
    return
  let hashAlg = if a.expected.isSome and a.precheck.isNone: some(a.expected.get.alg)
                else: none(HashAlg)
  a.startJob(burnAction(a.image, a.fmt, a.zip, a.targets, a.verify, hashAlg, allowSystem),
             a.targets)

proc begin*(a: App) =
  case a.mode
  of mBurn: a.beginBurn()
  of mBackup:
    let image = WriteTarget(name: a.backupOut.extractFilename, devnode: a.backupOut, size: -1,
                            targetType: ttFile)
    a.startJob(backupAction(a.targets[0], a.backupOut, a.backupFmt), @[image])
  of mRestore:
    a.startJob(formatAction(a.targets[0], $a.fs, a.label, a.targets[0].system), a.targets)

proc onHash*(a: App) =
  ## The child reported the image's hash while burning.
  if a.expected.isNone or a.verdict.isSome: return
  let ok = a.expected.get.matches(a.job.hashResult)
  a.verdict = some(ok)
  info("Hash while burning: " & (if ok: "match" else: "MISMATCH"))
  if not ok:
    a.child.reap(kill = true)
    a.job.failJob(getMonoTime(), WorkflowError(kind: ekCommand,
      raw: "The image doesn't match its checksum (" & a.expected.get.alg.displayName & " from " &
           a.expected.get.source & "). It may be corrupted or incomplete, so don't trust " &
           "the stick. Download the image again."))
    a.finishJob()

proc resetForNew*(a: App) =
  a.mode = mBurn
  a.screen = scHome
  a.targets = @[]
  a.picked = @[]
  a.args = BurnArgs(compression: caAuto, hash: HashArg(kind: haAsk), verify: a.verify)
  a.status = ""
  a.typed = ""
