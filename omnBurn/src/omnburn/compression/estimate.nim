## How big an image is once decompressed, read from the compressed file's
## headers and trailers where the format records it.

import std/[os, posix]
import ffi, formats, zip

type
  SizeEstimate* = object
    known*: bool
    exact*: bool ## otherwise `size` is a lower bound
    size*: int64

proc estimateSize*(path: string, cf: CompressionFormat, zip = ZipEntry()): SizeEstimate =
  ## How big the image is once decompressed, if we can tell without
  ## decompressing it.
  try:
    let fileSize = getFileSize(path)
    let fd = openRead(path)
    defer: discard posix.close(fd)
    case cf
    of cfIdentity: return SizeEstimate(known: true, exact: true, size: fileSize)
    of cfZip: return SizeEstimate(known: true, exact: true, size: zip.size)
    of cfBz2: return
    of cfGz:
      # ISIZE is the last member's size mod 2^32, so the image is at least that.
      let t = readAt(fd, fileSize - 4, 4)
      if t.len == 4: return SizeEstimate(known: true, size: u32(t, 0))
    of cfZst:
      let head = readAt(fd, 0, 18)
      if head.len == 0: return
      let r = ZSTD_getFrameContentSize(unsafeAddr head[0], csize_t(head.len))
      if r < culonglong(high(int64)): return SizeEstimate(known: true, size: int64(r))
    of cfLz4:
      let h = readAt(fd, 0, 14)
      if h.len >= 14 and (ord(h[4]) and 0x08) != 0: # content size flag
        return SizeEstimate(known: true, size: u64(h, 6))
    of cfXz:
      # Walk the streams backwards using their indexes; this is exact.
      var pos = fileSize
      var total: int64
      while pos > 0:
        while pos >= 4 and readAt(fd, pos - 4, 4) == "\0\0\0\0": pos -= 4 # stream padding
        let footer = readAt(fd, pos - 12, 12)
        if footer.len != 12 or footer[10 .. 11] != "YZ": return
        let backward = (u32(footer, 4) + 1) * 4
        let idxBytes = readAt(fd, pos - 12 - backward, int(backward))
        if idxBytes.len != int(backward): return
        var idx: ptr LzmaIndex
        var memlimit = high(uint64)
        var inPos: csize_t
        if lzma_index_buffer_decode(addr idx, addr memlimit, nil, cast[ptr uint8](unsafeAddr idxBytes[0]),
                                    addr inPos, csize_t(idxBytes.len)) != LZMA_OK: return
        total += int64(lzma_index_uncompressed_size(idx))
        pos -= int64(lzma_index_file_size(idx))
        lzma_index_end(idx, nil)
      return SizeEstimate(known: true, exact: true, size: total)
  except CatchableError: discard
