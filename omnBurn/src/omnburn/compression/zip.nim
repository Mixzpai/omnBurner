## Finding the image inside a zip archive, by reading the archive's central
## directory (zip64 included).

import std/[os, posix, strutils]
import formats

type
  ZipEntry* = object
    ## The member of a zip archive that holds the image.
    name*: string
    stored*: bool ## not compressed (method 0); otherwise deflate
    dataOffset*, compSize*, size*: int64

proc findZipEntry*(path: string): ZipEntry =
  ## Finds the largest file in a zip archive, which we take to be the image.
  ## Raises ValueError for archives we can't burn from.
  let fd = openRead(path)
  defer: discard posix.close(fd)
  let size = getFileSize(path)
  let tailStart = max(size - 65_557, 0)
  let tail = readAt(fd, tailStart, int(size - tailStart))
  let eocd = tail.rfind("PK\x05\x06")
  if eocd < 0 or eocd + 22 > tail.len: raise newException(ValueError, "not a zip archive")
  var entries = u16(tail, eocd + 10)
  var cdOffset = u32(tail, eocd + 16)
  if entries == 0xffff or cdOffset == 0xffff_ffff:
    let loc = eocd - 20 # zip64 end of central directory locator
    if loc < 0 or tail[loc ..< loc + 4] != "PK\x06\x07":
      raise newException(ValueError, "broken zip64 archive")
    let rec = readAt(fd, u64(tail, loc + 8), 56)
    if rec.len < 56 or not rec.startsWith("PK\x06\x06"):
      raise newException(ValueError, "broken zip64 archive")
    entries = u64(rec, 32)
    cdOffset = u64(rec, 48)

  var best: ZipEntry
  var found = false
  var off = cdOffset
  for _ in 0 ..< entries:
    let h = readAt(fd, off, 46)
    if h.len < 46 or not h.startsWith("PK\x01\x02"): raise newException(ValueError, "broken zip archive")
    let (flags, meth) = (u16(h, 8), u16(h, 10))
    var (comp, uncomp, local) = (u32(h, 20), u32(h, 24), u32(h, 42))
    let (nameLen, extraLen, commentLen) = (int(u16(h, 28)), int(u16(h, 30)), int(u16(h, 32)))
    let rest = readAt(fd, off + 46, nameLen + extraLen)
    if rest.len < nameLen + extraLen: raise newException(ValueError, "broken zip archive")
    let name = rest[0 ..< nameLen]
    var x = nameLen
    while x + 4 <= rest.len: # zip64 sizes live in extra field 0x0001
      let (id, sz) = (u16(rest, x), int(u16(rest, x + 2)))
      if id == 1:
        var p = x + 4
        if uncomp == 0xffff_ffff and p + 8 <= rest.len: (uncomp = u64(rest, p); p += 8)
        if comp == 0xffff_ffff and p + 8 <= rest.len: (comp = u64(rest, p); p += 8)
        if local == 0xffff_ffff and p + 8 <= rest.len: local = u64(rest, p)
      x += 4 + sz
    off += 46 + nameLen + extraLen + commentLen
    if name.endsWith("/") or (found and uncomp < best.size): continue
    if (flags and 1) != 0: raise newException(ValueError, name & " is encrypted")
    if meth notin [0'i64, 8]:
      raise newException(ValueError, name & " uses an unsupported compression method")
    best = ZipEntry(name: name, stored: meth == 0, compSize: comp, size: uncomp, dataOffset: local)
    found = true
  if not found: raise newException(ValueError, "the zip archive is empty")
  let lh = readAt(fd, best.dataOffset, 30)
  if lh.len < 30 or not lh.startsWith("PK\x03\x04"): raise newException(ValueError, "broken zip archive")
  best.dataOffset += 30 + u16(lh, 26) + u16(lh, 28)
  best
