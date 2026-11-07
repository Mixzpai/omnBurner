## The job the parent hands the writer (`Action`), and the errors the writer
## reports back. Both sides of the process boundary use these.

import std/[json, posix, strutils]
import ../[compression, device, hash]

const
  MaxTargets* = 16

type
  Op* = enum
    opBurn = "burn", opBackup = "backup", opFormat = "format", opWindows = "windows"

  TargetSpec* = object
    dest*: string
    targetType*: TargetType
    blockSize*: int64 ## 0 if unknown

  Action* = object
    op*: Op
    src*: string ## burn: the image; backup: the disk
    compression*: CompressionFormat ## burn: of the image; backup: to write
    zip*: ZipEntry
    targets*: seq[TargetSpec] ## burn: the disks; backup: the image; format: the disk
    verify*: bool
    verifyOnly*: bool ## skip writing, only compare (for tests)
    hash*: bool ## hash the image while burning
    hashAlg*: HashAlg
    allowSystem*: bool ## the user confirmed overwriting the system disk
    uid*, gid*: int ## backup: who should own the image, -1 to leave it
    fs*, label*: string ## format; label: Windows sticks too

  ErrorKind* = enum
    ekEndOfOutput = "end_of_output", ekVerificationFailed = "verification_failed",
    ekInputFile = "input", ekOutputFile = "output", ekUnknown = "unknown",
    ekUnexpectedTermination = "unexpected_termination", ekCommand = "command",
    ekRefused = "refused"

  IoKind* = enum
    ikUnknown = "unknown", ikPermissionDenied = "permission_denied",
    ikNotFound = "not_found", ikReadOnly = "read_only", ikBusy = "busy"

  WVError* = object of CatchableError
    kind*: ErrorKind
    io*: IoKind
    raw*: string

  Emit* = proc (line: string)

proc describe*(kind: ErrorKind, io: IoKind, raw: string): string =
  case kind
  of ekEndOfOutput: "Unexpected end of output. Is the disk too small for the image?"
  of ekVerificationFailed: "Disk verification failed! What's on the disk doesn't match the image."
  of ekUnexpectedTermination: "The writer process unexpectedly terminated!"
  of ekUnknown: "Unknown error occurred in the writer: " & raw
  of ekCommand: raw
  of ekRefused: raw
  of ekInputFile, ekOutputFile:
    let what = case io
      of ikPermissionDenied: "Permission denied while opening file!"
      of ikNotFound:
        if kind == ekInputFile: "File was not found! Was it moved or deleted?"
        else: "File was not found! Was it ejected?"
      of ikReadOnly:
        "It's read-only! Check the stick's write-protect switch, if it has one."
      of ikBusy: "The device is busy: " & raw
      of ikUnknown: "Unknown I/O error: " & raw
    (if kind == ekInputFile: "Error handling input: " else: "Error handling output: ") & what

proc wvError*(kind: ErrorKind, io = ikUnknown, raw = ""): ref WVError =
  (ref WVError)(kind: kind, io: io, raw: raw, msg: describe(kind, io, raw))

proc ioKindOf*(err: cint): IoKind =
  if err == EACCES or err == EPERM: ikPermissionDenied
  elif err == ENOENT or err == ENXIO or err == ENODEV: ikNotFound
  elif err == EROFS: ikReadOnly
  elif err == EBUSY: ikBusy
  else: ikUnknown

proc osErrorText*(context: string, err: cint): string =
  context & ": " & $strerror(err) & " (os error " & $err & ")"

proc osError*(kind: ErrorKind, context: string, err = errno): ref WVError =
  wvError(kind, ioKindOf(err), osErrorText(context, err))

proc toJson*(a: Action): string =
  var targets = newJArray()
  for t in a.targets:
    targets.add %*{"dest": t.dest, "targetType": $t.targetType, "blockSize": t.blockSize}
  $(%*{"op": $a.op, "src": a.src, "compression": $a.compression,
       "zip": {"name": a.zip.name, "stored": a.zip.stored, "dataOffset": a.zip.dataOffset,
               "compSize": a.zip.compSize, "size": a.zip.size},
       "targets": targets, "verify": a.verify, "verifyOnly": a.verifyOnly, "hash": a.hash,
       "hashAlg": $a.hashAlg,
       "allowSystem": a.allowSystem, "uid": a.uid, "gid": a.gid, "fs": a.fs, "label": a.label})

proc parseAction*(s: string): Action =
  let j = parseJson(s)
  result = Action(op: parseEnum[Op](j["op"].getStr), src: j["src"].getStr,
                  compression: parseEnum[CompressionFormat](j["compression"].getStr),
                  verify: j["verify"].getBool, verifyOnly: j{"verifyOnly"}.getBool,
                  hash: j["hash"].getBool,
                  hashAlg: parseEnum[HashAlg](j["hashAlg"].getStr),
                  allowSystem: j["allowSystem"].getBool, uid: j["uid"].getInt,
                  gid: j["gid"].getInt, fs: j["fs"].getStr, label: j["label"].getStr)
  let z = j["zip"]
  result.zip = ZipEntry(name: z["name"].getStr, stored: z["stored"].getBool,
                        dataOffset: z["dataOffset"].getBiggestInt,
                        compSize: z["compSize"].getBiggestInt, size: z["size"].getBiggestInt)
  for t in j["targets"]:
    result.targets.add TargetSpec(dest: t["dest"].getStr,
                                  targetType: parseEnum[TargetType](t["targetType"].getStr),
                                  blockSize: t["blockSize"].getBiggestInt)
