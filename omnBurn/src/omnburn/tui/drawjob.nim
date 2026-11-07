## The screens for the drives and the job: picking drives, backup and restore
## options, confirming, the job running, and the result.

import std/[options, os, strformat, strutils]
import ../[byteseries, cli, compression, device, hash, herder, logging, sig, theme]
import screen, widgets
import state
import drawparts

proc diskRow(a: App, d: WriteTarget, w: int): seq[Seg] =
  let multi = a.mode == mBurn
  let on = d.devnode in a.picked
  result.add ((if multi: (if on: "[x] " else: "[ ] ") else: (if on: "(•) " else: "( ) ")), a.acc)
  result.add (d.name.alignLeft(9), a.bright)
  result.add (d.modelStr.ellipsize(30).alignLeft(31), a.fg)
  result.add (d.sizeStr.align(9) & "  ", a.fg)
  result.add (($d.bus).alignLeft(8), a.dim)
  if d.system: result.add (" SYSTEM DISK", a.bad)
  if d.readOnly: result.add (" read-only", a.bad)
  if a.tooSmall(d): result.add (" too small", a.bad)
  let mps = d.mountpoints
  if mps.len > 0: result.add (" mounted: " & mps.join(", ").tilde, a.warnSt)

proc drawDisks*(a: App, b: var Buffer) =
  let title = case a.mode
    of mBurn: "Burn › Choose drives"
    of mBackup: "Back up › Choose a disk"
    of mRestore: "Restore › Choose a stick"
  b.header(a.th, title)
  let r = mainBox(b, 120, min(max(a.disks.len, 2), b.h - 8) + 2)
  b.box(r, if a.showAll: "All disks" else: "Removable drives", fgs(a.th.muted), a.acc,
        "watching for new drives", a.dim)
  let inn = r.inner
  if a.disks.len == 0:
    b.text(inn.x + 2, inn.y, "No removable drives found. Plug in a USB stick or SD card;", a.dim)
    b.text(inn.x + 2, inn.y + 1, "it shows up here by itself.", a.dim)
  for i, d in a.disks:
    if i >= inn.h: break
    b.row(inn.x + 1, inn.y + i, inn.w - 2, a.diskRow(d, inn.w - 2), i == a.diskSel, a.th)
  var y = r.y + r.h + 1
  if a.mode == mBurn and a.est.known:
    b.text(r.x + 1, y, "The image needs " & (if a.est.exact: "" else: "at least ") &
           formatBytes(a.est.size) & ".", a.dim)
    inc y
  if a.mode == mBurn and a.picked.len > 0:
    b.text(r.x + 1, y, $a.picked.len & " selected", a.acc)
    inc y
  if not a.showAll:
    b.text(r.x + 1, y, "Only removable drives are shown. Press a to show all disks.", a.dim)
  else:
    b.text(r.x + 1, y, "Showing all disks. Proceed with caution!", a.warnSt)
  a.drawStatus(b, b.h - 2)
  var hints = @[("↑↓", "move")]
  if a.mode == mBurn: hints.add ("space", "select")
  hints.add [("⏎", "continue"), ("a", if a.showAll: "removable only" else: "all disks"), ("esc", "back")]
  b.footer(a.th, hints)

proc drawBackupOpts*(a: App, b: var Buffer) =
  b.header(a.th, "Back up › Options")
  let d = a.targets[0]
  let r = mainBox(b, 110, 10)
  b.box(r, "Back up " & d.name, fgs(a.th.muted), a.acc)
  let inn = r.inner
  let (x, w, kw) = (inn.x + 1, inn.w - 2, 14)
  b.kvRow(x, inn.y, w, kw, "Disk", [(d.name & "  ", a.bright), (d.details, a.fg)], a.th)
  b.text(x, inn.y + 2, "Save to", fgs(a.th.accent))
  b.textField(x + kw, inn.y + 2, w - kw, a.backupOut, a.th)
  b.kvRow(x, inn.y + 4, w, kw, "Compression", [(a.backupFmt.displayName, a.bright), ("  (tab changes)", a.dim)], a.th)
  let free = freeSpace(a.backupOut.parentDir)
  b.kvRow(x, inn.y + 5, w, kw, "Free space",
          [((if free >= 0: formatBytes(free) else: "?") & " in " &
            a.backupOut.parentDir.tilde.ellipsizeLeft(w - kw - 14), a.fg)], a.th)
  b.paragraph(rect(r.x + 1, r.y + r.h + 1, r.w - 2, 3),
              "A " & a.backupOut.extractFilename & ".sha256 checksum file is saved next to it. " &
              "omnBurn can burn the image back later, compressed as it is.", a.dim)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("type", "edit the path"), ("tab", "compression"), ("⏎", "continue"), ("esc", "back")])

proc drawRestoreOpts*(a: App, b: var Buffer) =
  b.header(a.th, "Restore › Options")
  let d = a.targets[0]
  let r = mainBox(b, 100, 9)
  b.box(r, "Restore " & d.name, fgs(a.th.muted), a.acc)
  let inn = r.inner
  let (x, w, kw) = (inn.x + 1, inn.w - 2, 14)
  b.kvRow(x, inn.y, w, kw, "Disk", [(d.name & "  ", a.bright), (d.details, a.fg)], a.th)
  b.kvRow(x, inn.y + 2, w, kw, "Filesystem",
          [((if a.fs == fsExfat: "exFAT" else: "FAT32"), a.bright), ("  (tab changes)", a.dim)], a.th)
  b.text(x, inn.y + 4, "Label", fgs(a.th.accent))
  b.textField(x + kw, inn.y + 4, min(20, w - kw), a.label, a.th)
  b.paragraph(rect(r.x + 1, r.y + r.h + 1, r.w - 2, 3),
              if a.fs == fsExfat: "exFAT works on Linux, macOS and Windows, with files of any size."
              else: "FAT32 works almost everywhere, including old devices, but files can't exceed 4 GB.",
              a.dim)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("type", "edit the label"), ("tab", "filesystem"), ("⏎", "continue"), ("esc", "back")])

proc drawConfirm*(a: App, b: var Buffer) =
  b.header(a.th, $a.mode & " › Confirm")
  let r = mainBox(b, 110, a.targets.len + 9 + (if a.winMode: 1 else: 0))
  let title = case a.mode
    of mBurn: (if a.winMode: "Ready to make a Windows stick" else: "Ready to burn")
    of mBackup: "Ready to back up"
    of mRestore: "Ready to restore"
  b.box(r, title, fgs(a.th.muted), a.acc)
  let inn = r.inner
  let (x, w, kw) = (inn.x + 1, inn.w - 2, 10)
  var y = inn.y
  case a.mode
  of mBurn:
    b.kvRow(x, y, w, kw, "Image", [(a.image.extractFilename, a.bright),
                                   ("  " & formatBytes(getFileSize(a.image)), a.dim)], a.th)
    b.kvRow(x, y + 1, w, kw, "Checksum", a.checksumLine, a.th)
    y += 2
    if a.winMode:
      b.kvRow(x, y, w, kw, "Create", [("a Windows installer: one FAT32 partition with the ISO's files", a.bright)], a.th)
      inc y
  of mBackup:
    b.kvRow(x, y, w, kw, "Save to", [(a.backupOut.tilde.ellipsizeLeft(w - kw - 18), a.bright),
                                     ("  " & a.backupFmt.displayName, a.dim)], a.th)
    inc y
  of mRestore:
    b.kvRow(x, y, w, kw, "Create", [("one " & (if a.fs == fsExfat: "exFAT" else: "FAT32") &
                                     " partition labelled " & a.label, a.bright)], a.th)
    inc y
  for i, t in a.targets:
    var s = @[(t.name & "  ", a.bright), (t.details, a.fg)]
    if t.system: s.add ("  SYSTEM DISK", a.bad)
    let mps = t.mountpoints
    if mps.len > 0: s.add ("  " & mps.join(", ").tilde & " will be unmounted", a.warnSt)
    b.kvRow(x, y + i, w, kw, if i == 0: (if a.mode == mBackup: "From" else: "Drives") else: "", s, a.th)
  y += a.targets.len + 1
  if a.winMode:
    b.kvRow(x, y, w, kw, "Options", [("v", a.acc), (" verify: " & onOff(a.verify) & "   ", a.fg),
                                     ("e", a.acc), (" power off when done: " & onOff(a.eject), a.fg)], a.th)
  elif a.mode == mBurn:
    b.kvRow(x, y, w, kw, "Options", [("v", a.acc), (" verify: " & onOff(a.verify) & "   ", a.fg),
                                     ("e", a.acc), (" power off when done: " & onOff(a.eject) & "   ", a.fg),
                                     ("h", a.acc), (" check checksum first: " & onOff(a.hashFirst), a.fg)], a.th)
  elif a.mode == mRestore:
    b.kvRow(x, y, w, kw, "Options", [("e", a.acc), (" power off when done: " & onOff(a.eject), a.fg)], a.th)
  y = r.y + r.h + 1
  if a.mode == mBackup:
    if fileExists(a.backupOut):
      b.text(r.x + 1, y, "⚠ " & a.backupOut.tilde & " already exists and will be replaced.", a.warnSt)
  else:
    let msg = "⚠ EVERYTHING ON " & a.targets.names & " WILL BE DESTROYED."
    b.text(r.x + 1, y, msg, a.bad)
    if a.confirmText.len > 0:
      b.text(r.x + 1, y + 1, "This includes a disk that isn't removable. You'll have to type its name.", a.warnSt)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("y", "start"), ("esc", "back")])

proc runTitle(a: App): string =
  case a.job.op
  of opBurn: "Burning " & a.image.extractFilename
  of opBackup: "Backing up " & a.targets.names
  of opFormat: "Restoring " & a.jobTargets.names
  of opWindows: "Making a Windows stick from " & a.image.extractFilename

proc targetGauge(a: App, b: var Buffer, r: Rect, t: TargetProgress) =
  let j = a.job
  let name = t.target.name & "  "
  if t.failed:
    b.gauge(r, 1.0, name & "✗ " & $t.error, a.th.red, a.th.track, a.th)
    return
  case j.phase
  of phStarting, phWrite:
    let ratio = j.writeRatio(t)
    let written = t.write.bytesEncountered
    let label =
      if j.op == opBackup:
        &"Reading… {formatBytes(j.readHist.bytesEncountered)} / {formatBytes(j.rawTotal)} ({ratio * 100:.1f} %) → {formatBytes(written)}"
      elif j.op == opFormat: "Working…"
      elif j.op == opWindows:
        name & (if j.stepText.len > 0: j.stepText else: "Preparing the drive") & "…" &
          (if j.step >= 2: &" {formatBytes(written)} / {formatBytes(j.outTotal)} ({ratio * 100:.1f} %)" else: "")
      elif j.outTotal >= 0:
        &"{name}Burning… {formatBytes(written)} / {formatBytes(j.outTotal)} ({ratio * 100:.1f} %)"
      else: &"{name}Burning… {formatBytes(written)} ({ratio * 100:.1f} % of the input read)"
    b.gauge(r, ratio, label, a.th.yellow, a.th.track, a.th)
  of phVerify:
    let ratio = j.verifyRatio(t)
    b.gauge(r, ratio, &"{name}Verifying… {formatBytes(t.verify.bytesEncountered)} / " &
            &"{formatBytes(j.writtenBytes)} ({ratio * 100:.1f} %)", a.th.blue, a.th.yellow, a.th,
            trackIsColor = true)
  of phDone: b.gauge(r, 1.0, name & "Done!", a.th.green, a.th.track, a.th)
  of phFailed: b.gauge(r, 1.0, name & "Failed", a.th.red, a.th.track, a.th)

proc speedSegs(a: App, s: ByteSeries, live: bool): seq[Seg] =
  ## "3.9 MB/s now · 4.5 MB/s average", or just the average once it's over.
  if live: result.add [(formatSpeed(s.recentSpeed) & " now", a.fg), (" · ", a.dim)]
  result.add (formatSpeed(s.totalAvgSpeed) & " average", if live: a.dim else: a.fg)

proc drawRun*(a: App, b: var Buffer) =
  b.header(a.th, a.runTitle)
  let j = a.job
  var y = 1
  if j.op == opFormat:
    let r = mainBox(b, 80, max(j.steps, 6) + 3, 2)
    b.box(r, "Steps", fgs(a.th.muted), a.acc)
    const stepNames = ["Unmounting", "Wiping old signatures", "Writing a new partition table",
                       "Waiting for the new partition", "Creating the filesystem", "Syncing"]
    for i, n in stepNames:
      let s = i + 1
      let (mark, st) = if s < j.step or j.phase == phDone: ("✓ ", a.good)
                       elif s == j.step: ("▸ ", a.acc)
                       else: ("· ", a.dim)
      b.segs(r.x + 2, r.y + 1 + i, [(mark, st), ((if s == j.step: j.stepText else: n), if s == j.step: a.bright else: a.fg)])
  else:
    let shown = min(j.targets.len, max((b.h - 14), 1))
    for i in 0 ..< shown:
      a.targetGauge(b, rect(0, y, b.w, 1), j.targets[i])
      if j.targets.len > 1 and i == a.focus: b.set(0, y, "▸", Style(fg: a.th.accent, bg: a.th.bg, bold: true))
      inc y
    if shown < j.targets.len:
      b.text(1, y, "+" & $(j.targets.len - shown) & " more", a.dim)
      inc y
    # the data going by: the first 16 bytes of each MiB, as it goes out
    let infoH = if b.h >= 24: 9 else: max(b.h - y - 9, 0)
    let area = rect(0, y, b.w, b.h - y - infoH - 1)
    let t = j.targets[clamp(a.focus, 0, j.targets.len - 1)]
    let what = if j.phase == phVerify: "Verifying"
               elif j.op == opBackup: "Reading " & a.targets[0].name
               elif j.op == opWindows: "Copying"
               else: "Writing"
    var hex: seq[HexRow]
    for d in j.data: hex.add (d.offset, d.bytes, if d.verify: a.th.blue else: a.th.yellow)
    b.hexDump(area, what & " · the first bytes of each MiB", hex, max(j.rawTotal, j.outTotal),
              a.th, empty = "Waiting for the first data…")
    # stats
    if infoH > 2:
      let r = rect(0, b.h - infoH - 1, b.w, infoH)
      b.box(r, "Stats", fgs(a.th.muted), a.acc)
      let inn = r.inner
      let (x, w, kw) = (inn.x + 1, inn.w - 2, 14)
      var rows: seq[(string, seq[Seg])]
      if j.op == opBackup:
        rows.add ("Input", @[(a.targets[0].devnode, a.fg)])
        rows.add ("Output", @[(a.backupOut.tilde, a.fg)])
        rows.add ("Read speed", a.speedSegs(j.readHist, live = true))
        let rd = j.readHist.bytesEncountered
        let ratio = if rd > 0: float(t.write.bytesEncountered) / float(rd) * 100 else: 0.0
        rows.add ("Compressed", @[(&"{ratio:.0f} % of the original", a.fg)])
        rows.add ("ETA", @[(formatEta(j.writeEta), a.fg)])
      else:
        rows.add ("Input", @[(a.image.extractFilename, a.fg)])
        rows.add ("Output", @[(a.jobTargets.names, a.fg)])
        rows.add ("Write speed", a.speedSegs(t.write, live = j.phase != phVerify))
        if j.phase == phVerify:
          rows.add ("Verify speed", a.speedSegs(t.verify, live = true))
          rows.add ("ETA verify", @[(formatEta(j.verifyEta), a.fg)])
        else:
          rows.add ("ETA write", @[(formatEta(j.writeEta), a.fg)])
        let chk: seq[Seg] =
          if a.expected.isNone: @[("not checked", a.dim)]
          elif a.precheck.isSome: @[("✓ checked before burning", a.good)]
          elif a.verdict.isSome: (if a.verdict.get: @[("✓ matches", a.good)] else: @[("✗ MISMATCH", a.bad)])
          else: @[("computing while burning…", a.dim)]
        rows.add ("Checksum", chk)
        if a.sig.status != ssNone: rows.add ("Signature", a.sigLine)
      for i, (k, v) in rows:
        if i >= inn.h: break
        b.kvRow(x, inn.y + i, w, kw, k, v, a.th)
  var hints: seq[(string, string)]
  if j.targets.len > 1: hints.add ("tab", "next drive")
  hints.add ("q", "stop")
  b.footer(a.th, hints)

proc drawDone*(a: App, b: var Buffer) =
  let j = a.job
  b.header(a.th, if j.ok: "Done" elif j.phase == phDone: "Partly done" else: "Failed")
  let rows = 6 + j.targets.len + a.powerMsgs.len + (if j.phase == phFailed: 8 else: 0) +
             (if j.op == opWindows: 2 else: 0)
  let r = mainBox(b, 110, min(rows + 2, b.h - 4))
  let border = if j.ok: a.th.green elif j.phase == phDone: a.th.yellow else: a.th.red
  b.box(r, if j.ok: "Success" else: "Something went wrong", fgs(border), fgs(border, bold = true))
  let inn = r.inner
  let (x, w, kw) = (inn.x + 1, inn.w - 2, 12)
  var y = inn.y
  let verb = case j.op
    of opBurn: "Burned " & a.image.extractFilename
    of opBackup: "Backed up " & a.targets.names
    of opFormat: "Restored " & a.jobTargets.names
    of opWindows: "Made a Windows installer stick from " & a.image.extractFilename
  if j.ok:
    b.text(x, y, "✓ " & verb & (if j.op in {opBurn, opWindows} and j.hasVerify: " and verified it." else: "."), a.good)
  elif j.phase == phDone:
    b.text(x, y, &"⚠ {verb}: {j.okCount} of {j.targets.len} drives OK.", a.warnSt)
  else:
    b.text(x, y, "✗ " & (case j.op
                         of opBurn: "The burn"
                         of opBackup: "The backup"
                         of opFormat: "The restore"
                         of opWindows: "Making the Windows stick") & " failed.", a.bad)
  y += 2
  if j.op != opBackup and a.jobStarted:
    for t in j.targets:
      if t.failed: b.kvRow(x, y, w, kw, t.target.name, [("✗ " & $t.error, a.bad)], a.th)
      elif a.verdict == some(false):
        b.kvRow(x, y, w, kw, t.target.name, [("✗ written, but from an image that failed its checksum", a.bad)], a.th)
      else: b.kvRow(x, y, w, kw, t.target.name, [("✓ ", a.good), (t.target.details, a.fg)], a.th)
      inc y
  if j.op in {opBurn, opWindows} and j.phase == phDone:
    let chk: seq[Seg] =
      if a.expected.isNone: @[("not checked (no checksum)", a.dim)]
      elif (a.precheck.isSome and a.precheck.get) or (a.verdict.isSome and a.verdict.get):
        @[("✓ matches ", a.good), (a.expected.get.alg.displayName & " from " & a.expected.get.source, a.dim)]
      else: @[("✗ mismatch", a.bad)]
    b.kvRow(x, y, w, kw, "Checksum", chk, a.th)
    inc y
    if a.sig.status != ssNone:
      b.kvRow(x, y, w, kw, "Signature", a.sigLine, a.th)
      inc y
  if j.op == opBackup and j.ok:
    b.kvRow(x, y, w, kw, "Saved to", [(a.backupOut.tilde.ellipsizeLeft(w - kw), a.bright)], a.th)
    b.kvRow(x, y + 1, w, kw, "Size", [(formatBytes(j.targets[0].write.bytesEncountered) & " (from " &
                                       formatBytes(j.rawTotal) & ")", a.fg)], a.th)
    b.kvRow(x, y + 2, w, kw, "SHA-256", [(j.extra, a.fg)], a.th)
    y += 3
  if j.op == opWindows and j.phase == phDone and j.okCount > 0:
    b.paragraph(rect(x, y, w, 2), "To install, start the PC from the stick (usually F12, F11 or Esc " &
                "at power-on). It boots in UEFI mode; Secure Boot can stay on.", a.fg)
    y += 2
  if j.op == opFormat and j.ok:
    b.text(x, y, a.jobTargets.names & " now has one " & (if a.fs == fsExfat: "exFAT" else: "FAT32") &
           " partition labelled " & a.label & ".", a.fg)
    inc y
  if a.jobStarted:
    let secs = secondsBetween(j.startTime, j.finishTime)
    var time = fmtDuration(secs)
    if j.op in {opBurn, opWindows} and j.targets.len > 0:
      time.add " · avg. write " & formatSpeed(j.targets[0].write.totalAvgSpeed)
    b.kvRow(x, y, w, kw, "Time", [(time, a.fg)], a.th)
    inc y
  for (ok, msg) in a.powerMsgs:
    b.text(x, y, (if ok: "⏏ " else: "✗ ") & msg, if ok: a.good else: a.warnSt, w)
    inc y
  if j.phase == phFailed:
    inc y
    var shown = false
    for t in j.targets:
      if t.failed and t.error == j.error: shown = true
    if not shown:
      y += b.paragraph(rect(x, y, w, inn.y + inn.h - y), $j.error, a.fg) + 1
    let e = j.error
    if a.verdict != some(false) and (e.kind in {ekUnknown, ekUnexpectedTermination, ekCommand} or
                                     (e.kind in {ekInputFile, ekOutputFile} and e.io == ikUnknown)):
      b.paragraph(rect(x, y, w, inn.y + inn.h - y), bugReportMsg(a.logPath), a.dim)
  a.drawStatus(b, b.h - 2)
  var hints: seq[(string, string)]
  if not a.powered and a.powerTargets.len > 0 and j.okCount > 0: hints.add ("p", "power off")
  hints.add [("n", "start over"), ("q", "quit")]
  b.footer(a.th, hints)

