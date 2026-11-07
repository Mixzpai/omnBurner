## Windows ISOs come only from Microsoft's website, in a browser. What we can
## do is check one against the checksums Microsoft publishes on that page.

import std/strutils
import web

const
  WindowsPage* = "https://www.microsoft.com/software-download/windows11"
    ## Microsoft hands out ISO links only here, in a browser.

proc parseWindowsHashes*(page: string): seq[tuple[label, sha256: string]] =
  ## The "Hash values for the ISO files" table on Microsoft's download page:
  ## a cell naming the language ("English 64-bit"), then one with its hash.
  var cells: seq[string]
  var cell = ""
  var i = 0
  while i < page.len:
    if page[i] == '<':
      cells.add cell.strip
      cell = ""
      let j = page.find('>', i)
      i = if j < 0: page.len else: j + 1
    else:
      cell.add page[i]
      inc i
  var label = ""
  for c in cells:
    if c.len == 64 and c.allCharsInSet(HexDigits):
      if label.len > 0: result.add (label.replace("&amp;", "&"), c.toLowerAscii)
      label = ""
    elif c.len > 0: label = c

proc windowsHashes*(): seq[tuple[label, sha256: string]] =
  ## SHA-256 checksums of the current Windows 11 ISOs, per language.
  result = parseWindowsHashes(fetchText("https://www.microsoft.com/en-us/software-download/windows11"))
  if result.len == 0: raise newException(FetchError, "no checksums found on microsoft.com")

proc windowsHashLabel*(table: openArray[tuple[label, sha256: string]], sha256: string): string =
  ## Which ISO in Microsoft's table has this checksum, or "".
  for (label, h) in table:
    if h == sha256.toLowerAscii: return label
