## Reusable pieces of the full-screen UI: styled text runs, header/footer
## bars, gauges, the hex view of the data going by, list rows and modals.

import std/[math, strutils, unicode]
import ../theme
import screen

type
  Seg* = tuple[text: string, st: Style]

  HexRow* = tuple
    offset: int64
    bytes: string
    color: Color ## for the offset

proc ellipsize*(s: string, w: int): string =
  ## Cuts `s` to `w` columns, with a "…" if it didn't fit.
  if w <= 0: return ""
  if s.runeLen <= w: s
  elif w == 1: "…"
  else: s.runeSubStr(0, w - 1) & "…"

proc padTo*(s: string, w: int): string =
  ## `s` padded with spaces to `w` columns (alignLeft counts bytes, not columns).
  result = s
  for _ in s.runeLen ..< w: result.add ' '

proc ellipsizeLeft*(s: string, w: int): string =
  ## Like `ellipsize`, but keeps the end (for paths).
  if w <= 0: return ""
  let n = s.runeLen
  if n <= w: s else: "…" & s.runeSubStr(n - w + 1)

proc segs*(b: var Buffer, x, y: int, s: openArray[Seg], maxW = high(int)): int {.discardable.} =
  ## Draws styled runs side by side, cut at `maxW` columns. Returns the width.
  for seg in s:
    if result >= maxW: break
    result += b.text(x + result, y, seg.text, seg.st, maxW - result)

proc segsWidth*(s: openArray[Seg]): int =
  for seg in s: result += seg.text.runeLen

proc header*(b: var Buffer, th: Theme, title: string) =
  b.fill(rect(0, 0, b.w, 1), Style(bg: th.selection))
  let x = b.segs(0, 0, [(" omnBurn ", Style(fg: th.bg, bg: th.accent, bold: true)),
                        (" " & title, Style(fg: th.fg, bg: th.selection, bold: true))], b.w)
  let right = "theme: " & th.name & " "
  if x + right.runeLen + 2 < b.w:
    b.text(b.w - right.runeLen, 0, right, Style(fg: th.dim, bg: th.selection))

proc footer*(b: var Buffer, th: Theme, hints: openArray[(string, string)]) =
  ## Key hints along the bottom row, like "⏎ select  esc back".
  var x = 1
  let y = b.h - 1
  for (k, label) in hints:
    let w = k.runeLen + label.runeLen + 3
    if x + w > b.w: break
    x += b.text(x, y, k, fgs(th.accent, bold = true))
    x += b.text(x, y, " " & label & "  ", fgs(th.dim))

proc gauge*(b: var Buffer, r: Rect, ratio: float, label: string, bar, track: Color, th: Theme,
            trackIsColor = false) =
  ## A one-row progress bar with a centered label.
  var ratio = if ratio.isNaN: 0.0 else: clamp(ratio, 0.0, 1.0)
  let filled = int(ratio * float(r.w))
  # Reverse video puts the theme background behind the label on colored
  # cells, which keeps it readable on any palette.
  let onBar = Style(fg: bar, bg: th.bg, reverse: true, bold: true)
  let onTrack =
    if trackIsColor: Style(fg: track, bg: th.bg, reverse: true)
    else: Style(fg: th.fg, bg: track)
  for i in 0 ..< r.w: b.set(r.x + i, r.y, " ", if i < filled: onBar else: onTrack)
  let l = label.ellipsize(r.w)
  let x0 = r.x + max((r.w - l.runeLen) div 2, 0)
  var j = 0
  for ch in l.runes:
    let x = x0 + j
    b.set(x, r.y, $ch, if x - r.x < filled: onBar else: onTrack)
    inc j

proc byteStyle(c: char, th: Theme): Style =
  ## A byte's color in the hex view, by kind, so text and padding stand out.
  case c
  of '\0': fgs(th.dim)
  of '!' .. '~': fgs(th.fg)
  of ' ', '\t', '\n', '\r', '\x01' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f', '\x7f': fgs(th.green)
  else: fgs(th.accent)

proc byteGlyph(c: char): string =
  ## A byte in the hex view's text column.
  case c
  of ' ' .. '~': $c
  of '\0': "·"
  else: "•"

proc hexDump*(b: var Buffer, area: Rect, title: string, rows: openArray[HexRow], total: int64,
              th: Theme, empty = "") =
  ## A boxed hex dump in the style of `hexdump -C`, of the last `rows` that
  ## fit (the newest at the bottom), or `empty` if there are none yet.
  ## Offsets have enough digits for `total`.
  b.box(area, title, fgs(th.muted), fgs(th.accent, bold = true))
  let inner = area.inner
  if inner.w < 16 or inner.h < 1: return
  if rows.len == 0:
    b.text(inner.x + max((inner.w - empty.runeLen) div 2, 0), inner.y + (inner.h - 1) div 2, empty,
           fgs(th.dim), inner.w)
    return
  var digits = 8
  while digits < 16 and (total shr (4 * digits)) > 0: inc digits
  # 16 bytes a row with the text column if they fit, else 8, else 8 alone
  proc width(per: int, text: bool): int = # the space after the last byte separates the text
    digits + 2 + per * 3 + (if per > 8: 1 else: 0) + (if text: per + 2 else: -1)
  let (per, text) = if width(16, true) <= inner.w: (16, true)
                    elif width(8, true) <= inner.w: (8, true)
                    else: (8, false)
  let x0 = inner.x + max((inner.w - width(per, text)) div 2, 0)
  let shown = min(rows.len, inner.h)
  for r in 0 ..< shown:
    let row = rows[rows.len - shown + r]
    let y = inner.y + r
    b.text(x0, y, toHex(row.offset, digits).toLowerAscii, fgs(row.color), inner.w)
    var x = x0 + digits + 2
    for i in 0 ..< per:
      if i == 8: inc x
      if i < row.bytes.len: b.text(x, y, toHex(ord(row.bytes[i]), 2).toLowerAscii,
                                   byteStyle(row.bytes[i], th))
      x += 3
    if text:
      b.text(x, y, "│", fgs(th.muted))
      for i in 0 ..< min(per, row.bytes.len):
        b.set(x + 1 + i, y, byteGlyph(row.bytes[i]), byteStyle(row.bytes[i], th))
      b.text(x + 1 + per, y, "│", fgs(th.muted))

proc row*(b: var Buffer, x, y, w: int, s: openArray[Seg], selected: bool, th: Theme) =
  ## A list row; the selected one gets the theme's selection background.
  if selected:
    b.fill(rect(x, y, w, 1), Style(bg: th.selection))
    var hl: seq[Seg]
    for seg in s:
      var st = seg.st
      st.bg = th.selection
      hl.add (seg.text, st)
    b.segs(x, y, hl, w)
  else:
    b.segs(x, y, s, w)

proc modal*(b: var Buffer, title: string, lines: openArray[seq[Seg]], th: Theme,
            border: Color, width = 64) =
  ## A centered dialog over whatever is drawn.
  let w = min(width, b.w - 4)
  let r = centered(rect(0, 0, b.w, b.h), w, lines.len + 4)
  let bg = Style(fg: th.fg, bg: th.bg)
  b.fill(r, bg)
  b.box(r, title, Style(fg: border, bg: th.bg), Style(fg: border, bg: th.bg, bold: true))
  for i, l in lines:
    var withBg: seq[Seg]
    for seg in l:
      var st = seg.st
      if st.bg.kind == ckDefault: st.bg = th.bg
      withBg.add (seg.text, st)
    b.segs(r.x + 2, r.y + 2 + i, withBg, r.w - 4)

proc paragraph*(b: var Buffer, r: Rect, text: string, st: Style): int {.discardable.} =
  ## Word-wrapped text. Returns the rows used.
  for i, l in wrapText(text, r.w):
    if i >= r.h: break
    b.text(r.x, r.y + i, l, st, r.w)
    result = i + 1

proc kvRow*(b: var Buffer, x, y, w, keyW: int, key: string, value: openArray[Seg], th: Theme) =
  b.text(x, y, key.ellipsize(keyW - 1), fgs(th.accent), keyW)
  b.segs(x + keyW, y, value, w - keyW)

proc textField*(b: var Buffer, x, y, w: int, value: string, th: Theme, active = true) =
  ## A one-line input showing the end of `value` and a block cursor.
  let shown = value.ellipsizeLeft(w - 1)
  b.fill(rect(x, y, w, 1), Style(bg: th.selection))
  b.text(x, y, shown, Style(fg: th.bright, bg: th.selection), w)
  if active: b.set(x + shown.runeLen, y, " ", Style(fg: th.bg, bg: th.accent))
