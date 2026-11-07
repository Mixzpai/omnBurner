## A scratch directory for tests that need files, and helpers that burn plain
## files through the real pipeline, with plain files standing in for disks.
## Test files that import this end with `removeDir(dir)`.

import std/[monotimes, options, os, posix, random]
import ../src/omnburn/[compression, device, hash, herder, writer]

let dir* = getTempDir() / ("omnburn-test-" & $getpid())
createDir(dir)
var rng = initRand(102)

proc randomFile*(name: string, size: int): string =
  result = dir / name
  var data = newString(size)
  for c in data.mitems: c = char(rng.rand(255))
  writeFile(result, data)

proc fileTargets*(names: varargs[string]): seq[WriteTarget] =
  for n in names: result.add WriteTarget(name: n, devnode: dir / n, size: -1, targetType: ttFile)

proc burnFiles*(image: string, cf: CompressionFormat, outs: seq[WriteTarget], zip = ZipEntry(),
               hashAlg = none(HashAlg), verifyOnly = false): Job =
  var a = burnAction(image, cf, zip, outs, true, hashAlg, false)
  a.verifyOnly = verifyOnly
  result = newJob(opBurn, outs)
  var lines: seq[string]
  try:
    run(a, proc (l: string) = lines.add l)
  except WVError as e:
    lines.add "error " & $e.kind & " " & $e.io & " " & e.raw
  for l in lines: result.onLine(getMonoTime(), l)
  if not result.isFinished: result.onEof(getMonoTime())
