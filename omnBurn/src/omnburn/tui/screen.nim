## A tiny double-buffered terminal renderer: a grid of styled cells, drawing
## helpers (text, boxes), and a diff-based flush.

import std/[strutils, unicode]
import ../theme

type
  Rect* = object
    x*, y*, w*, h*: int

  Cell = object
    ch: string
    st: Style

  Buffer* = object
    w*, h*: int
    cells: seq[Cell]

proc rect*(x, y, w, h: int): Rect = Rect(x: x, y: y, w: max(w, 0), h: max(h, 0))
proc inner*(r: Rect): Rect = rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2)

proc centered*(outer: Rect, w, h: int): Rect =
  rect(outer.x + (outer.w - w) div 2, outer.y + (outer.h - h) div 2, min(w, outer.w), min(h, outer.h))

proc newBuffer*(w, h: int): Buffer =
  Buffer(w: w, h: h, cells: newSeq[Cell](w * h))

proc clear*(b: var Buffer) =
  for c in b.cells.mitems: c = Cell(ch: " ")

proc set*(b: var Buffer, x, y: int, ch: string, st: Style) =
  if x >= 0 and y >= 0 and x < b.w and y < b.h:
    b.cells[y * b.w + x] = Cell(ch: ch, st: st)

proc text*(b: var Buffer, x, y: int, s: string, st: Style, maxW = high(int)): int {.discardable.} =
  ## Writes `s` starting at (x, y), at most `maxW` columns. Returns the width.
  for r in s.runes:
    if result >= maxW: break
    b.set(x + result, y, $r, st)
    inc result

proc fill*(b: var Buffer, r: Rect, st: Style) =
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w: b.set(x, y, " ", st)

proc box*(b: var Buffer, r: Rect, title: string, border, titleSt: Style,
          rightTitle = "", rightSt = Style()) =
  if r.w < 2 or r.h < 2: return
  let (x1, y1) = (r.x + r.w - 1, r.y + r.h - 1)
  for x in r.x + 1 ..< x1:
    b.set(x, r.y, "─", border)
    b.set(x, y1, "─", border)
  for y in r.y + 1 ..< y1:
    b.set(r.x, y, "│", border)
    b.set(x1, y, "│", border)
  b.set(r.x, r.y, "╭", border)
  b.set(x1, r.y, "╮", border)
  b.set(r.x, y1, "╰", border)
  b.set(x1, y1, "╯", border)
  if title.len > 0: b.text(r.x + 2, r.y, " " & title & " ", titleSt, r.w - 4)
  if rightTitle.len > 0:
    let t = " " & rightTitle & " "
    if t.runeLen + title.runeLen + 8 <= r.w:
      b.text(x1 - 1 - t.runeLen, r.y, t, rightSt)

proc wrapText*(s: string, width: int): seq[string] =
  ## Greedy word wrap, keeping explicit newlines.
  for para in s.splitLines:
    var line = ""
    for word in strutils.splitWhitespace(para):
      if line.len > 0 and line.runeLen + 1 + word.runeLen > width:
        result.add line
        line = ""
      if line.len > 0: line.add ' '
      line.add word
    result.add line

proc flush*(prev: var Buffer, cur: Buffer): string =
  ## Escape codes turning the screen from `prev` into `cur`. A size change
  ## repaints everything.
  let full = prev.w != cur.w or prev.h != cur.h
  result = "\e[?2026h" # synchronized update: no tearing on supporting terminals
  if full: result.add "\e[0m\e[2J"
  var lastSt: Style
  var haveSt = false
  var cx, cy = -1
  for y in 0 ..< cur.h:
    for x in 0 ..< cur.w:
      let c = cur.cells[y * cur.w + x]
      if not full and prev.cells[y * cur.w + x] == c: continue
      if cx != x or cy != y: result.add "\e[" & $(y + 1) & ";" & $(x + 1) & "H"
      if not haveSt or c.st != lastSt:
        result.add sgr(c.st)
        lastSt = c.st
        haveSt = true
      result.add(if c.ch.len > 0: c.ch else: " ")
      cx = x + 1
      cy = y
  result.add "\e[0m\e[?2026l"
  prev = cur
