## Reading an image: `Source` is a decompressing, byte-counting reader over a
## file descriptor, built on a `Decoder` that gives every format the same
## streaming interface.

import std/[os, posix]
import ffi, formats, zip

# ---------------------------------------------------------------------------
# Decoder

type
  Bytes = ptr UncheckedArray[byte]

  Decoder = ref object
    fmt: CompressionFormat
    atBoundary: bool ## the last call ended a complete stream/frame
    memberDone: bool ## gz/bz2: a member ended, maybe another follows
    trailing: bool   ## skipping bytes after the last member
    zs: ZStream
    bz: BzStream
    lz: LzmaStream
    ctx: pointer     ## lz4 / zstd context

proc newDecoder(fmt: CompressionFormat): Decoder =
  result = Decoder(fmt: fmt, atBoundary: fmt == cfIdentity)
  case fmt
  of cfIdentity: discard
  of cfGz:
    # 15 + 32: maximum window, detect gzip or zlib headers automatically
    if inflateInit2(addr result.zs, 15 + 32) != Z_OK: fail(fmt, "init")
  of cfZip:
    if inflateInit2(addr result.zs, -15) != Z_OK: fail(fmt, "init") # raw deflate
  of cfBz2:
    if BZ2_bzDecompressInit(addr result.bz, 0, 0) != BZ_OK: fail(fmt, "init")
  of cfXz:
    # Multi-threaded decoding needs files with several blocks (xz -T0 makes
    # those); others decode single-threaded just the same.
    var mt = LzmaMt(flags: LZMA_CONCATENATED, threads: threadCount(),
                    memlimit_threading: 1'u64 shl 30, memlimit_stop: high(uint64))
    if lzma_stream_decoder_mt(addr result.lz, addr mt) != LZMA_OK and
       lzma_stream_decoder(addr result.lz, high(uint64), LZMA_CONCATENATED) != LZMA_OK:
      fail(fmt, "init")
  of cfLz4:
    if LZ4F_isError(LZ4F_createDecompressionContext(addr result.ctx, LZ4F_VERSION)) != 0:
      fail(fmt, "init")
  of cfZst:
    result.ctx = ZSTD_createDStream()
    if result.ctx == nil: fail(fmt, "init")

proc close(d: Decoder) =
  case d.fmt
  of cfIdentity: discard
  of cfGz, cfZip: discard inflateEnd(addr d.zs)
  of cfBz2: discard BZ2_bzDecompressEnd(addr d.bz)
  of cfXz: lzma_end(addr d.lz)
  of cfLz4: discard LZ4F_freeDecompressionContext(d.ctx)
  of cfZst: discard ZSTD_freeDStream(d.ctx)

proc nextMember(d: Decoder, src: Bytes, srcLen: int): bool =
  ## gzip and bzip2 files may hold several concatenated members. Returns true
  ## if decoding should continue with a fresh member.
  if not d.memberDone: return true
  if srcLen == 0: return false
  let magic = if d.fmt == cfGz: 0x1f'u8 else: uint8(ord('B'))
  if d.fmt == cfZip or src[0] != magic:
    d.trailing = true # padding or garbage after the last member; ignore it
    return false
  d.memberDone = false
  if d.fmt == cfGz:
    discard inflateReset(addr d.zs)
  else:
    discard BZ2_bzDecompressEnd(addr d.bz)
    d.bz = BzStream()
    if BZ2_bzDecompressInit(addr d.bz, 0, 0) != BZ_OK: fail(d.fmt, "init")
  true

proc step(d: Decoder, src: Bytes, srcLen: int, dst: Bytes, dstLen: int,
          inputEof: bool): (int, int) =
  ## Decodes some of `src` into `dst`. Returns (consumed, produced).
  if d.trailing: return (srcLen, 0)
  case d.fmt
  of cfIdentity:
    let n = min(srcLen, dstLen)
    if n > 0: copyMem(dst, src, n)
    (n, n)
  of cfGz, cfZip:
    if not d.nextMember(src, srcLen): return ((if d.trailing: srcLen else: 0), 0)
    d.zs.next_in = cast[ptr uint8](src)
    d.zs.avail_in = cuint(srcLen)
    d.zs.next_out = cast[ptr uint8](dst)
    d.zs.avail_out = cuint(dstLen)
    let rc = inflate(addr d.zs, 0)
    case rc
    of Z_OK, Z_BUF_ERROR: d.atBoundary = false
    of Z_STREAM_END: d.atBoundary = true; d.memberDone = true
    else: fail(d.fmt, if d.zs.msg != nil: $d.zs.msg else: "error " & $rc)
    (srcLen - int(d.zs.avail_in), dstLen - int(d.zs.avail_out))
  of cfBz2:
    if not d.nextMember(src, srcLen): return ((if d.trailing: srcLen else: 0), 0)
    d.bz.next_in = cast[cstring](src)
    d.bz.avail_in = cuint(srcLen)
    d.bz.next_out = cast[cstring](dst)
    d.bz.avail_out = cuint(dstLen)
    let rc = BZ2_bzDecompress(addr d.bz)
    case rc
    of BZ_OK: d.atBoundary = false
    of BZ_STREAM_END: d.atBoundary = true; d.memberDone = true
    else: fail(d.fmt, "error " & $rc)
    (srcLen - int(d.bz.avail_in), dstLen - int(d.bz.avail_out))
  of cfXz:
    d.lz.next_in = cast[ptr uint8](src)
    d.lz.avail_in = csize_t(srcLen)
    d.lz.next_out = cast[ptr uint8](dst)
    d.lz.avail_out = csize_t(dstLen)
    let rc = lzma_code(addr d.lz, if inputEof: LZMA_FINISH else: LZMA_RUN)
    case rc
    of LZMA_OK, LZMA_BUF_ERROR: d.atBoundary = false
    of LZMA_STREAM_END: d.atBoundary = true
    else: fail(d.fmt, "error " & $rc)
    (srcLen - int(d.lz.avail_in), dstLen - int(d.lz.avail_out))
  of cfLz4:
    var dsz = csize_t(dstLen)
    var ssz = csize_t(srcLen)
    let hint = LZ4F_decompress(d.ctx, dst, addr dsz, src, addr ssz, nil)
    if LZ4F_isError(hint) != 0: fail(d.fmt, $LZ4F_getErrorName(hint))
    # A call that did nothing returns the next frame's header size; ignore it.
    if ssz > 0 or dsz > 0: d.atBoundary = hint == 0
    (int(ssz), int(dsz))
  of cfZst:
    var i = ZstdInBuffer(src: src, size: csize_t(srcLen))
    var o = ZstdOutBuffer(dst: dst, size: csize_t(dstLen))
    let rc = ZSTD_decompressStream(d.ctx, addr o, addr i)
    if ZSTD_isError(rc) != 0: fail(d.fmt, $ZSTD_getErrorName(rc))
    if i.pos > 0 or o.pos > 0: d.atBoundary = rc == 0
    (int(i.pos), int(o.pos))

# ---------------------------------------------------------------------------
# Source

type
  RawTap* = proc (p: pointer, n: int, ctx: pointer) {.nimcall, gcsafe.}
    ## Sees every raw (still compressed) byte that is read.

  Source* = object
    fd*: cint
    kind: CompressionFormat ## what the decoder does (stored zip = identity)
    dec: Decoder
    raw: seq[byte]
    pos, len: int
    rawEof: bool
    start: int64 ## zip: where the member's data starts
    limit: int64 ## zip: where it ends; -1 for no limit
    drained: bool
    rawBytes*: int64 ## bytes read from the file, before decompression
    outBytes*: int64 ## bytes produced, after decompression
    tap*: RawTap
    tapCtx*: pointer

proc readRetry*(fd: cint, buf: pointer, n: int): int =
  while true:
    let r = posix.read(fd, buf, n)
    if r >= 0: return r
    if errno != EINTR: raiseOSError(osLastError())

proc openSource*(fd: cint, fmt: CompressionFormat, bufSize = 1 shl 20, zip = ZipEntry()): Source =
  ## Reads from `fd`, which must be at the start of the file, or at least of
  ## the compressed data. For zip archives, only the member in `zip` is
  ## decompressed, but a `tap` still sees the whole file.
  result = Source(fd: fd, kind: fmt, limit: -1)
  if fmt == cfZip:
    result.start = zip.dataOffset
    result.limit = zip.dataOffset + zip.compSize
    if zip.stored: result.kind = cfIdentity
  result.dec = newDecoder(result.kind)
  if result.kind != cfIdentity: result.raw = newSeq[byte](bufSize)

proc close*(s: var Source) =
  if s.dec != nil:
    s.dec.close()
    s.dec = nil

proc room(s: Source, n: int): int =
  if s.limit < 0: n else: int(min(int64(n), s.limit - s.rawBytes))

proc passOver(s: var Source, until: int64) =
  ## Reads raw bytes we don't decode (outside the zip member) for the tap.
  if s.tap == nil:
    if until != high(int64):
      if lseek(s.fd, Off(until), SEEK_SET) < 0: raiseOSError(osLastError())
      s.rawBytes = until
    return
  var tmp: array[65536, byte]
  while s.rawBytes < until:
    let r = readRetry(s.fd, addr tmp, int(min(int64(tmp.len), until - s.rawBytes)))
    if r == 0: break
    s.tap(addr tmp, r, s.tapCtx)
    s.rawBytes += r

proc readInner(s: var Source, dst: pointer, n: int): int =
  if s.kind == cfIdentity:
    let want = s.room(n)
    if want <= 0: return 0
    result = readRetry(s.fd, dst, want)
    if s.tap != nil and result > 0: s.tap(dst, result, s.tapCtx)
    s.rawBytes += result
    s.outBytes += result
    return
  let base = cast[Bytes](addr s.raw[0])
  while true:
    if s.pos == s.len and not s.rawEof:
      s.pos = 0
      let want = s.room(s.raw.len)
      s.len = if want > 0: readRetry(s.fd, base, want) else: 0
      if s.tap != nil and s.len > 0: s.tap(base, s.len, s.tapCtx)
      s.rawBytes += s.len
      s.rawEof = s.len == 0
    let (consumed, produced) = s.dec.step(cast[Bytes](addr base[s.pos]), s.len - s.pos,
                                          cast[Bytes](dst), n, s.rawEof)
    s.pos += consumed
    if produced > 0:
      s.outBytes += produced
      return produced
    if s.rawEof and s.pos == s.len:
      if s.dec.atBoundary or s.dec.trailing: return 0
      if consumed == 0:
        raise newException(DecompressError, "unexpected end of " & s.kind.displayName &
                           " data. Is the file truncated?")
    elif consumed == 0 and s.pos < s.len:
      fail(s.kind, "decoder stalled")

proc read*(s: var Source, dst: pointer, n: int): int =
  ## Reads up to `n` decompressed bytes. Returns 0 at the end of the input.
  if n <= 0: return 0
  if s.rawBytes < s.start: s.passOver(s.start)
  result = s.readInner(dst, n)
  if result == 0 and s.limit >= 0 and not s.drained:
    s.drained = true
    if s.tap != nil: s.passOver(high(int64))

proc readFull*(s: var Source, dst: pointer, n: int): int =
  ## Like `read`, but keeps going until `dst` is full or the input ends.
  let d = cast[Bytes](dst)
  while result < n:
    let r = s.read(addr d[result], n - result)
    if r == 0: break
    result += r

proc openImage*(path: string, fmt: CompressionFormat, zip = ZipEntry(), bufSize = 1 shl 20): Source =
  ## Opens `path` for decompressed reading. Close the fd with `closeImage`.
  openSource(openRead(path), fmt, bufSize, zip)

proc closeImage*(s: var Source) =
  s.close()
  discard posix.close(s.fd)
