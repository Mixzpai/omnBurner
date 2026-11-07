## The full-screen app: pick (or download) an image, check it, choose one or
## more drives, confirm, burn, done. Also backs disks up and restores burned
## sticks to normal drives. Everything is painted in the current Omarchy
## theme and repainted live when it changes.
##
## The code is split across `tui/`:
##
## - `state`:   the `App` object and small helpers that read it
## - `draw`:    the terminal and one draw proc per screen
## - `actions`: loading images and downloads, starting and finishing jobs
## - `keys`:    key handling, one proc per screen
## - `app`:     setting up, background work and the main loop (this file)

import std/[monotimes, options, os, strformat, strutils, times]
from std/posix import TPollfd, Tnfds, poll, POLLIN, POLLHUP, POLLERR
import ../[cli, compression, desktop, device, fetch, herder, logging, sig, sudoauth, term, theme]
import screen
import actions, draw, keys, state

proc tick(a: App) =
  ## Background work: hotplug scans, downloads, signature checks.
  if a.screen in {scHome, scDisks} and (getMonoTime() - a.lastScan).inMilliseconds >= ScanMs:
    a.scanDisks()
  discard a.sig.poll()
  if a.screen == scFetching and a.dl.poll():
    case a.dl.phase
    of dlDone:
      a.imageBack = if a.winFlow: scWindows else: scDownload
      if a.loadImage(a.dl.dest) and a.dl.sidecars.len > 0:
        a.setStatus("Got " & a.dl.sidecars.join(", "), err = false)
    of dlFailed:
      a.setStatus("Download failed: " & a.dl.error)
      a.screen = if a.winFlow: scWindows else: scDownload
    else: discard
  if a.screen == scWindows and (getMonoTime() - a.lastWinScan).inMilliseconds >= ScanMs:
    # Waiting for the browser: carry on once a new ISO stops growing.
    a.lastWinScan = getMonoTime()
    let (path, size) = findWindowsIso(downloadDir())
    if path.len > 0 and path == a.winIso and size == a.winSize: inc a.winStable
    else: a.winStable = 0
    (a.winIso, a.winSize) = (path, size)
    if a.winStable >= 2 and path != a.winSeen:
      a.useWindowsIso(path)
      return
  if a.msPending and a.screen == scImage:
    a.msPending = false
    a.checkWithMicrosoft()
  if a.autoStart and a.screen == scImage:
    a.autoStart = false
    if (a.hashFirst or a.winMode) and a.expected.isSome and a.precheck.isNone and not a.checkHashFirst(): return
    if a.precheck.isNone or a.precheck.get: a.begin()

proc pumpChild(a: App, readable: bool) =
  if readable and not a.child.pump(): a.job.onEof(getMonoTime())
  var line: string
  while a.running and a.child.popLine(line):
    let hadHash = a.job.fileHash.len > 0
    a.job.onLine(getMonoTime(), line)
    if not hadHash and a.job.fileHash.len > 0: a.onHash()
  if a.running and a.job.isFinished: a.finishJob()

proc initApp(cmd: Command, logPath: string, th: Theme): App =
  result = App(th: th, logPath: logPath, verify: true, backupFmt: cfZst, fs: fsExfat, label: "USB",
               args: BurnArgs(compression: caAuto, hash: HashArg(kind: haAsk), verify: true))
  let a = result
  case cmd.kind
  of cmdBurn:
    a.mode = mBurn
    a.args = cmd.burn
    a.common = cmd.burn.common
    a.verify = cmd.burn.verify
    a.hashFirst = cmd.burn.hashFirst
    a.eject = cmd.burn.eject
    for o in cmd.burn.outputs:
      try: a.targets.add fromPath(o)
      except DeviceNotFound as e: a.setStatus(e.msg)
    if a.status.len > 0: a.targets = @[]
    a.imageBack = scHome
    if cmd.burn.preset.isSome: a.startPreset(cmd.burn.preset.get)
    elif cmd.burn.image.isUrl: a.startFetch(cmd.burn.image)
    elif cmd.burn.image.len > 0:
      if a.loadImage(cmd.burn.image):
        a.autoStart = a.common.force and a.targets.len > 0
      else: a.screen = scHome
    else:
      a.loadDir(startDir())
      a.screen = scBrowse
  of cmdBackup:
    a.mode = mBackup
    a.common = cmd.backup.common
    a.backupFmt = cmd.backup.compression
    if cmd.backup.disk.len > 0:
      try:
        a.targets = @[fromPath(cmd.backup.disk)]
        a.backupOut = if cmd.backup.output.len > 0: absolutePath(cmd.backup.output)
                      else: defaultBackupPath(a.targets[0], a.backupFmt)
        a.screen = scBackupOpts
      except DeviceNotFound as e:
        a.setStatus(e.msg)
        a.toDisks()
    else: a.toDisks()
  of cmdRestore:
    a.mode = mRestore
    a.common = cmd.restore.common
    a.fs = cmd.restore.fs
    a.label = cmd.restore.label
    a.eject = cmd.restore.eject
    if cmd.restore.disk.len > 0:
      try:
        a.targets = @[fromPath(cmd.restore.disk)]
        a.screen = scRestoreOpts
      except DeviceNotFound as e:
        a.setStatus(e.msg)
        a.toDisks()
    else: a.toDisks()
  else: a.screen = scHome
  a.showAll = a.common.showAllDisks
  if a.screen == scHome: a.scanDisks()

proc summary*(a: App): seq[(string, Style)] =
  ## A line for the terminal after the app exits.
  if not a.hadJob: return
  let j = a.job
  let what = case j.op
    of opBurn: "Burned " & a.image.extractFilename & " to " & a.jobTargets.names
    of opBackup: "Backed up " & a.targets.names & " to " & a.backupOut.tilde
    of opFormat: "Restored " & a.jobTargets.names
    of opWindows: "Made a Windows stick from " & a.image.extractFilename & " on " & a.jobTargets.names
  if j.ok: @[("✓ ", fgs(a.th.green, bold = true)), (what & (if j.hasVerify: " and verified it." else: "."), fgs(a.th.fg))]
  elif j.phase == phDone: @[("⚠ ", fgs(a.th.yellow, bold = true)), (what & &": {j.okCount} of {j.targets.len} OK.", fgs(a.th.fg))]
  else: @[("✗ ", fgs(a.th.red, bold = true)), ($j.error, fgs(a.th.fg))]

proc runApp*(cmd: Command, logPath: string, th: var Theme): (int, seq[(string, Style)]) =
  ## Runs the app until the user quits. Returns an exit code and a summary.
  let a = initApp(cmd, logPath, th)
  a.enterScreen()
  try:
    var lastDraw = getMonoTime() - initDuration(seconds = 1)
    while not a.quit:
      if a.th.refresh():
        info("Theme changed to " & a.th.name)
        a.prev = newBuffer(0, 0)
      a.tick()
      if a.quit: break
      if (getMonoTime() - lastDraw).inMilliseconds >= 30 or not a.running:
        a.drawNow()
        lastDraw = getMonoTime()
      let watchChild = a.running and not a.child.eof
      let watchSudo = a.auth.running
      var fds = [TPollfd(fd: 0, events: POLLIN),
                 TPollfd(fd: (if watchChild: a.child.outFd else: -1), events: POLLIN),
                 TPollfd(fd: a.auth.fd, events: POLLIN)] # poll skips an fd of -1
      let timeout = if hasPendingKeys(): 0 else: TickMs
      discard poll(addr fds[0], Tnfds(fds.len), cint(timeout))
      if watchChild:
        a.pumpChild((fds[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0)
      if watchSudo and (fds[2].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        a.auth.onReadable()
        if a.auth.done and a.modal == mdPassword: a.onSudoDone()
      if (fds[0].revents and POLLIN) != 0 or hasPendingKeys():
        let k = readKey(0)
        if k.kind != kNone: a.onKey(k)
  finally:
    if a.running: a.child.reap(kill = true)
    a.auth.cancel()
    a.password.wipe()
    a.sig.cancel()
    if a.screen == scFetching: a.dl.cancel()
    leaveScreen()
  th = a.th
  let code = if a.hadJob and not a.job.ok: 1 else: 0
  (code, a.summary)
