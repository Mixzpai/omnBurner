## Compression formats: detection, streaming decompression and compression
## (via the system's zlib, bzip2, xz, lz4 and zstd libraries), zip archives,
## and uncompressed-size estimates.
##
## This module only re-exports the public API. The code lives in
## `compression/`:
##
## - `formats`:  the format enum, detection, shared file/byte helpers
## - `zip`:      finding the image inside a zip archive
## - `estimate`: uncompressed-size estimates
## - `source`:   the decompressing reader (`Source`, `openImage`)
## - `encoder`:  streaming compression, for backups
## - `ffi`:      the C library bindings (internal)

import compression/[encoder, estimate, formats, source, zip]

export encoder, estimate, source, zip
export formats except fail, openRead, u16, u32, u64
