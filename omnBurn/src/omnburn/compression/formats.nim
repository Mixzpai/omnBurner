## The compression formats omnBurn knows, detecting them from a file's name
## or contents, and the small file and byte helpers the other compression
## modules share.

import std/[os, posix, strutils]

type
  CompressionFormat* = enum
    cfIdentity = "none", cfGz = "gz", cfBz2 = "bz2", cfXz = "xz", cfLz4 = "lz4",
    cfZst = "zst", cfZip = "zip"

  DecompressError* = object of IOError

const
  AvailableFormats* = [cfIdentity, cfGz, cfBz2, cfXz, cfLz4, cfZst, cfZip]
  BackupFormats* = [cfZst, cfXz, cfGz, cfIdentity]

proc displayName*(cf: CompressionFormat): string =
  case cf
  of cfIdentity: "no compression"
  of cfGz: "gzip"
  of cfBz2: "bzip2"
  of cfXz: "xz/LZMA"
  of cfLz4: "lz4"
  of cfZst: "zstd/ZStandard"
  of cfZip: "zip"

proc extension*(cf: CompressionFormat): string =
  if cf == cfIdentity: "" else: "." & $cf

proc isIdentity*(cf: CompressionFormat): bool = cf == cfIdentity

proc fail*(fmt: CompressionFormat, msg: string) {.noreturn.} =
  raise newException(DecompressError, fmt.displayName & " decompression failed: " & msg)

proc detectFromExtension*(ext: string): CompressionFormat =
  case ext.toLowerAscii.strip(trailing = false, chars = {'.'})
  of "gz": cfGz
  of "bz2": cfBz2
  of "xz": cfXz
  of "lz4": cfLz4
  of "zst": cfZst
  of "zip": cfZip
  else: cfIdentity

proc detectFromPath*(path: string): (bool, CompressionFormat) =
  ## Returns (false, _) when the path has no extension at all.
  let ext = path.splitFile.ext
  if ext.len == 0: (false, cfIdentity) else: (true, detectFromExtension(ext))

proc detectFromMagic*(head: string): (bool, CompressionFormat) =
  const magics = [("\x1f\x8b", cfGz), ("BZh", cfBz2), ("\xfd7zXZ\x00", cfXz),
                  ("\x04\x22\x4d\x18", cfLz4), ("\x28\xb5\x2f\xfd", cfZst), ("PK\x03\x04", cfZip)]
  for (m, cf) in magics:
    if head.startsWith(m): return (true, cf)

proc readAt*(fd: cint, off: int64, n: int): string =
  ## pread() up to `n` bytes at `off`.
  result = newString(max(n, 0))
  if off < 0: return ""
  var got = 0
  while got < n:
    let r = pread(fd, addr result[got], n - got, Off(off + got))
    if r < 0:
      if errno == EINTR: continue
      raiseOSError(osLastError())
    if r == 0: break
    got += r
  result.setLen(got)

proc openRead*(path: string): cint =
  result = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if result < 0: raiseOSError(osLastError(), path)

proc readHead*(path: string, n: int): string =
  let fd = openRead(path)
  defer: discard posix.close(fd)
  readAt(fd, 0, n)

proc detectFormat*(path: string): CompressionFormat =
  ## Detects compression from the file's contents rather than its name.
  let (found, cf) = detectFromMagic(readHead(path, 8))
  if found: cf else: cfIdentity

# Little-endian integers, as zip, xz and lz4 headers store them.
proc u16*(s: string, i: int): int64 = int64(ord(s[i])) or int64(ord(s[i + 1])) shl 8
proc u32*(s: string, i: int): int64 = u16(s, i) or u16(s, i + 2) shl 16
proc u64*(s: string, i: int): int64 = u32(s, i) or u32(s, i + 4) shl 32
