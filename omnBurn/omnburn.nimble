# Package

version       = "0.2.0"
author        = "mixz"
description   = "A lightweight, user-friendly disk imaging TUI that follows your Omarchy theme"
license       = "GPL-3.0-only"
srcDir        = "src"
bin           = @["omnburn"]

# Dependencies: none beyond Nim itself. Decompression and hashing use the
# system's zlib, bzip2, xz, lz4, zstd and openssl libraries.

requires "nim >= 2.0.0"
