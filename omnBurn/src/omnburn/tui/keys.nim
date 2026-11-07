## Key handling: one proc per screen, and `onKey`, which dispatches to them.

import std/[options, os, strutils]
import ../[cli, compression, desktop, device, fetch, hash, herder, logging, sig, sudoauth, term,
           tools, writer]
import actions, draw, state

proc isCh(k: Key, chars: varargs[string]): bool = k.kind == kChar and k.ch in chars

proc moveSel(sel: var int, k: Key, n: int, page = 10) =
  case k.kind
  of kUp: sel = max(sel - 1, 0)
  of kDown: sel = min(sel + 1, max(n - 1, 0))
  of kPageUp: sel = max(sel - page, 0)
  of kPageDown: sel = min(sel + page, max(n - 1, 0))
  else: discard

proc toDisks*(a: App) =
  a.status = ""
  a.scanDisks()
  a.screen = scDisks

proc afterImage(a: App) =
  ## From the image screen, on to the drives (or straight to confirming, if
  ## they were given on the command line).
  if a.targets.len > 0: a.screen = scConfirm
  else: a.toDisks()

proc keyHome(a: App, k: Key) =
  moveSel(a.homeSel, k, 5)
  if k.isCh("q"): a.quit = true
  if k.kind != kEnter: return
  case a.homeSel
  of 0:
    a.mode = mBurn
    a.loadDir(startDir())
    a.screen = scBrowse
  of 1:
    a.mode = mBurn
    a.dlSel = 0
    a.dlTop = 0
    a.screen = scDownload
  of 2:
    a.mode = mBackup
    a.toDisks()
  of 3:
    a.mode = mRestore
    a.toDisks()
  else: a.quit = true

proc keyBrowse(a: App, k: Key) =
  let entries = a.visibleEntries
  moveSel(a.sel, k, entries.len, 15)
  case k.kind
  of kEnter:
    if entries.len == 0: return
    let e = entries[a.sel]
    a.status = ""
    if e.dir: a.loadDir(if e.name == "..": a.cwd.parentDir else: e.path)
    else:
      a.imageBack = scBrowse
      discard a.loadImage(e.path)
  of kLeft:
    if a.cwd != "/": a.loadDir(a.cwd.parentDir)
  of kBackspace:
    if a.filter.len > 0: a.filter.dropLastRune
    elif a.cwd != "/": a.loadDir(a.cwd.parentDir)
  of kTab: a.allFiles = not a.allFiles
  of kEsc:
    if a.filter.len > 0: a.filter = ""
    else:
      a.status = ""
      a.screen = scHome
  of kChar:
    a.filter.add k.ch
    a.sel = 0
    a.top = 0
  else: discard

proc keyDownload(a: App, k: Key) =
  let n = Preset.high.ord + 2
  moveSel(a.dlSel, k, n)
  case k.kind
  of kChar:
    # Jump to the next entry starting with that letter.
    let c = k.ch.toLowerAscii
    for step in 1 .. n:
      let i = (a.dlSel + step) mod n
      let name = if i <= Preset.high.ord: Preset(i).displayName else: "Enter a URL"
      if name.toLowerAscii.startsWith(c):
        a.dlSel = i
        break
  of kEnter:
    a.status = ""
    a.winFlow = false
    if a.dlSel <= Preset.high.ord: a.startPreset(Preset(a.dlSel))
    else:
      a.url = ""
      a.screen = scUrl
  of kEsc:
    a.status = ""
    a.screen = scHome
  else: discard

proc keyWindows(a: App, k: Key) =
  case k.kind
  of kEnter:
    if a.winSeen.len > 0 and fileExists(a.winSeen): a.useWindowsIso(a.winSeen)
  of kEsc:
    a.status = ""
    a.winFlow = false
    a.screen = scDownload
  of kChar:
    case k.ch
    of "o": a.openWindowsPage()
    of "u":
      a.url = ""
      a.status = ""
      a.screen = scUrl
    of "b":
      a.status = ""
      a.loadDir(startDir())
      a.screen = scBrowse
    of "q": a.quit = true
    else: discard
  else: discard

proc keyUrl(a: App, k: Key) =
  case k.kind
  of kEnter:
    let u = a.url.strip
    if not u.isUrl: a.setStatus("That's not an http(s) URL.")
    else: a.startFetch(u)
  of kEsc:
    a.status = ""
    a.screen = if a.winFlow: scWindows else: scDownload
  of kBackspace: a.url.dropLastRune
  of kChar: a.url.add k.ch
  else: discard

proc keyImage(a: App, k: Key) =
  if a.editHash:
    case k.kind
    of kEnter:
      try:
        let (algs, value) = parseHashInput(a.hashInput.strip)
        a.expected = some(expectedFromInput(algs[^1], value, "what you typed"))
        a.precheck = none(bool)
        a.editHash = false
        a.status = ""
      except HashParseError as e: a.setStatus(e.msg)
    of kEsc:
      a.editHash = false
      a.status = ""
    of kBackspace: a.hashInput.dropLastRune
    of kChar: a.hashInput.add k.ch
    else: discard
    return
  case k.kind
  of kEnter:
    a.status = ""
    if a.winMode and a.winProblem.len > 0:
      a.winProblem = windowsProblem() # it may have been installed since
      if a.winProblem.len > 0:
        a.setStatus("This system can't make a Windows stick yet (see above).")
        return
    if (a.hashFirst or a.winMode) and a.expected.isSome and a.precheck.isNone and not a.checkHashFirst(): return
    if a.precheck.isSome and not a.precheck.get:
      a.setStatus("The image doesn't match its checksum. Press s to burn it anyway, without the check.")
      return
    a.afterImage()
  of kEsc:
    a.status = ""
    a.sig.cancel()
    a.sig = SigCheck()
    a.screen = a.imageBack
  of kChar:
    case k.ch
    of "c":
      a.editHash = true
      a.hashInput = ""
    of "s":
      a.expected = none(ExpectedHash)
      a.precheck = none(bool)
      a.setStatus("Not checking the image against a checksum.", err = false)
    of "z":
      let i = AvailableFormats.find(a.fmt)
      a.fmt = AvailableFormats[(i + 1) mod AvailableFormats.len]
      discard a.reinspect()
      a.precheck = none(bool)
    of "v": a.verify = not a.verify
    of "h": a.hashFirst = not a.hashFirst
    of "m": (if a.info.windows: a.checkWithMicrosoft())
    of "k":
      if a.sig.status == ssNoKey:
        a.setStatus("Fetching key " & a.sig.keyId & " from keyserver.ubuntu.com…", err = false)
        a.drawNow()
        let (ok, msg) = fetchKey(a.sig.keyId)
        a.setStatus(msg, err = not ok)
        a.sig = checkImage(a.image)
    of "q": a.quit = true
    else: discard
  else: discard

proc pickable(a: App, d: WriteTarget): string =
  ## Why a disk can't be picked, or "".
  if a.mode != mBackup and d.readOnly: return d.name & " is read-only."
  if a.tooSmall(d): return d.name & " is too small for this image."

proc keyDisks(a: App, k: Key) =
  moveSel(a.diskSel, k, a.disks.len)
  let cur = if a.disks.len > 0: a.disks[a.diskSel] else: WriteTarget()
  case k.kind
  of kEnter:
    if a.disks.len == 0: return
    if a.picked.len == 0:
      let why = a.pickable(cur)
      if why.len > 0:
        a.setStatus(why)
        return
      a.picked = @[cur.devnode]
    a.targets = @[]
    for d in a.disks:
      if d.devnode in a.picked: a.targets.add d
    a.status = ""
    case a.mode
    of mBurn: a.screen = scConfirm
    of mBackup:
      a.backupOut = defaultBackupPath(a.targets[0], a.backupFmt)
      a.screen = scBackupOpts
    of mRestore:
      a.label = defaultLabel(a.fs)
      a.screen = scRestoreOpts
  of kEsc:
    a.status = ""
    a.picked = @[]
    a.screen = if a.mode == mBurn: scImage else: scHome
  of kChar:
    case k.ch
    of " ":
      if a.disks.len == 0: return
      let why = a.pickable(cur)
      if why.len > 0:
        a.setStatus(why)
      elif cur.devnode in a.picked:
        a.picked.delete(a.picked.find(cur.devnode))
      elif a.mode == mBurn:
        if a.picked.len >= MaxTargets: a.setStatus("At most " & $MaxTargets & " drives at once.")
        else: a.picked.add cur.devnode
      else: a.picked = @[cur.devnode]
      if why.len == 0: a.status = ""
    of "a":
      a.showAll = not a.showAll
      a.scanDisks()
    of "q": a.quit = true
    else: discard
  else: discard

proc keyBackupOpts(a: App, k: Key) =
  case k.kind
  of kEnter:
    let dir = a.backupOut.expandTilde.parentDir
    if a.backupOut.strip.len == 0 or a.backupOut.endsWith("/"):
      a.setStatus("Enter a file name.")
    elif not dirExists(dir): a.setStatus(dir.tilde & " doesn't exist.")
    else:
      a.backupOut = absolutePath(a.backupOut.expandTilde)
      a.status = ""
      a.screen = scConfirm
  of kTab:
    let old = a.backupFmt
    let i = BackupFormats.find(old)
    a.backupFmt = BackupFormats[(i + 1) mod BackupFormats.len]
    if old.extension.len > 0 and a.backupOut.endsWith(old.extension):
      a.backupOut.setLen(a.backupOut.len - old.extension.len)
    a.backupOut.add a.backupFmt.extension
  of kEsc:
    a.status = ""
    a.toDisks()
  of kBackspace: a.backupOut.dropLastRune
  of kChar: a.backupOut.add k.ch
  else: discard

proc keyRestoreOpts(a: App, k: Key) =
  let maxLen = if a.fs == fsFat32: 11 else: 15
  case k.kind
  of kEnter:
    if a.label.strip.len == 0: a.setStatus("Enter a label.")
    else:
      a.status = ""
      a.screen = scConfirm
  of kTab:
    a.fs = if a.fs == fsExfat: fsFat32 else: fsExfat
    if a.fs == fsFat32: a.label = a.label.toUpperAscii
    if a.label.len > 11 and a.fs == fsFat32: a.label.setLen(11)
  of kEsc:
    a.status = ""
    a.toDisks()
  of kBackspace: a.label.dropLastRune
  of kChar:
    if a.label.len < maxLen and k.ch.len == 1 and k.ch[0] notin {'/', '\\', '"', '*', ':', '<', '>', '?', '|'}:
      a.label.add(if a.fs == fsFat32: k.ch.toUpperAscii else: k.ch)
  else: discard

proc keyConfirm(a: App, k: Key) =
  case k.kind
  of kEsc:
    a.status = ""
    a.screen = case a.mode
      of mBurn: (if a.args.outputs.len > 0: scImage else: scDisks)
      of mBackup: scBackupOpts
      of mRestore: scRestoreOpts
  of kEnter: discard
  of kChar:
    case k.ch
    of "y", "Y":
      for t in a.targets.mitems: t = t.refreshed # mounts may have changed meanwhile
      if a.confirmText.len > 0:
        a.typed = ""
        a.modal = mdTypeConfirm
      else: a.begin()
    of "v": (if a.mode == mBurn: a.verify = not a.verify)
    of "e": (if a.mode != mBackup: a.eject = not a.eject)
    of "h": (if a.mode == mBurn: a.hashFirst = not a.hashFirst)
    of "q": a.quit = true
    else: discard
  else: discard

proc keyRun(a: App, k: Key) =
  if k.kind in {kCtrlC, kEsc} or k.isCh("q"):
    info("Got request to quit, spawning prompt")
    a.modal = mdQuit
  elif k.kind == kTab and a.job.targets.len > 0:
    a.focus = (a.focus + 1) mod a.job.targets.len

proc keyDone(a: App, k: Key) =
  if k.kind in {kEsc, kCtrlC} or k.isCh("q"): a.quit = true
  elif k.isCh("n"): a.resetForNew()
  elif k.isCh("p") and not a.powered and a.job.okCount > 0: a.powerOffAll()

proc keyModal(a: App, k: Key) =
  case a.modal
  of mdQuit:
    if k.kind == kEsc: a.modal = mdNone
    elif k.isCh("q", "Q") or k.kind == kCtrlC:
      a.modal = mdNone
      a.child.reap(kill = true)
      a.quit = true
  of mdStopDownload:
    if k.kind == kEsc or k.isCh("n"): a.modal = mdNone
    elif k.isCh("y", "Y"):
      a.modal = mdNone
      a.dl.cancel()
      a.setStatus("Download stopped; it resumes if you start it again.", err = false)
      a.screen = if a.winFlow: scWindows else: scDownload
  of mdEscalate:
    if k.isCh("y", "Y") or k.kind == kEnter:
      a.modal = mdNone
      if not a.launch(some(a.escMethod)): a.finishJob()
    elif k.isCh("n", "N") or k.kind == kEsc:
      a.modal = mdNone
      a.job.error.raw.add " (not allowed to become root)"
      a.finishJob()
  of mdPassword:
    case k.kind
    of kEsc, kCtrlC: a.cancelPassword()
    of kEnter: a.submitPassword()
    of kBackspace: a.password.wipeLastRune
    of kChar: (if a.password.len + k.ch.len < 200: a.password.add k.ch)
    else: discard
  of mdTypeConfirm:
    case k.kind
    of kEsc: a.modal = mdNone
    of kEnter:
      if a.typed.strip == a.confirmText:
        a.modal = mdNone
        a.begin()
      else: a.typed = ""
    of kBackspace: a.typed.dropLastRune
    of kChar: a.typed.add k.ch
    else: discard
  of mdNone: discard

proc onKey*(a: App, k: Key) =
  if a.modal != mdNone:
    a.keyModal(k)
    return
  if k.kind == kCtrlC and a.screen notin {scRun, scFetching}:
    a.quit = true
    return
  case a.screen
  of scHome: a.keyHome(k)
  of scBrowse: a.keyBrowse(k)
  of scDownload: a.keyDownload(k)
  of scWindows: a.keyWindows(k)
  of scUrl: a.keyUrl(k)
  of scFetching:
    if k.kind in {kEsc, kCtrlC} or k.isCh("q"): a.modal = mdStopDownload
  of scImage: a.keyImage(k)
  of scHashing: discard
  of scDisks: a.keyDisks(k)
  of scBackupOpts: a.keyBackupOpts(k)
  of scRestoreOpts: a.keyRestoreOpts(k)
  of scConfirm: a.keyConfirm(k)
  of scRun: a.keyRun(k)
  of scDone: a.keyDone(k)
