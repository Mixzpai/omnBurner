## Round trips through the real burn and backup pipeline, with plain files as
## disks: several targets, verification, hashing, every compression format,
## zip archives, and backups that burn back to the same bytes.

import std/[options, os, osproc, sequtils, strutils, unittest]
import ../src/omnburn/[compression, device, hash, herder, writer]
import scratch

suite "burning":
  test "several targets at once, misaligned sizes":
    for size in [0, 1, 33, 4097, 1 shl 20, (1 shl 20) + 1, 8_312_808]:
      let f = randomFile("mis.bin", size)
      let j = burnFiles(f, cfIdentity, fileTargets("a.out", "b.out", "c.out"))
      checkpoint $size
      check j.ok and j.hasVerify
      for n in ["a.out", "b.out", "c.out"]: check readFile(dir / n) == readFile(f)

  test "verification catches a flipped byte":
    for flip in [0, 1, 834, 4210, (1 shl 20) + 7]:
      let f = randomFile("flip.bin", (1 shl 20) + 4231)
      var d = readFile(f) & "trailing junk on the disk"
      d[flip] = char(not ord(d[flip]) and 0xff)
      writeFile(dir / "flip.disk", d)
      writeFile(dir / "good.disk", readFile(f))
      let j = burnFiles(f, cfIdentity, fileTargets("flip.disk", "good.disk"), verifyOnly = true)
      checkpoint $flip
      check j.phase == phDone and j.okCount == 1
      check j.targets[0].failed and j.targets[0].error.kind == ekVerificationFailed
      check not j.targets[1].failed

  test "the first bytes of each MiB, for the hex view":
    let f = randomFile("data.bin", 5 * (1 shl 20) + 7)
    let image = readFile(f)
    let j = burnFiles(f, cfIdentity, fileTargets("data.out"))
    check j.ok
    var expected: seq[DataLine]
    for verify in [false, true]:
      for k in 0 .. 5:
        let off = k * (1 shl 20)
        expected.add DataLine(offset: off, bytes: image[off ..< min(off + 16, image.len)], verify: verify)
    check j.data == expected

  test "a missing image is an input error":
    let j = burnFiles(dir / "nope.iso", cfIdentity, fileTargets("x.out"))
    check j.phase == phFailed and j.error.kind == ekInputFile and j.error.io == ikNotFound

  test "hashing while burning":
    let f = randomFile("h.bin", 3_000_000)
    let j = burnFiles(f, cfIdentity, fileTargets("h.out"), hashAlg = some(haSha256))
    check j.ok and j.fileHash == execProcess("sha256sum " & f).split[0] and j.imageHash == ""

suite "decompression":
  let raw = randomFile("raw.bin", 3_000_000)
  let doubled = readFile(raw) & readFile(raw)
  let tools = [(cfGz, "gzip -c"), (cfBz2, "bzip2 -c"), (cfXz, "xz -c -T2 --block-size=1MiB"),
               (cfLz4, "lz4 -c --content-size"), (cfZst, "zstd -q -c")]

  for (cf, tool) in tools:
    test "round trip: " & $cf:
      if findExe(tool.split[0]).len == 0: skip()
      else:
        let packed = dir / ("raw." & $cf)
        # two concatenated streams/members, like `cat a.gz b.gz`
        check execCmd(tool & " " & raw & " > " & packed & " && " & tool & " " & raw & " >> " & packed) == 0
        check detectFormat(packed) == cf
        let j = burnFiles(packed, cf, fileTargets("out1.bin", "out2.bin"), hashAlg = some(haSha256))
        check j.ok
        check readFile(dir / "out1.bin") == doubled and readFile(dir / "out2.bin") == doubled
        let sums = execProcess("sh -c 'sha256sum " & packed & "; cat " & raw & " " & raw & " | sha256sum'").splitLines
        check j.fileHash == sums[0].split[0] and j.imageHash == sums[1].split[0]
        let r = hashImage(packed, haSha256, cf)
        check toHex(r.file) == j.fileHash and toHex(r.image) == j.imageHash
        let est = estimateSize(packed, cf)
        case cf
        of cfXz: check est.known and est.exact and est.size == 6_000_000
        of cfBz2: check not est.known
        else: check est.known and not est.exact and est.size <= 6_000_000

    test "truncated input: " & $cf:
      if findExe(tool.split[0]).len == 0: skip()
      else:
        let packed = dir / ("trunc." & $cf)
        check execCmd(tool & " " & raw & " | head -c 100000 > " & packed) == 0
        expect IOError: discard hashImage(packed, haMd5, cf)
        let j = burnFiles(packed, cf, fileTargets("trunc.out"))
        check j.phase == phFailed and j.error.kind == ekInputFile

  test "zip archives, deflated and stored":
    if findExe("python3").len == 0: skip()
    else:
      for (name, meth) in [("deflated.zip", "ZIP_DEFLATED"), ("stored.zip", "ZIP_STORED")]:
        let z = dir / name
        check execCmd("python3 -c 'import zipfile,sys; f=zipfile.ZipFile(sys.argv[1],\"w\",zipfile." & meth &
                      "); f.writestr(\"readme.txt\",\"hi\"); f.write(sys.argv[2],\"image.img\"); f.close()' " &
                      z & " " & raw) == 0
        check detectFormat(z) == cfZip
        let e = findZipEntry(z)
        check e.name == "image.img" and e.size == 3_000_000 and e.stored == (meth == "ZIP_STORED")
        check estimateSize(z, cfZip, e) == SizeEstimate(known: true, exact: true, size: 3_000_000)
        let j = burnFiles(z, cfZip, fileTargets("zip.out"), e, some(haSha256))
        check j.ok and readFile(dir / "zip.out") == readFile(raw)
        # the file hash covers the whole archive, as published checksums do
        check j.fileHash == execProcess("sha256sum " & z).split[0]
        check j.imageHash == execProcess("sha256sum " & raw).split[0]
      expect ValueError: discard findZipEntry(raw)

suite "backups":
  let raw = randomFile("disk.bin", 2_500_000)
  for cf in BackupFormats:
    test "round trip: " & $cf:
      let dest = dir / ("backup.img" & cf.extension)
      var lines: seq[string]
      let disk = WriteTarget(name: "disk.bin", devnode: raw, targetType: ttFile)
      run(backupAction(disk, dest, cf), proc (l: string) = lines.add l)
      check lines[^1].startsWith("done ")
      let data = lines.filterIt(it.startsWith("data "))
      check data.len == 3 and data[2] == "data 2097152 " & toHex(readFile(raw)[2097152 ..< 2097168]).toLowerAscii
      let digest = lines[^1].split[1]
      check readFile(dest & ".sha256") == digest & "  " & dest.extractFilename & "\n"
      check execProcess("sha256sum " & dest).split[0] == digest
      # and it burns back to the same bytes
      check detectFormat(dest) == cf
      let j = burnFiles(dest, cf, fileTargets("restored.bin"))
      check j.ok and readFile(dir / "restored.bin") == readFile(raw)
      if cf == cfZst: check estimateSize(dest, cf).size == 2_500_000 # pledged in the header

removeDir(dir)
