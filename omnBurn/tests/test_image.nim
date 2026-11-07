## Looking inside images before burning them.

import std/[strutils, unittest]
import ../src/omnburn/[compression, image]

suite "image inspection":
  proc blank(): string = newString(64 * 1024)
  test "hybrid ISO":
    var h = blank()
    h[510] = '\x55'; h[511] = '\xaa'
    h[0x8001 ..< 0x8006] = "CD001"
    h[0x8028 ..< 0x8028 + 11] = "OMARCHY_406"
    let i = classify(h)
    check i.kind == ikHybridIso and i.label == "OMARCHY_406" and i.warnings.len == 0
  test "plain and Windows ISOs":
    var h = blank()
    h[0x8001 ..< 0x8006] = "CD001"
    check classify(h).kind == ikPlainIso and classify(h).warnings.len == 1
    h[0x8028 ..< 0x8028 + 15] = "CCCOMA_X64FRE_E"
    # omnBurn builds a stick from a Windows ISO's files, so no "won't boot" warning
    check classify(h).windows and classify(h).warnings.len == 0 and
      classify(h).summary.startsWith("Windows installer ISO")
    check classify(h).windowsStick(cfIdentity) and not classify(h).windowsStick(cfXz)
  test "disk images":
    var h = blank()
    h[510] = '\x55'; h[511] = '\xaa'
    check classify(h).kind == ikMbrDisk
    h[512 ..< 520] = "EFI PART"
    check classify(h).kind == ikGptDisk
    check classify(blank()).kind == ikUnknown and classify(blank()).warnings.len == 1
    check classify("").warnings.len > 0
