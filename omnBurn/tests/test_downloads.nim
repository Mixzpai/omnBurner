## Finding the newest releases, Microsoft's checksum table, file names, and GPG
## signatures: parsing gpg's output and finding signature files.

import std/[os, strutils, unittest]
import ../src/omnburn/[fetch, sig]
import scratch

suite "signatures and downloads":
  test "gpg status lines":
    check parseGpgStatus("[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG F0134EE680CAC571 Omarchy <iso@omarchy.org>\n" &
                         "[GNUPG:] VALIDSIG 40DF...\n") == (ssGood, "Omarchy <iso@omarchy.org>", "F0134EE680CAC571")
    check parseGpgStatus("[GNUPG:] BADSIG ABCD Someone\n")[0] == ssBad
    check parseGpgStatus("[GNUPG:] ERRSIG ABCD 22 10 00 1792448487 9 40DF\n[GNUPG:] NO_PUBKEY ABCD\n") ==
      (ssNoKey, "", "ABCD")
    check parseGpgStatus("gpg: no valid OpenPGP data found.\n")[0] == ssError
    check parseGpgStatus("[GNUPG:] EXPKEYSIG ABCD Old Key\n")[0] == ssExpired
  test "version patterns":
    var nums: seq[string]
    check globMatch("ubuntu-26.04.1-desktop-amd64.iso", "ubuntu-#-desktop-amd64.iso", nums) and nums == @["26.04.1"]
    check globMatch("manjaro-kde-26.1.0-260930-linux618.iso", "manjaro-kde-#-#-linux#.iso", nums) and
      nums == @["26.1.0", "260930", "618"]
    check globMatch("EndeavourOS_Titan-Nova-2026.08.15.iso", "EndeavourOS_*-#.iso", nums) and nums == @["2026.08.15"]
    check not globMatch("omarchy-.iso", "omarchy-#.iso", nums)
    check not globMatch("Qubes-R4.3.2-rc1-x86_64.iso", "Qubes-R#-x86_64.iso", nums)
    check not globMatch("debian-13.7.0-amd64-DVD-1.iso", "debian-#-amd64-netinst.iso", nums)
  test "the newest release in a page or listing":
    # URLs on a web page, numbered parts compared as numbers
    check newest("<a href=\"https://iso.omarchy.org/omarchy-4.0.6.iso\">x</a> " &
                 "https://iso.omarchy.org/omarchy-4.0.10.iso https://iso.omarchy.org/omarchy-.iso",
                 "https://iso.omarchy.org/omarchy-#.iso")[0] == "https://iso.omarchy.org/omarchy-4.0.10.iso"
    # names in a directory listing (relative links, folders with a slash)
    const listing = """<a href="Qubes-R4.2.4-x86_64.iso">Qubes-R4.2.4-x86_64.iso</a>
<a href="Qubes-R4.3.2-x86_64.iso">Qubes-R4.3.2-x86_64.iso</a>
<a href="Qubes-R4.3.3-rc1-x86_64.iso">Qubes-R4.3.3-rc1-x86_64.iso</a>
<a href="Qubes-R4.3.2-x86_64.iso.DIGESTS">Qubes-R4.3.2-x86_64.iso.DIGESTS</a>"""
    check newest(listing, "Qubes-R#-x86_64.iso") == ("Qubes-R4.3.2-x86_64.iso", @["4.3.2"])
    check newest("""<a href="21.3/">21.3/</a> <a href="22/">22/</a> <a href="22.3/">22.3/</a>""", "#")[0] == "22.3"
    # only some versions count: Ubuntu's LTS releases
    proc lts(v: seq[int]): bool = v.len == 2 and v[1] == 4 and v[0] mod 2 == 0
    check newest("""<a href="24.04/">24.04</a> <a href="25.10/">25.10</a> <a href="26.04/">26.04</a> """ &
                 """<a href="26.10/">26.10</a>""", "#", lts)[0] == "26.04"
    check newest("nothing here", "#.iso")[0] == ""
    # elementary's links carry a base64 token, "=" padding and all
    check newest("""<a href="https://dl.elementaryos.org/MTc5Mjg0MjEyNw==/elementaryos-8.1-stable-amd64.20260219.iso">""" &
                 """ws=https%3A%2F%2Fdl.elementaryos.org%2FMTc5Mjg0MjEyNw%3D%3D%2Felementaryos-9.0-stable-amd64.20270101.iso""",
                 "https://dl.elementaryos.org/*/elementaryos-#-stable-amd64.#.iso") ==
      ("https://dl.elementaryos.org/MTc5Mjg0MjEyNw==/elementaryos-8.1-stable-amd64.20260219.iso", @["8.1", "20260219"])
  test "Microsoft's checksum table":
    const page = """<p>SHA256 output matches the value in the below table</p>
<table><tr><th>Country Locale</th><th>Hash Code</th></tr>
<tr><td>Arabic 64-bit</td><td>A75AE3F36CB9FFFFEDCB2D7DED9CEF83FFB710EB1376610D2220684D987CB9A5</td></tr>
<tr><td>English 64-bit</td>
  <td>BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650</td></tr>
<tr><td>Spanish (Mexico) 64-bit</td><td><span>83231BCD4C509CFA51EB9A79056C6F1CA40DF09110267832E780A881B9EE8F9E</span></td></tr>
</table><p>Not a hash: 1234</p>"""
    let t = parseWindowsHashes(page)
    check t.len == 3 and t[1] == ("English 64-bit", "bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea650")
    check t[2].label == "Spanish (Mexico) 64-bit"
    check windowsHashLabel(t, "BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650") == "English 64-bit"
    check windowsHashLabel(t, "00" & "bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea6") == ""
    check parseWindowsHashes("<p>no table</p>").len == 0
  test "every preset has a name and its id is its CLI name":
    for p in Preset:
      check p.displayName.len > 0 and $p == ($p).toLowerAscii and ' ' notin $p
  test "file names":
    check fileNameOf("https://example.com/a/b.iso?x=1#y") == "b.iso"
    check fileNameOf("https://example.com/") == "example.com"
    check isUrl("https://x") and isUrl("http://x") and not isUrl("ftp://x")

suite "finding signatures":
  setup:
    let d = dir / "sigs"
    removeDir(d)
    createDir(d)
  test "on the image, on a checksum file, or inside it":
    let img = d / "a.iso"
    writeFile(img, "x")
    check not findSignature(img)[0]
    writeFile(img & ".CHECKSUM", "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\nSHA256 (a.iso) = 00\n")
    check findSignature(img) == (true, img & ".CHECKSUM", "") # cleartext-signed
    removeFile(img & ".CHECKSUM")
    writeFile(img & ".DIGESTS", "00 *a.iso\n")
    writeFile(img & ".DIGESTS.asc", "sig")
    check findSignature(img) == (true, img & ".DIGESTS.asc", img & ".DIGESTS")
    writeFile(d / "SHA256SUMS", "00  other.iso\n") # doesn't list this image
    writeFile(d / "SHA256SUMS.sign", "sig")
    check findSignature(img)[1] == img & ".DIGESTS.asc"
    writeFile(img & ".sig", "sig")
    check findSignature(img) == (true, img & ".sig", img)
  test "what a signature covers":
    let img = d / "a.iso"
    check SigCheck(image: img, sigFile: img & ".sig", signedFile: img).coversImage
    check not SigCheck(image: img, sigFile: img & ".DIGESTS.asc", signedFile: img & ".DIGESTS").coversImage
    check not SigCheck(image: img, sigFile: img & ".CHECKSUM").coversImage
    check SigCheck(status: ssGood, image: img, sigFile: img & ".CHECKSUM", signer: "Fedora").describe.
      contains("(on a.iso.CHECKSUM)")

removeDir(dir)
