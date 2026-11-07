## Bindings to the system's zlib, bzip2, xz (liblzma), lz4 and zstd
## libraries: just the types, functions and constants omnBurn uses.

import std/cpuinfo

{.passL: "-lz -lbz2 -llzma -llz4 -lzstd".}

type
  ZStream* {.importc: "z_stream", header: "<zlib.h>".} = object
    next_in*: ptr uint8
    avail_in*: cuint
    next_out*: ptr uint8
    avail_out*: cuint
    msg*: cstring

  BzStream* {.importc: "bz_stream", header: "<bzlib.h>".} = object
    next_in*: cstring
    avail_in*: cuint
    next_out*: cstring
    avail_out*: cuint

  LzmaStream* {.importc: "lzma_stream", header: "<lzma.h>".} = object
    next_in*: ptr uint8
    avail_in*: csize_t
    next_out*: ptr uint8
    avail_out*: csize_t

  LzmaMt* {.importc: "lzma_mt", header: "<lzma.h>".} = object
    flags*, threads*, timeout*, preset*: uint32
    check*: cint
    memlimit_threading*, memlimit_stop*: uint64

  LzmaIndex* {.importc: "lzma_index", header: "<lzma.h>", incompleteStruct.} = object

  ZstdInBuffer* = object
    src*: pointer
    size*, pos*: csize_t

  ZstdOutBuffer* = object
    dst*: pointer
    size*, pos*: csize_t

proc inflateInit2*(s: ptr ZStream, windowBits: cint): cint {.importc, header: "<zlib.h>".}
proc inflate*(s: ptr ZStream, flush: cint): cint {.importc, header: "<zlib.h>".}
proc inflateReset*(s: ptr ZStream): cint {.importc, header: "<zlib.h>".}
proc inflateEnd*(s: ptr ZStream): cint {.importc, header: "<zlib.h>".}
proc deflateInit2*(s: ptr ZStream, level, meth, windowBits, memLevel, strategy: cint): cint {.importc, header: "<zlib.h>".}
proc deflate*(s: ptr ZStream, flush: cint): cint {.importc, header: "<zlib.h>".}
proc deflateEnd*(s: ptr ZStream): cint {.importc, header: "<zlib.h>".}

proc BZ2_bzDecompressInit*(s: ptr BzStream, verbosity, small: cint): cint {.importc, header: "<bzlib.h>".}
proc BZ2_bzDecompress*(s: ptr BzStream): cint {.importc, header: "<bzlib.h>".}
proc BZ2_bzDecompressEnd*(s: ptr BzStream): cint {.importc, header: "<bzlib.h>".}

proc lzma_stream_decoder*(s: ptr LzmaStream, memlimit: uint64, flags: uint32): cint {.importc, header: "<lzma.h>".}
proc lzma_stream_decoder_mt*(s: ptr LzmaStream, mt: ptr LzmaMt): cint {.importc, header: "<lzma.h>".}
proc lzma_stream_encoder_mt*(s: ptr LzmaStream, mt: ptr LzmaMt): cint {.importc, header: "<lzma.h>".}
proc lzma_code*(s: ptr LzmaStream, action: cint): cint {.importc, header: "<lzma.h>".}
proc lzma_end*(s: ptr LzmaStream) {.importc, header: "<lzma.h>".}
proc lzma_index_buffer_decode*(i: ptr ptr LzmaIndex, memlimit: ptr uint64, allocator: pointer,
                               inp: ptr uint8, inPos: ptr csize_t, inSize: csize_t): cint {.importc, header: "<lzma.h>".}
proc lzma_index_uncompressed_size*(i: ptr LzmaIndex): uint64 {.importc, header: "<lzma.h>".}
proc lzma_index_file_size*(i: ptr LzmaIndex): uint64 {.importc, header: "<lzma.h>".}
proc lzma_index_end*(i: ptr LzmaIndex, allocator: pointer) {.importc, header: "<lzma.h>".}

proc LZ4F_createDecompressionContext*(ctx: ptr pointer, version: cuint): csize_t {.importc, cdecl.}
proc LZ4F_freeDecompressionContext*(ctx: pointer): csize_t {.importc, cdecl.}
proc LZ4F_decompress*(ctx, dst: pointer, dstSize: ptr csize_t, src: pointer,
                      srcSize: ptr csize_t, opts: pointer): csize_t {.importc, cdecl.}
proc LZ4F_isError*(code: csize_t): cuint {.importc, cdecl.}
proc LZ4F_getErrorName*(code: csize_t): cstring {.importc, cdecl.}

proc ZSTD_createDStream*(): pointer {.importc, cdecl.}
proc ZSTD_freeDStream*(ds: pointer): csize_t {.importc, cdecl.}
proc ZSTD_decompressStream*(ds: pointer, o: ptr ZstdOutBuffer, i: ptr ZstdInBuffer): csize_t {.importc, cdecl.}
proc ZSTD_createCCtx*(): pointer {.importc, cdecl.}
proc ZSTD_freeCCtx*(c: pointer): csize_t {.importc, cdecl.}
proc ZSTD_CCtx_setParameter*(c: pointer, param, value: cint): csize_t {.importc, cdecl.}
proc ZSTD_CCtx_setPledgedSrcSize*(c: pointer, size: culonglong): csize_t {.importc, cdecl.}
proc ZSTD_compressStream2*(c: pointer, o: ptr ZstdOutBuffer, i: ptr ZstdInBuffer, op: cint): csize_t {.importc, cdecl.}
proc ZSTD_getFrameContentSize*(src: pointer, size: csize_t): culonglong {.importc, cdecl.}
proc ZSTD_isError*(code: csize_t): cuint {.importc, cdecl.}
proc ZSTD_getErrorName*(code: csize_t): cstring {.importc, cdecl.}

const
  Z_OK* = 0
  Z_STREAM_END* = 1
  Z_BUF_ERROR* = -5
  Z_FINISH* = 4
  BZ_OK* = 0
  BZ_STREAM_END* = 4
  LZMA_OK* = 0
  LZMA_STREAM_END* = 1
  LZMA_BUF_ERROR* = 10
  LZMA_RUN* = 0
  LZMA_FINISH* = 3
  LZMA_CONCATENATED* = 0x08'u32
  LZMA_CHECK_CRC64* = 4
  LZ4F_VERSION* = 100
  ZSTD_c_compressionLevel* = 100
  ZSTD_c_checksumFlag* = 201
  ZSTD_c_nbWorkers* = 400
  ZSTD_e_continue* = 0
  ZSTD_e_end* = 2

proc threadCount*(): uint32 = uint32(clamp(countProcessors(), 1, 8))
