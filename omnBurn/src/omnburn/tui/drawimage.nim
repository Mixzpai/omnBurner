## The screens for choosing an image: home, the file browser, downloads, the
## Windows flow, and checking the image.

import std/[os, strformat, strutils, times]
import ../[byteseries, compression, desktop, device, fetch, sig, theme]
import screen, widgets
import state
import drawparts

proc drawHome*(a: App, b: var Buffer) =
  b.header(a.th, "Home")
  const items = [("Burn an image file", "ISO or disk image, compressed or zipped"),
                 ("Download & burn", "Omarchy, Fedora, Ubuntu, Mint… or any URL"),
                 ("Back up a disk", "Save a stick or disk as a compressed image"),
                 ("Restore a stick", "Wipe it back to a normal exFAT/FAT32 drive"),
                 ("Quit", "")]
  let r = mainBox(b, 76, items.len + 4)
  b.box(r, "What do you want to do?", fgs(a.th.muted), a.acc)
  let inn = r.inner
  for i, (label, desc) in items:
    let selected = i == a.homeSel
    b.row(inn.x + 1, inn.y + 1 + i, inn.w - 2,
          [((if selected: "▸ " else: "  "), a.acc), (label.padTo(22), a.bright), (desc, a.dim)],
          selected, a.th)
  var y = r.y + r.h + 1
  if a.disks.len == 0:
    b.text(r.x + 1, y, "No USB sticks or SD cards plugged in.", a.dim)
  else:
    b.text(r.x + 1, y, "Plugged in:", a.dim)
    for d in a.disks:
      inc y
      if y >= b.h - 2: break
      b.segs(r.x + 3, y, [(d.name & "  ", a.acc), (d.modelStr & "  ", a.fg), (d.sizeStr, a.dim)], r.w - 3)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("↑↓", "move"), ("⏎", "select"), ("q", "quit")])

proc drawBrowse*(a: App, b: var Buffer) =
  b.header(a.th, "Burn › Pick an image")
  let r = mainBox(b, 110, b.h - 4)
  b.box(r, a.cwd.tilde.ellipsizeLeft(r.w - 30), fgs(a.th.muted), a.acc,
        if a.allFiles: "all files" else: "images only", a.dim)
  let inn = r.inner
  let entries = a.visibleEntries
  let vis = max(inn.h, 1)
  a.sel = clamp(a.sel, 0, max(entries.len - 1, 0))
  if a.sel < a.top: a.top = a.sel
  if a.sel >= a.top + vis: a.top = a.sel - vis + 1
  if entries.len == 0:
    b.text(inn.x + 2, inn.y + 1, (if a.filter.len > 0: "Nothing matches \"" & a.filter & "\"."
                                  else: "No images here. Tab shows all files."), a.dim)
  for i in a.top ..< min(a.top + vis, entries.len):
    let e = entries[i]
    let y = inn.y + i - a.top
    let w = inn.w - 2
    let meta = if e.dir: "" else: formatBytes(e.size).align(9) & "  " & e.mtime.local.format("yyyy-MM-dd HH:mm")
    let nameW = max(w - meta.len - 2, 4)
    let name = if e.dir: e.name & "/" else: e.name
    b.row(inn.x + 1, y, w, [(name.ellipsize(nameW).padTo(nameW + 2),
                             if e.dir: a.acc elif e.name.isImageName: a.bright else: a.fg),
                            (meta, a.dim)], i == a.sel, a.th)
  if a.filter.len > 0:
    b.segs(r.x + 2, r.y + r.h - 1, [(" filter: ", a.dim), (a.filter & " ", a.bright)])
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("↑↓", "move"), ("⏎", "open"), ("←", "up"), ("type", "filter"),
                  ("tab", "all files"), ("esc", "back")])

proc drawDownload*(a: App, b: var Buffer) =
  b.header(a.th, "Download & burn")
  var items: seq[(string, string)]
  for p in Preset: items.add (p.displayName, p.edition)
  items.add ("Enter a URL…", "any http(s) link to an image")
  # Leave room for the note below the box; scroll when the terminal is short.
  let r = mainBox(b, 76, min(items.len + 4, max(b.h - 10, 5)))
  let inn = r.inner
  let vis = max(inn.h - 2, 1)
  a.dlSel = clamp(a.dlSel, 0, items.len - 1)
  if a.dlSel < a.dlTop: a.dlTop = a.dlSel
  if a.dlSel >= a.dlTop + vis: a.dlTop = a.dlSel - vis + 1
  b.box(r, "What should I download?", fgs(a.th.muted), a.acc,
        if vis < items.len: $(a.dlSel + 1) & "/" & $items.len else: "", a.dim)
  for i in a.dlTop ..< min(a.dlTop + vis, items.len):
    let (name, edition) = items[i]
    b.row(inn.x + 1, inn.y + 1 + i - a.dlTop, inn.w - 2,
          [((if i == a.dlSel: "▸ " else: "  "), a.acc), (name.padTo(18), a.bright), (edition, a.dim)],
          i == a.dlSel, a.th)
  b.paragraph(rect(r.x + 1, r.y + r.h + 1, r.w - 2, 3),
              "Saves to " & downloadDir().tilde & ", with the checksum and signature files when " &
              "they're published, and resumes interrupted downloads.", a.dim)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("↑↓", "move"), ("a-z", "jump"), ("⏎", "select"), ("esc", "back")])

proc drawUrl*(a: App, b: var Buffer) =
  b.header(a.th, if a.winFlow: "Download & burn › Windows 11 › Link" else: "Download & burn › URL")
  let r = mainBox(b, 90, 6)
  b.box(r, if a.winFlow: "The 64-bit Download link from Microsoft's page" else: "Image URL",
        fgs(a.th.muted), a.acc)
  b.textField(r.x + 2, r.y + 2, r.w - 4, a.url, a.th)
  if a.winFlow:
    b.paragraph(rect(r.x + 1, r.y + r.h + 1, r.w - 2, 3), "Right-click the 64-bit Download button " &
                "and copy the link, then paste it here. Microsoft's links work for 24 hours.", a.dim)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("⏎", "download"), ("esc", "back")])

proc drawWindows*(a: App, b: var Buffer) =
  b.header(a.th, "Download & burn › Windows 11")
  let r = mainBox(b, 100, 14)
  b.box(r, "Get Windows 11 from Microsoft", fgs(a.th.muted), a.acc)
  let inn = r.inner
  let (x, w) = (inn.x + 1, inn.w - 2)
  var y = inn.y
  y += b.paragraph(rect(x, y, w, 2), "Microsoft hands out Windows download links only on its " &
                   "website, so this part happens in your browser:", a.fg) + 1
  for i, step in ["Under “Download Windows 11 Disk Image (ISO) for x64 devices”, choose " &
                    "Windows 11 and press Download Now.",
                  "Choose your language, press Confirm, then 64-bit Download.",
                  "Save it to " & downloadDir().tilde & ". omnBurn carries on by itself once it's there."]:
    b.text(x, y, $(i + 1) & ".", a.acc)
    y += b.paragraph(rect(x + 3, y, w - 3, 2), step, a.fg)
  inc y
  b.paragraph(rect(x, y, w, 2), "Or copy the 64-bit Download link and press u to paste it; omnBurn " &
              "then downloads it itself.", a.dim)
  y = r.y + r.h + 1
  if a.winSeen.len > 0 and fileExists(a.winSeen):
    b.segs(r.x + 1, y, [("Found ", a.fg), (a.winSeen.extractFilename, a.bright),
                        ("  " & formatBytes(getFileSize(a.winSeen)) & " in " & a.winSeen.parentDir.tilde, a.dim)])
    b.segs(r.x + 1, y + 1, [("⏎", a.acc), (" uses it, or get a new one with the steps above.", a.dim)])
  else:
    b.text(r.x + 1, y, "Watching " & downloadDir().tilde & " for the ISO…", a.dim)
  a.drawStatus(b, b.h - 2)
  var hints: seq[(string, string)]
  if a.winSeen.len > 0: hints.add ("⏎", "use it")
  hints.add [("o", "open the page"), ("u", "paste a link"), ("b", "browse for it"), ("esc", "back")]
  b.footer(a.th, hints)

proc drawFetching*(a: App, b: var Buffer) =
  b.header(a.th, "Downloading")
  let r = mainBox(b, 100, 11)
  b.box(r, "Downloading " & a.dl.dest.extractFilename, fgs(a.th.muted), a.acc)
  let inn = r.inner
  b.kvRow(inn.x + 1, inn.y, inn.w - 2, 10, "From", [(a.dl.url, a.fg)], a.th)
  b.kvRow(inn.x + 1, inn.y + 1, inn.w - 2, 10, "To", [(a.dl.dest.tilde, a.fg)], a.th)
  let done = a.dl.bytesDone
  let ratio = if a.dl.total > 0: float(done) / float(a.dl.total) else: 0.0
  let label = if a.dl.phase == dlSidecars: "Fetching the checksum and signature…"
              elif a.dl.total > 0: &"{formatBytes(done)} / {formatBytes(a.dl.total)} ({ratio * 100:.1f} %)"
              else: formatBytes(done)
  b.gauge(rect(inn.x + 1, inn.y + 3, inn.w - 2, 1), ratio, label, a.th.accent, a.th.track, a.th)
  b.kvRow(inn.x + 1, inn.y + 5, inn.w - 2, 10, "Speed", [(formatSpeed(a.dl.speed), a.fg)], a.th)
  b.kvRow(inn.x + 1, inn.y + 6, inn.w - 2, 10, "ETA", [(fmtEtaShort(a.dl.eta), a.fg)], a.th)
  if a.dl.resumedFrom > 0 and a.dl.phase == dlFile:
    b.kvRow(inn.x + 1, inn.y + 7, inn.w - 2, 10, "Resumed", [("from " & formatBytes(a.dl.resumedFrom), a.dim)], a.th)
  a.drawStatus(b, b.h - 2)
  b.footer(a.th, [("esc", "stop")])

proc drawImage*(a: App, b: var Buffer) =
  b.header(a.th, "Burn › Image")
  let r = mainBox(b, 110, 12)
  b.box(r, "Image", fgs(a.th.muted), a.acc)
  let inn = r.inner
  let (x, w, kw) = (inn.x + 1, inn.w - 2, 12)
  var size = formatBytes(getFileSize(a.image))
  if not a.fmt.isIdentity and a.est.known:
    size.add " → " & (if a.est.exact: "" else: "at least ") & formatBytes(a.est.size) & " decompressed"
  let fmtText = a.fmt.displayName & (if a.fmt == cfZip: " (" & a.zip.name & ")" else: "")
  b.kvRow(x, inn.y, w, kw, "File", [(a.image.extractFilename, a.bright)], a.th)
  b.kvRow(x, inn.y + 1, w, kw, "Folder", [(a.image.parentDir.tilde.ellipsizeLeft(w - kw), a.fg)], a.th)
  b.kvRow(x, inn.y + 2, w, kw, "Size", [(size, a.fg)], a.th)
  b.kvRow(x, inn.y + 3, w, kw, "Format", [(fmtText, a.fg)], a.th)
  b.kvRow(x, inn.y + 4, w, kw, "Contents", [(a.info.summary, a.fg)], a.th)
  b.kvRow(x, inn.y + 5, w, kw, "Checksum", a.checksumLine, a.th)
  b.kvRow(x, inn.y + 6, w, kw, "Signature", a.sigLine, a.th)
  if a.winMode:
    b.kvRow(x, inn.y + 7, w, kw, "Options", [("verify after copying: " & onOff(a.verify), a.fg)], a.th)
  else:
    b.kvRow(x, inn.y + 7, w, kw, "Options", [("verify after burning: " & onOff(a.verify), a.fg),
                                             ("  ·  check checksum first: " & onOff(a.hashFirst), a.fg)], a.th)
  var y = r.y + r.h + 1
  if a.winMode and not a.editHash:
    y += b.paragraph(rect(r.x + 1, y, r.w - 2, b.h - y - 2), "omnBurn builds a bootable Windows " &
                     "stick from this ISO: one FAT32 partition with its files, which PCs boot in " &
                     "UEFI mode (Secure Boot included). PCs that only boot the old BIOS way can't " &
                     "start it.", a.fg) + 1
    if a.winProblem.len > 0:
      let parts = a.winProblem.splitLines
      for i, part in parts:
        y += b.paragraph(rect(r.x + 1, y, r.w - 2, b.h - y - 2), (if i == 0: "⚠ " else: "  ") & part, a.warnSt)
      inc y
  if a.editHash:
    b.text(r.x + 1, y, "Hash (sha256-…, or just the hex):", a.acc)
    b.textField(r.x + 1, y + 1, r.w - 2, a.hashInput, a.th)
    y += 3
  for wmsg in a.info.warnings:
    y += b.paragraph(rect(r.x + 1, y, r.w - 2, b.h - y - 2), "⚠ " & wmsg, a.warnSt) + 1
  a.drawStatus(b, b.h - 2)
  if a.editHash:
    b.footer(a.th, [("⏎", "use this hash"), ("esc", "cancel")])
  else:
    var hints = @[("⏎", if a.targets.len > 0: "continue" else: "choose drives"), ("c", "checksum"),
                  ("s", "skip checksum"), ("z", "format"), ("v", "verify")]
    if not a.winMode: hints.add ("h", "check first")
    if a.info.windows: hints.add ("m", "check with Microsoft")
    if a.sig.status == ssNoKey: hints.add ("k", "fetch key")
    hints.add ("esc", "back")
    b.footer(a.th, hints)

proc drawHashing*(a: App, b: var Buffer) =
  b.header(a.th, "Burn › Checking the image")
  let r = mainBox(b, 90, 6)
  b.box(r, a.hashTitle, fgs(a.th.muted), a.acc)
  let ratio = if a.hashTotal > 0: float(a.hashDone) / float(a.hashTotal) else: 0.0
  b.gauge(rect(r.x + 2, r.y + 2, r.w - 4, 1), ratio,
          &"{formatBytes(a.hashDone)} / {formatBytes(a.hashTotal)} ({ratio * 100:.1f} %)",
          a.th.cyan, a.th.track, a.th)
  b.footer(a.th, [("esc", "cancel")])

