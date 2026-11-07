## Looking inside an image before burning it: is it a hybrid ISO that boots
## from a USB stick, a plain disk image, a Windows ISO (which omnBurn builds a
## stick from instead of copying it), or something that won't boot when
## copied byte for byte?

import std/strutils
import compression

type
  ImageKind* = enum
    ikUnknown, ikHybridIso, ikPlainIso, ikMbrDisk, ikGptDisk

  ImageInfo* = object
    kind*: ImageKind
    label*: string ## ISO volume label
    windows*: bool
    summary*: string
    warnings*: seq[string]

const
  HeadSize = 64 * 1024
  WindowsLabels = ["CCCOMA_", "CPBA_", "CENA_", "CCSA_", "J_CCSA", "GRMC", "GSP1RM", "ESD-ISO",
                   "SSS_X64", "IR3_", "IR4_", "IR5_", "WIN10", "WIN11", "WINDOWS"]

proc classify*(head: string): ImageInfo =
  ## Classifies an image from its first 64 KiB (decompressed).
  let mbr = head.len >= 512 and head[510] == '\x55' and head[511] == '\xaa'
  let gpt = head.len >= 520 and head[512 ..< 520] == "EFI PART"
  let iso = head.len >= 0x8006 and head[0x8001 ..< 0x8006] == "CD001"
  if iso and head.len >= 0x8048:
    result.label = head[0x8028 ..< 0x8048].strip(chars = Whitespace + {'\0'})
  let upper = result.label.toUpperAscii
  for w in WindowsLabels:
    if upper.startsWith(w): result.windows = true
  if iso and mbr:
    result.kind = ikHybridIso
    result.summary = "Hybrid ISO, boots from USB (" & (if gpt: "BIOS + UEFI" else: "BIOS/UEFI") & ")"
  elif iso:
    result.kind = ikPlainIso
    result.summary = "ISO 9660 image, not hybrid"
  elif gpt:
    result.kind = ikGptDisk
    result.summary = "Disk image with a GPT partition table"
  elif mbr:
    result.kind = ikMbrDisk
    result.summary = "Disk image with an MBR partition table"
  else:
    result.summary = "No partition table or ISO filesystem found"
  if result.label.len > 0: result.summary.add " · label " & result.label

  if result.windows:
    result.summary = "Windows installer ISO" & (if result.label.len > 0: " · label " & result.label else: "")
  elif result.kind == ikPlainIso:
    result.warnings.add "This ISO isn't a hybrid image, so a stick written from it probably " &
      "won't boot. It's meant for DVDs."
  elif result.kind == ikUnknown and head.len > 0:
    result.warnings.add "This doesn't look like a bootable image (no partition table or ISO " &
      "filesystem at the start). Burn it only if you know it's right."
  if head.len == 0:
    result.warnings.add "The image is empty."

proc windowsStick*(info: ImageInfo, cf: CompressionFormat): bool =
  ## Whether burning builds a Windows installer stick from the ISO's files
  ## (which needs the plain .iso, to mount it) rather than copying the image.
  info.windows and cf.isIdentity

proc inspect*(path: string, cf: CompressionFormat, zip = ZipEntry()): ImageInfo =
  var src = openImage(path, cf, zip)
  defer: src.closeImage()
  var head = newString(HeadSize)
  head.setLen(src.readFull(addr head[0], HeadSize))
  result = classify(head)
  if result.windows and not cf.isIdentity:
    result.warnings.add "omnBurn builds a bootable Windows stick from the ISO's files, which " &
      "needs the plain .iso. Decompress this one first; copied byte for byte, it won't boot."
