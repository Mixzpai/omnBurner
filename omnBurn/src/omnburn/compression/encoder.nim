## Streaming compression, for backups.

import ffi, formats

type
  Sink* = proc (p: pointer, n: int)

  Encoder* = ref object
    fmt: CompressionFormat
    zs: ZStream
    lz: LzmaStream
    ctx: pointer
    buf: seq[byte]

proc newEncoder*(fmt: CompressionFormat, totalSize: int64 = -1): Encoder =
  result = Encoder(fmt: fmt, buf: newSeq[byte](1 shl 20))
  case fmt
  of cfIdentity: discard
  of cfGz:
    # level 6, deflate, 15 + 16: gzip header, memLevel 8, default strategy
    if deflateInit2(addr result.zs, 6, 8, 15 + 16, 8, 0) != Z_OK: fail(fmt, "init")
  of cfXz:
    var mt = LzmaMt(threads: threadCount(), preset: 3, check: LZMA_CHECK_CRC64)
    if lzma_stream_encoder_mt(addr result.lz, addr mt) != LZMA_OK: fail(fmt, "init")
  of cfZst:
    result.ctx = ZSTD_createCCtx()
    if result.ctx == nil: fail(fmt, "init")
    discard ZSTD_CCtx_setParameter(result.ctx, ZSTD_c_compressionLevel, 3)
    discard ZSTD_CCtx_setParameter(result.ctx, ZSTD_c_checksumFlag, 1)
    discard ZSTD_CCtx_setParameter(result.ctx, ZSTD_c_nbWorkers, cint(threadCount()))
    if totalSize >= 0: # recorded in the header, so a later burn knows the size
      discard ZSTD_CCtx_setPledgedSrcSize(result.ctx, culonglong(totalSize))
  else: raise newException(ValueError, "can't compress to " & fmt.displayName)

proc encode*(e: Encoder, src: pointer, n: int, finish: bool, sink: Sink) =
  ## Compresses `n` bytes; with `finish`, also ends the stream.
  let outp = addr e.buf[0]
  case e.fmt
  of cfIdentity:
    if n > 0: sink(src, n)
  of cfGz:
    e.zs.next_in = cast[ptr uint8](src)
    e.zs.avail_in = cuint(n)
    while true:
      e.zs.next_out = cast[ptr uint8](outp)
      e.zs.avail_out = cuint(e.buf.len)
      let rc = deflate(addr e.zs, if finish: Z_FINISH else: 0)
      if rc notin [Z_OK, Z_STREAM_END, Z_BUF_ERROR]: fail(e.fmt, "error " & $rc)
      let produced = e.buf.len - int(e.zs.avail_out)
      if produced > 0: sink(outp, produced)
      if finish:
        if rc == Z_STREAM_END: break
      elif e.zs.avail_out != 0: break
  of cfXz:
    e.lz.next_in = cast[ptr uint8](src)
    e.lz.avail_in = csize_t(n)
    while true:
      e.lz.next_out = cast[ptr uint8](outp)
      e.lz.avail_out = csize_t(e.buf.len)
      let rc = lzma_code(addr e.lz, if finish: LZMA_FINISH else: LZMA_RUN)
      if rc notin [LZMA_OK, LZMA_STREAM_END, LZMA_BUF_ERROR]: fail(e.fmt, "error " & $rc)
      let produced = e.buf.len - int(e.lz.avail_out)
      if produced > 0: sink(outp, produced)
      if finish:
        if rc == LZMA_STREAM_END: break
      elif e.lz.avail_in == 0 and e.lz.avail_out != 0: break
  of cfZst:
    var i = ZstdInBuffer(src: src, size: csize_t(n))
    while true:
      var o = ZstdOutBuffer(dst: outp, size: csize_t(e.buf.len))
      let rc = ZSTD_compressStream2(e.ctx, addr o, addr i, if finish: ZSTD_e_end else: ZSTD_e_continue)
      if ZSTD_isError(rc) != 0: fail(e.fmt, $ZSTD_getErrorName(rc))
      if o.pos > 0: sink(outp, int(o.pos))
      if finish:
        if rc == 0: break
      elif i.pos == i.size: break
  else: discard

proc close*(e: Encoder) =
  case e.fmt
  of cfGz: discard deflateEnd(addr e.zs)
  of cfXz: lzma_end(addr e.lz)
  of cfZst: discard ZSTD_freeCCtx(e.ctx)
  else: discard
