## Backing a disk up into a (compressed) image file, with a .sha256 sidecar.

import std/[monotimes, os, posix, times]
import ../[compression, hash, logging]
import lowlevel, protocol

proc backup*(a: Action, emit: Emit) =
  let dest = a.targets[0].dest
  info("Backing up " & a.src & " to " & dest)
  var src = posix.open(a.src.cstring, O_RDONLY or O_DIRECT or O_CLOEXEC)
  if src < 0 and errno == EINVAL: src = posix.open(a.src.cstring, O_RDONLY or O_CLOEXEC)
  if src < 0: raise osError(ekInputFile, "opening " & a.src)
  defer: discard posix.close(src)
  var size: uint64
  if ioctl(src, BLKGETSIZE64, addr size) != 0:
    let e = lseek(src, 0, SEEK_END)
    size = if e > 0: uint64(e) else: 0
    discard lseek(src, 0, SEEK_SET)
  let outFd = posix.open(dest.cstring, O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o644)
  if outFd < 0: raise osError(ekOutputFile, "creating " & dest)
  defer: discard posix.close(outFd)
  emit("start " & $size & " -1 1")
  emit("phase write")

  var written: int64
  var outHash = initHasher(haSha256)
  let sink = proc (p: pointer, n: int) =
    let err = writeAll(outFd, p, n)
    if err == ENOSPC: raise wvError(ekEndOfOutput, ikUnknown, "no space left for the image")
    if err != 0: raise osError(ekOutputFile, "writing " & dest, err)
    outHash.update(p, n)
    written += n
  let enc = newEncoder(a.compression, int64(size))
  defer: enc.close()
  let buf = alignedAlloc(SlotSize, 4096)
  defer: c_free(buf)
  var read: int64
  var last = getMonoTime()
  var budget = MaxData
  while true:
    let n = readAll(src, buf, SlotSize)
    if n < 0: raise osError(ekInputFile, "reading " & a.src, cint(-n))
    enc.encode(buf, n, n == 0, sink)
    emitData(emit, read, buf, n, budget)
    read += n
    if n == 0: break
    if (getMonoTime() - last).inMilliseconds >= ReportMs:
      emit("bytes " & $read & " " & $written)
      last = getMonoTime()
      budget = MaxData
  emit("bytes " & $read & " " & $written)
  if fsync(outFd) != 0: raise osError(ekOutputFile, "syncing " & dest)
  let digest = toHex(outHash.finish())
  let sidecar = dest & ".sha256"
  writeFile(sidecar, digest & "  " & dest.extractFilename & "\n")
  if a.uid >= 0 and geteuid() == 0:
    # We're root via sudo; the image belongs to the user who asked for it.
    discard fchown(outFd, Uid(a.uid), Gid(a.gid))
    discard chown(sidecar.cstring, Uid(a.uid), Gid(a.gid))
  info("Backup done, sha256 " & digest)
  emit("done " & digest)
