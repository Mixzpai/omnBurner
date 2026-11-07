## Low-level I/O shared by the writer's operations: aligned buffers for
## O_DIRECT, full reads and writes, opening targets, and running the
## external tools that formatting and Windows sticks need.

import std/[os, osproc, posix, strutils]
import ../[device, logging, tools]
import protocol

const
  SlotSize* = 1 shl 20 ## size of each pipeline buffer (1 MiB)
  ReportMs* = 100
  DataStride* = SlotSize ## the app's hex view shows one line per MiB...
  DataBytes* = 16        ## ...with its first 16 bytes
  MaxData* = 30          ## and gets at most this many lines per report

proc posix_memalign(p: ptr pointer, align, size: csize_t): cint {.importc, header: "<stdlib.h>".}
proc c_free*(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc alignedAlloc*(size, align: int): pointer =
  ## O_DIRECT needs buffers aligned to the disk's block size.
  if posix_memalign(addr result, csize_t(max(align, 4096)), csize_t(size)) != 0:
    raise newException(OutOfMemDefect, "posix_memalign failed")

proc at*(p: pointer, off: int): pointer = cast[pointer](cast[uint](p) + uint(off))

proc roundUp*(n, to: int): int = (n + to - 1) div to * to

proc dataLine*(offset: int64, p: pointer, n: int): string =
  ## A "data" message for the app's hex view: `offset`, and the first bytes
  ## (up to `DataBytes` of the `n`) found there, in hex.
  const digits = "0123456789abcdef"
  result = "data " & $offset & " "
  let b = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< min(n, DataBytes):
    result.add digits[int(b[i] shr 4)]
    result.add digits[int(b[i] and 15)]

proc emitData*(emit: Emit, offset: int64, p: pointer, n: int, budget: var int) =
  ## "data" messages for the `n` bytes at `p`, which sit at `offset`: one per
  ## MiB, while `budget` lasts. Callers top it up to `MaxData` at each report.
  var k = 0
  while k < n and budget > 0:
    emit(dataLine(offset + k, p.at(k), n - k))
    dec budget
    k += DataStride

proc writeAll*(fd: cint, buf: pointer, n: int): cint =
  ## Returns 0, or an errno (ENOSPC for a short disk).
  var off = 0
  while off < n:
    let w = posix.write(fd, buf.at(off), n - off)
    if w < 0:
      if errno == EINTR: continue
      return errno
    if w == 0: return ENOSPC
    off += w

proc readAll*(fd: cint, buf: pointer, n: int): int =
  ## Returns the bytes read (short at the end of the disk), or -errno.
  while result < n:
    let r = posix.read(fd, buf.at(result), n - result)
    if r < 0:
      if errno == EINTR: continue
      return -int(errno)
    if r == 0: break
    result += r

var BLKRRPART* {.importc, header: "<linux/fs.h>".}: culong
var BLKGETSIZE64* {.importc, header: "<linux/fs.h>".}: culong

proc openTarget*(t: TargetSpec, allowSystem: bool, readOnly = false): cint =
  ## Unmounts a disk and opens it exclusively, or creates a file.
  if t.targetType == ttFile:
    result = if readOnly: posix.open(t.dest.cstring, O_RDONLY or O_CLOEXEC)
             else: posix.open(t.dest.cstring, O_RDWR or O_CREAT or O_TRUNC or O_CLOEXEC, 0o644)
    if result < 0: raise osError(ekOutputFile, "opening " & t.dest)
    return
  let dev = fromPath(t.dest)
  if dev.system and not allowSystem:
    raise wvError(ekRefused, ikUnknown, t.dest & " holds the running system; refusing to overwrite it")
  if dev.mountpoints.len > 0:
    info("Unmounting " & dev.mountpoints.join(", "))
    let (ok, msg) = unmountAll(dev)
    if not ok:
      # Without root, a failed unmount is usually a permissions problem too.
      raise wvError(ekOutputFile, if geteuid() == 0: ikBusy else: ikPermissionDenied, msg)
  result = posix.open(t.dest.cstring, O_RDWR or O_DIRECT or O_EXCL or O_CLOEXEC)
  if result < 0:
    let err = errno
    if err == EBUSY:
      raise wvError(ekOutputFile, ikBusy, t.dest & " is in use by another program, or still mounted")
    raise osError(ekOutputFile, "opening " & t.dest, err)

# ---------------------------------------------------------------------------
# Running tools

proc runTool*(cmd: openArray[string], input = ""): string =
  let exe = findTool(cmd[0])
  if exe.len == 0:
    raise wvError(ekCommand, ikUnknown, cmd[0] & " is not installed. " & installHint([cmd[0]]))
  info("Running " & quoteShellCommand(cmd))
  var full = @cmd
  full[0] = exe
  let (output, code) = execCmdEx(quoteShellCommand(full), input = input)
  if code != 0:
    let lines = output.strip.splitLines
    raise wvError(ekCommand, ikUnknown, cmd[0] & " failed: " & (if lines.len > 0: lines[^1] else: "exit code " & $code))
  output

proc waitForPartition*(disk: string): string =
  ## The first partition's device node, once the kernel and udev have it.
  result = partitionNode(disk, 1)
  let udevadm = findTool("udevadm")
  if udevadm.len > 0: discard execCmdEx(quoteShellCommand([udevadm, "settle", "--timeout=10"]))
  var st: Stat
  for _ in 0 ..< 50:
    if stat(result.cstring, st) == 0: return
    sleep(100)
  raise wvError(ekCommand, ikUnknown, result & " didn't show up")
