## Hash algorithms, parsing user-supplied hashes, finding hash files, and
## hashing files (via the system's libcrypto).

import std/[algorithm, os, strutils, monotimes, times]
import compression, logging

{.passL: "-lcrypto".}

type
  HashAlg* = enum
    ## Ordered by security, lowest first.
    haMd5 = "md5", haSha1 = "sha1", haSha224 = "sha224", haSha256 = "sha256",
    haSha384 = "sha384", haSha512 = "sha512"

  HashParseErrorKind* = enum
    hpUnknownAlg, hpSriValueNotBase16OrBase64, hpInvalidLengthForAlg,
    hpAlgDetectionFailure, hpUnparseableInput, hpEmptyInput

  HashParseError* = object of ValueError
    kind*: HashParseErrorKind

proc displayName*(a: HashAlg): string =
  case a
  of haMd5: "MD5"
  of haSha1: "SHA-1"
  of haSha224: "SHA-224"
  of haSha256: "SHA-256"
  of haSha384: "SHA-384"
  of haSha512: "SHA-512"

proc digestBytes*(a: HashAlg): int =
  case a
  of haMd5: 16
  of haSha1: 20
  of haSha224: 28
  of haSha256: 32
  of haSha384: 48
  of haSha512: 64

proc fromSriAlg*(s: string): (bool, HashAlg) =
  ## Parses an SRI-style algorithm prefix (more algorithms than the spec).
  for a in HashAlg:
    if $a == s: return (true, a)

proc detectFromLength*(bytes: int): seq[HashAlg] =
  for a in HashAlg:
    if a.digestBytes == bytes: result.add a

# ---------------------------------------------------------------------------
# base16 / base64

proc toHex*(b: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for x in b:
    result.add digits[int(x shr 4)]
    result.add digits[int(x and 0xf)]

proc decodeBase16*(s: string): (bool, seq[byte]) =
  if s.len mod 2 != 0: return
  proc nibble(c: char): int =
    case c
    of '0' .. '9': ord(c) - ord('0')
    of 'a' .. 'f': ord(c) - ord('a') + 10
    of 'A' .. 'F': ord(c) - ord('A') + 10
    else: -1
  var o = newSeq[byte](s.len div 2)
  for i in 0 ..< o.len:
    let (hi, lo) = (nibble(s[2 * i]), nibble(s[2 * i + 1]))
    if hi < 0 or lo < 0: return
    o[i] = byte(hi shl 4 or lo)
  (true, o)

proc decodeBase64*(s: string, urlSafe: bool): (bool, seq[byte]) =
  ## Strict, canonically padded base64.
  if s.len mod 4 != 0: return
  let (c62, c63) = if urlSafe: ('-', '_') else: ('+', '/')
  var pad = 0
  while pad < 2 and pad < s.len and s[s.len - 1 - pad] == '=': inc pad
  var acc, bits: uint32
  var o: seq[byte]
  for i in 0 ..< s.len - pad:
    let c = s[i]
    let v = case c
      of 'A' .. 'Z': ord(c) - ord('A')
      of 'a' .. 'z': ord(c) - ord('a') + 26
      of '0' .. '9': ord(c) - ord('0') + 52
      else:
        if c == c62: 62 elif c == c63: 63 else: return
    acc = (acc shl 6) or uint32(v)
    bits += 6
    if bits >= 8:
      bits -= 8
      o.add byte((acc shr bits) and 0xff)
  if (acc and ((1'u32 shl bits) - 1)) != 0: return # non-canonical trailing bits
  (true, o)

proc parseBase16OrBase64*(s: string): (bool, seq[byte]) =
  result = decodeBase16(s)
  if not result[0]: result = decodeBase64(s, urlSafe = true)
  if not result[0]: result = decodeBase64(s, urlSafe = false)

proc hashParseError(kind: HashParseErrorKind, msg: string): ref HashParseError =
  (ref HashParseError)(kind: kind, msg: msg)

proc parseHashInput*(h: string): (seq[HashAlg], seq[byte]) =
  ## Parses "<alg>-<hash>" (SRI-like) or a bare hash, whose algorithm is
  ## guessed from its length. Raises `HashParseError`.
  if h.len == 0: raise hashParseError(hpEmptyInput, "Input is empty")
  let dash = h.find('-')
  if dash >= 0:
    let algStr = h[0 ..< dash]
    let (known, alg) = fromSriAlg(algStr)
    if not known: raise hashParseError(hpUnknownAlg, "Unknown algorithm " & algStr)
    let (ok, expected) = parseBase16OrBase64(h[dash + 1 .. ^1])
    if not ok:
      raise hashParseError(hpSriValueNotBase16OrBase64, "SRI-style value is not base16 or base64")
    if expected.len != alg.digestBytes:
      raise hashParseError(hpInvalidLengthForAlg, "Algorithm " & alg.displayName &
        " expected a digest of length " & $alg.digestBytes & ", but got length " & $expected.len)
    return (@[alg], expected)
  let (ok, bytes) = parseBase16OrBase64(h)
  if ok:
    let algs = detectFromLength(bytes.len)
    if algs.len == 0:
      raise hashParseError(hpAlgDetectionFailure,
        "Could not detect hash algorithm from digest size " & $bytes.len)
    return (algs, bytes)
  raise hashParseError(hpUnparseableInput, "Provided argument is not a hash algorithm, " &
    "SRI-style hash, nor is it base16 or base64")

# ---------------------------------------------------------------------------
# Hash files (SHA256SUMS and friends)

const
  HashFiles = [
    (haMd5, "md5sum.txt"), (haMd5, "md5sums.txt"), (haMd5, "MD5SUM"), (haMd5, "MD5SUMS"),
    (haSha1, "sha1sum.txt"), (haSha1, "sha1sums.txt"), (haSha1, "SHA1SUM"), (haSha1, "SHA1SUMS"),
    (haSha224, "sha224sum.txt"), (haSha224, "sha224sums.txt"), (haSha224, "SHA224SUM"),
    (haSha224, "SHA224SUMS"),
    (haSha256, "sha256sum.txt"), (haSha256, "sha256sums.txt"), (haSha256, "SHA256SUM"),
    (haSha256, "SHA256SUMS"),
    (haSha384, "sha384sum.txt"), (haSha384, "sha384sums.txt"), (haSha384, "SHA384SUM"),
    (haSha384, "SHA384SUMS"),
    (haSha512, "sha512sum.txt"), (haSha512, "sha512sums.txt"), (haSha512, "SHA512SUM"),
    (haSha512, "SHA512SUMS")]
  HashExtensions = [(haMd5, "md5"), (haSha1, "sha1"), (haSha224, "sha224"),
                    (haSha256, "sha256"), (haSha384, "sha384"), (haSha512, "sha512"),
                    (haSha256, "sha256sum"), (haSha512, "sha512sum"), (haSha256, "SHA256SUMS"),
                    (haSha256, "CHECKSUM"), (haSha512, "DIGESTS")] # Fedora's, Qubes's

proc signedPart*(content: string): string =
  ## For a cleartext-signed file (like Fedora's CHECKSUM), only the text the
  ## signature covers; anything else is returned as it is.
  var state = 0 # 0: before the armor, 1: its headers, 2: the signed text
  for line in content.splitLines:
    case state
    of 0:
      if line.strip == "-----BEGIN PGP SIGNED MESSAGE-----": state = 1
    of 1:
      if line.strip.len == 0: state = 2
    else:
      if line.startsWith("-----BEGIN PGP SIGNATURE-----"): return
      result.add (if line.startsWith("- "): line[2 .. ^1] else: line) & "\n"
  if state == 0: return content

proc parseHashfile*(content, inputFile: string, allowBare = false): (bool, seq[byte]) =
  ## Finds `inputFile`'s hash in coreutils-style "<hash>  <file>" lines or
  ## BSD-style "SHA256 (<file>) = <hash>" lines; other lines are skipped, and
  ## in a cleartext-signed file only the signed lines count. When several
  ## lines match (Qubes lists MD5 to SHA-512), the strongest hash wins. With
  ## `allowBare`, a file holding nothing but a hash counts too. Raises
  ## ValueError if a matching line's hash is malformed.
  let content = signedPart(content)
  let stripped = content.strip
  if allowBare and stripped.len > 0 and stripped.find(Whitespace) < 0:
    let (ok, decoded) = decodeBase16(stripped)
    if ok and detectFromLength(decoded.len).len > 0: return (true, decoded)
  for line in content.splitLines:
    let l = line.strip
    var file, value: string
    let bsd = l.find(" (")
    if bsd > 0 and l.find(") = ") > bsd:
      let close = l.rfind(") = ")
      file = l[bsd + 2 ..< close]
      value = l[close + 4 .. ^1].strip
    else:
      let sep = l.find(Whitespace)
      if sep < 0: continue
      value = l[0 ..< sep]
      file = l[sep + 1 .. ^1].strip(trailing = false)
      if file.startsWith('*'): file = file[1 .. ^1] # binary-mode marker
    if file.startsWith("./"): file = file[2 .. ^1]
    if file == inputFile:
      let (ok, decoded) = decodeBase16(value)
      if not ok: raise newException(ValueError, "Failed to decode hash")
      if not result[0] or decoded.len > result[1].len: result = (true, decoded)

proc tryHashfile(path, basename: string, allowBare = false): (bool, seq[byte]) =
  try:
    if not fileExists(path) or getFileSize(path) > 1 shl 20: return
    result = parseHashfile(readFile(path), basename, allowBare)
    if not result[0]: debug("Hash not found in " & path)
  except CatchableError as e:
    debug(path & ": " & e.msg)

type
  HashTarget* = enum
    htEither ## we don't know; accept a match with the file or its contents
    htFile   ## the file as it is (compressed, if it is)
    htImage  ## the decompressed image

  ExpectedHash* = object
    alg*: HashAlg
    value*: seq[byte]
    source*: string ## where it came from, for display
    target*: HashTarget

  HashResult* = object
    file*: seq[byte]  ## hash of the file as it is
    image*: seq[byte] ## hash of the decompressed contents; empty if not compressed

proc fromBytes(value: seq[byte], source: string, target = htEither): ExpectedHash =
  let algs = detectFromLength(value.len)
  ExpectedHash(alg: if algs.len > 0: algs[^1] else: haSha256, value: value, source: source,
               target: target)

proc findHashFor*(input: string): (bool, ExpectedHash) =
  ## Looks for the image's hash in the files that usually sit next to it:
  ## SHA256SUMS, sha256sums.txt, <image>.sha256, Fedora-style *CHECKSUM, ...
  ## Those list the file as published, so they're hashes of the file as is.
  let basename = input.extractFilename
  let dir = input.parentDir
  for (alg, ext) in HashExtensions:
    let (ok, h) = tryHashfile(input & "." & ext, basename, allowBare = true)
    if ok: return (true, fromBytes(h, basename & "." & ext, htFile))
  for (alg, name) in HashFiles:
    let (ok, h) = tryHashfile(dir / name, basename)
    if ok: return (true, fromBytes(h, name, htFile))
  var others: seq[string]
  try:
    for kind, p in walkDir(dir):
      let n = p.extractFilename.toLowerAscii
      if kind in {pcFile, pcLinkToFile} and (n.endsWith("checksum") or n.endsWith("checksums") or
          "sha256sum" in n or "sha512sum" in n):
        others.add p
  except OSError: discard
  others.sort()
  for p in others:
    let (ok, h) = tryHashfile(p, basename)
    if ok: return (true, fromBytes(h, p.extractFilename, htFile))

proc findHashInUserFile*(input, hashFile: string): (bool, ExpectedHash) =
  let (ok, h) = tryHashfile(hashFile, input.extractFilename, allowBare = true)
  if ok: return (true, fromBytes(h, hashFile.extractFilename, htFile))

proc expectedFromInput*(alg: HashAlg, value: seq[byte], source: string,
                        target = htEither): ExpectedHash =
  ExpectedHash(alg: alg, value: value, source: source, target: target)

proc matches*(e: ExpectedHash, r: HashResult): bool =
  case e.target
  of htFile: r.file == e.value
  of htImage: (if r.image.len > 0: r.image else: r.file) == e.value
  of htEither: r.file == e.value or (r.image.len > 0 and r.image == e.value)

# ---------------------------------------------------------------------------
# Hashing (libcrypto EVP)

proc EVP_MD_CTX_new(): pointer {.importc, cdecl.}
proc EVP_MD_CTX_free(ctx: pointer) {.importc, cdecl.}
proc EVP_DigestInit_ex(ctx, md, engine: pointer): cint {.importc, cdecl.}
proc EVP_DigestUpdate(ctx, d: pointer, cnt: csize_t): cint {.importc, cdecl.}
proc EVP_DigestFinal_ex(ctx: pointer, md: ptr uint8, s: ptr cuint): cint {.importc, cdecl.}
proc EVP_md5(): pointer {.importc, cdecl.}
proc EVP_sha1(): pointer {.importc, cdecl.}
proc EVP_sha224(): pointer {.importc, cdecl.}
proc EVP_sha256(): pointer {.importc, cdecl.}
proc EVP_sha384(): pointer {.importc, cdecl.}
proc EVP_sha512(): pointer {.importc, cdecl.}

proc evpMd(a: HashAlg): pointer =
  case a
  of haMd5: EVP_md5()
  of haSha1: EVP_sha1()
  of haSha224: EVP_sha224()
  of haSha256: EVP_sha256()
  of haSha384: EVP_sha384()
  of haSha512: EVP_sha512()

type Hasher* = object
  ## An incremental hash. Plain data, so it can be handed to another thread.
  alg*: HashAlg
  ctx: pointer

proc initHasher*(alg: HashAlg): Hasher =
  result = Hasher(alg: alg, ctx: EVP_MD_CTX_new())
  if result.ctx == nil or EVP_DigestInit_ex(result.ctx, evpMd(alg), nil) != 1:
    raise newException(IOError, "Failed to initialize " & alg.displayName)

proc active*(h: Hasher): bool = h.ctx != nil

proc update*(h: var Hasher, p: pointer, n: int) {.gcsafe.} =
  if h.ctx != nil and n > 0: discard EVP_DigestUpdate(h.ctx, p, csize_t(n))

proc finish*(h: var Hasher): seq[byte] =
  ## The digest; also frees the context.
  if h.ctx == nil: return
  result = newSeq[byte](h.alg.digestBytes)
  var outLen: cuint
  discard EVP_DigestFinal_ex(h.ctx, addr result[0], addr outLen)
  EVP_MD_CTX_free(h.ctx)
  h.ctx = nil

proc free*(h: var Hasher) =
  if h.ctx != nil:
    EVP_MD_CTX_free(h.ctx)
    h.ctx = nil

proc hasherTap*(p: pointer, n: int, ctx: pointer) {.nimcall, gcsafe.} =
  ## A `RawTap` that feeds a `Hasher` (passed as `ctx`).
  cast[ptr Hasher](ctx)[].update(p, n)

proc hashImage*(path: string, alg: HashAlg, cf: CompressionFormat, zip = ZipEntry(),
                progress: proc (rawBytes, totalBytes: int64) = nil): HashResult =
  ## Hashes `path` as it is and, if it's compressed, its decompressed contents
  ## too, in one pass. `progress` is called periodically with how much of the
  ## file has been read; it may raise to cancel.
  let total = getFileSize(path)
  var fileH = initHasher(alg)
  var imageH = if cf.isIdentity: Hasher() else: initHasher(alg)
  var src = openImage(path, cf, zip)
  defer:
    fileH.free()
    imageH.free()
    src.closeImage()
  src.tap = hasherTap
  src.tapCtx = addr fileH
  var buf = newSeq[byte](1 shl 20)
  var lastReport = getMonoTime()
  while true:
    let n = src.read(addr buf[0], buf.len)
    if n == 0: break
    imageH.update(addr buf[0], n)
    if progress != nil and (getMonoTime() - lastReport).inMilliseconds >= 100:
      progress(src.rawBytes, total)
      lastReport = getMonoTime()
  if progress != nil: progress(src.rawBytes, total)
  result.file = fileH.finish()
  result.image = imageH.finish()
  info("Hashed " & path & " (" & $alg & "): file " & toHex(result.file) & ", image " &
       toHex(result.image))
