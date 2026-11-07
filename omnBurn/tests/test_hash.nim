## Hash parsing and hash files (SHA256SUMS and friends).

import std/unittest
import ../src/omnburn/hash
import common

suite "hash parsing":
  test "valid SRI hash":
    check parseHashInput("sha384-" & sha384b64) == (@[haSha384], b64Bytes(sha384b64))
  test "valid SRI hash, base16":
    check parseHashInput("md5-b7fbc56aaec74706d8fdae71aae7b0ac") ==
      (@[haMd5], hexBytes("b7fbc56aaec74706d8fdae71aae7b0ac"))
  test "valid base64-only hash":
    check parseHashInput(sha384b64) == (@[haSha384], b64Bytes(sha384b64))
  test "valid base16-only hash":
    const h = "531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713"
    check parseHashInput(h) == (@[haSha256], hexBytes(h))
  test "invalid hashes":
    for (input, kind) in [("asdf-fdsu", hpUnknownAlg), ("sha256-deadbeef", hpInvalidLengthForAlg),
                          ("sha256-", hpInvalidLengthForAlg), ("", hpEmptyInput),
                          ("f9od:fd", hpUnparseableInput)]:
      try:
        discard parseHashInput(input)
        checkpoint input
        fail()
      except HashParseError as e:
        check e.kind == kind
  test "base64 is strict":
    check not decodeBase64("abc", false)[0]       # unpadded
    check not decodeBase64("ab+/", true)[0]       # wrong alphabet
    check decodeBase64("ab-_", true)[0]
    check not decodeBase64("YR==", false)[0]      # non-canonical trailing bits
    check decodeBase64("YQ==", false) == (true, @[byte('a')])
  test "matching the file or its contents":
    let r = HashResult(file: @[1'u8, 2], image: @[3'u8, 4])
    check expectedFromInput(haSha256, @[1'u8, 2], "x").matches(r)
    check expectedFromInput(haSha256, @[3'u8, 4], "x").matches(r)
    check not expectedFromInput(haSha256, @[3'u8, 4], "x", htFile).matches(r)
    check not expectedFromInput(haSha256, @[1'u8, 2], "x", htImage).matches(r)
    check expectedFromInput(haSha256, @[1'u8, 2], "x", htImage).matches(HashResult(file: @[1'u8, 2]))

suite "hash files":
  test "simple":
    check parseHashfile("bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965 " &
                        "archlinux-2024.11.01-x86_64.iso", "archlinux-2024.11.01-x86_64.iso") ==
      (true, hexBytes("bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965"))
  test "complicated":
    const content = """bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965  archlinux-2024.11.01-x86_64.iso
bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965  archlinux-x86_64.iso
c64745475da03a31f270b92e9abfbe7b6315596c7c97b17ef9a373433562a4a4  archlinux-bootstrap-2024.11.01-x86_64.tar.zst
c64745475da03a31f270b92e9abfbe7b6315596c7c97b17ef9a373433562a4a4 *archlinux-bootstrap-x86_64.tar.zst
"""
    for (file, h) in [
        ("archlinux-2024.11.01-x86_64.iso", "bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965"),
        ("archlinux-x86_64.iso", "bceb3dded8935c1d3521c475a69ae557e082839b46d921c8b400524470b5c965"),
        ("archlinux-bootstrap-2024.11.01-x86_64.tar.zst", "c64745475da03a31f270b92e9abfbe7b6315596c7c97b17ef9a373433562a4a4"),
        ("archlinux-bootstrap-x86_64.tar.zst", "c64745475da03a31f270b92e9abfbe7b6315596c7c97b17ef9a373433562a4a4")]:
      check parseHashfile(content, file) == (true, hexBytes(h))
    check not parseHashfile(content, "missing.iso")[0]
  test "BSD style inside a PGP clearsigned file (Fedora CHECKSUM)":
    const content = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

# Fedora-Workstation-Live-41-1.4.x86_64.iso: 2398523392 bytes
SHA256 (Fedora-Workstation-Live-41-1.4.x86_64.iso) = 531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713
-----BEGIN PGP SIGNATURE-----
"""
    check parseHashfile(content, "Fedora-Workstation-Live-41-1.4.x86_64.iso") ==
      (true, hexBytes("531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713"))
  test "a clearsigned file counts only its signed lines":
    const h = "531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713"
    const signed = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n" &
      h & "  a.iso\n- -dashed line\n-----BEGIN PGP SIGNATURE-----\n\nabc\n-----END PGP SIGNATURE-----\n" &
      "0000000000000000000000000000000000000000000000000000000000000000  b.iso\n"
    check signedPart(signed) == h & "  a.iso\n-dashed line\n"
    check signedPart("plain\n") == "plain\n"
    check parseHashfile(signed, "a.iso") == (true, hexBytes(h))
    check not parseHashfile(signed, "b.iso")[0] # outside the signature
  test "the strongest of several hashes wins (Qubes DIGESTS)":
    const sha256 = "531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713"
    const sha512 = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce" &
                   "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
    const digests = "b7fbc56aaec74706d8fdae71aae7b0ac *Qubes.iso\n" &
      "da39a3ee5e6b4b0d3255bfef95601890afd80709 *Qubes.iso\n" & sha256 & " *Qubes.iso\n" & sha512 & " *Qubes.iso\n"
    check parseHashfile(digests, "Qubes.iso") == (true, hexBytes(sha512))
    check detectFromLength(hexBytes(sha512).len) == @[haSha512]
  test "bare hashes and ./ prefixes":
    const h = "531a1557d205e09358e16fc4d79911ae4b9e28984bf10dbd7ab42d39f6a10713"
    check parseHashfile(h & "\n", "x.iso", allowBare = true) == (true, hexBytes(h))
    check not parseHashfile(h & "\n", "x.iso")[0]
    check parseHashfile(h & "  ./x.iso\n", "x.iso") == (true, hexBytes(h))
