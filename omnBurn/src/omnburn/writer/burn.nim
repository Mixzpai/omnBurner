## Burning is a pipeline: one thread decompresses the image into a ring of
## aligned buffers, and one thread per disk writes them out (and later reads
## them back to verify), so decompression and slow USB writes overlap.

import std/[locks, os, posix]
import ../[compression, device, hash, logging]
import lowlevel, protocol

const
  Depth = 8           ## buffers in flight
  HeadRing = 64       ## slots' first bytes kept for the app's hex view (> MaxData + Depth)

type
  Slot = object
    buf: pointer
    len: int
    pending: int ## targets that still have to consume it

  TargetState = object
    fd: cint
    isFile: bool
    blockSize: int
    active: bool
    finished: bool ## its thread is done with this pass
    consumed: int64 ## slots consumed
    bytes: int64
    verifyBuf: pointer
    failed, reported: bool
    errKind: ErrorKind
    errIo: IoKind
    errMsg: array[400, char]

  Shared = object
    lock: Lock
    cond: Cond
    slots: array[Depth, Slot]
    produced: int64
    eof, abort, verifying: bool
    nTargets: int
    targets: array[MaxTargets, TargetState]
    padTo: int ## zero-pad the last buffer to this (the largest block size)
    src: ptr string
    fmt: CompressionFormat
    zip: ptr ZipEntry
    rawRead, outBytes: int64
    producerDone: bool
    inFailed: bool
    inErrKind: ErrorKind
    inErrIo: IoKind
    inErrMsg: array[400, char]
    hashing: bool
    fileHasher, imageHasher: Hasher
    heads: array[HeadRing, tuple[len: int, bytes: array[DataBytes, uint8]]]
      ## each slot's first bytes, by slot number, for the app's hex view

proc setMsg(dst: var array[400, char], s: string) =
  let n = min(s.len, dst.len - 1)
  if n > 0: copyMem(addr dst[0], unsafeAddr s[0], n)
  dst[n] = '\0'

proc msgOf(a: array[400, char]): string = $cast[cstring](unsafeAddr a[0])

proc activeCount(sh: ptr Shared): int =
  for i in 0 ..< sh.nTargets:
    if sh.targets[i].active: inc result

proc producer(sh: ptr Shared) {.thread.} =
  var src: Source
  var opened = false
  try:
    src = openImage(sh.src[], sh.fmt, sh.zip[])
    opened = true
    if sh.hashing:
      src.tap = hasherTap
      src.tapCtx = addr sh.fileHasher
    var i = 0'i64
    while true:
      let slot = int(i mod Depth)
      acquire(sh.lock)
      while sh.slots[slot].pending > 0 and not sh.abort and activeCount(sh) > 0:
        wait(sh.cond, sh.lock)
      let stop = sh.abort or activeCount(sh) == 0
      release(sh.lock)
      if stop: break
      let buf = sh.slots[slot].buf
      let n = src.readFull(buf, SlotSize)
      if sh.hashing: sh.imageHasher.update(buf, n)
      if n == 0: break
      let padded = min(roundUp(n, sh.padTo), SlotSize)
      if padded > n: zeroMem(buf.at(n), padded - n) # direct I/O writes whole blocks
      acquire(sh.lock)
      let head = addr sh.heads[int(i mod HeadRing)]
      head.len = min(n, DataBytes)
      copyMem(addr head.bytes[0], buf, head.len)
      sh.slots[slot].len = n
      sh.slots[slot].pending = activeCount(sh)
      sh.produced = i + 1
      sh.rawRead = src.rawBytes
      sh.outBytes = src.outBytes
      broadcast(sh.cond)
      release(sh.lock)
      inc i
    acquire(sh.lock)
    sh.rawRead = src.rawBytes
    sh.outBytes = src.outBytes
    release(sh.lock)
  except OSError as e:
    acquire(sh.lock)
    sh.inFailed = true
    sh.inErrKind = ekInputFile
    sh.inErrIo = ioKindOf(cint(e.errorCode))
    setMsg(sh.inErrMsg, "reading input: " & e.msg)
    sh.abort = true
    release(sh.lock)
  except CatchableError as e:
    acquire(sh.lock)
    sh.inFailed = true
    sh.inErrKind = ekInputFile
    sh.inErrIo = ikUnknown
    setMsg(sh.inErrMsg, e.msg)
    sh.abort = true
    release(sh.lock)
  if opened: src.closeImage()
  acquire(sh.lock)
  sh.eof = true
  sh.producerDone = true
  broadcast(sh.cond)
  release(sh.lock)

proc failTarget(sh: ptr Shared, t: int, kind: ErrorKind, io: IoKind, msg: string) =
  ## Takes a target out of the pipeline. Call with the lock held.
  let tp = addr sh.targets[t]
  if not tp.active: return
  tp.active = false
  tp.failed = true
  tp.errKind = kind
  tp.errIo = io
  setMsg(tp.errMsg, msg)
  for s in tp.consumed ..< sh.produced: dec sh.slots[int(s mod Depth)].pending
  broadcast(sh.cond)

proc consumer(arg: (ptr Shared, int)) {.thread.} =
  let (sh, t) = arg
  let tp = addr sh.targets[t]
  while true:
    acquire(sh.lock)
    while tp.active and tp.consumed == sh.produced and not sh.eof and not sh.abort:
      wait(sh.cond, sh.lock)
    if not tp.active or sh.abort or tp.consumed == sh.produced:
      release(sh.lock)
      break
    let slot = int(tp.consumed mod Depth)
    let n = sh.slots[slot].len
    let buf = sh.slots[slot].buf
    let verifying = sh.verifying
    release(sh.lock)

    var kind = ekUnknown
    var io = ikUnknown
    var msg = ""
    let len = if tp.isFile: n else: roundUp(n, tp.blockSize)
    if not verifying:
      let err = writeAll(tp.fd, buf, len)
      if err == ENOSPC: (kind, msg) = (ekEndOfOutput, "no space left")
      elif err != 0: (kind, io, msg) = (ekOutputFile, ioKindOf(err), osErrorText("writing", err))
    else:
      let r = readAll(tp.fd, tp.verifyBuf, len)
      if r < 0: (kind, io, msg) = (ekOutputFile, ioKindOf(cint(-r)), osErrorText("reading back", cint(-r)))
      elif r < n or not equalMem(tp.verifyBuf, buf, n):
        (kind, msg) = (ekVerificationFailed, "mismatch near byte " & $(tp.bytes + int64(min(r, n))))

    acquire(sh.lock)
    if msg.len > 0:
      failTarget(sh, t, kind, io, msg)
      release(sh.lock)
      break
    dec sh.slots[slot].pending
    inc tp.consumed
    tp.bytes += n
    broadcast(sh.cond)
    release(sh.lock)

  acquire(sh.lock)
  let sync = tp.active and not sh.verifying and not sh.abort
  release(sh.lock)
  if sync and fdatasync(tp.fd) != 0 and errno != EINVAL:
    let err = errno
    acquire(sh.lock)
    failTarget(sh, t, ekOutputFile, ioKindOf(err), osErrorText("syncing", err))
    release(sh.lock)
  acquire(sh.lock)
  tp.finished = true
  broadcast(sh.cond)
  release(sh.lock)

proc runPass(sh: ptr Shared, emit: Emit) =
  ## Runs one write or verify pass over all active targets.
  var prod: Thread[ptr Shared]
  var cons: array[MaxTargets, Thread[(ptr Shared, int)]]
  acquire(sh.lock)
  sh.produced = 0
  sh.eof = false
  sh.producerDone = false
  for s in sh.slots.mitems: (s.len = 0; s.pending = 0)
  for i in 0 ..< sh.nTargets:
    let tp = addr sh.targets[i]
    tp.consumed = 0
    tp.bytes = 0
    tp.finished = not tp.active
    if tp.active and sh.verifying and lseek(tp.fd, 0, SEEK_SET) < 0:
      failTarget(sh, i, ekOutputFile, ioKindOf(errno), osErrorText("seeking", errno))
      tp.finished = true
  release(sh.lock)

  createThread(prod, producer, sh)
  var started: seq[int]
  for i in 0 ..< sh.nTargets:
    if not sh.targets[i].finished:
      createThread(cons[i], consumer, (sh, i))
      started.add i

  var nextData = 0'i64 ## the next slot to send to the app's hex view

  proc report(sh: ptr Shared, emit: Emit): bool =
    ## Emits progress, the data that went out since the last report, and
    ## failures. Returns true when the pass is over.
    var line = "bytes "
    var fails, data: seq[string]
    acquire(sh.lock)
    line.add $sh.rawRead
    var allDone = sh.producerDone
    var done = high(int64) # slots every drive still going has finished with
    for i in 0 ..< sh.nTargets:
      let tp = addr sh.targets[i]
      line.add " " & $tp.bytes
      if not tp.finished: allDone = false
      if tp.active: done = min(done, tp.consumed)
      if tp.failed and not tp.reported:
        tp.reported = true
        fails.add "fail " & $i & " " & $tp.errKind & " " & $tp.errIo & " " & msgOf(tp.errMsg)
    if done != high(int64):
      for k in max(nextData, done - MaxData) ..< done:
        let head = addr sh.heads[int(k mod HeadRing)]
        data.add dataLine(k * SlotSize, addr head.bytes[0], head.len)
      nextData = max(nextData, done)
    release(sh.lock)
    emit(line)
    for d in data: emit(d)
    for f in fails:
      warn(f)
      emit(f)
    allDone

  while not report(sh, emit): sleep(ReportMs)
  joinThread(prod)
  for i in started: joinThread(cons[i])

proc burn*(a: Action, emit: Emit) =
  if a.targets.len == 0 or a.targets.len > MaxTargets:
    raise wvError(ekUnknown, ikUnknown, "between 1 and " & $MaxTargets & " targets are supported")
  info("Opening image " & a.src)
  var st: Stat
  if stat(a.src.cstring, st) != 0: raise osError(ekInputFile, "opening " & a.src)
  if posix.access(a.src.cstring, R_OK) != 0: raise osError(ekInputFile, "opening " & a.src)
  let sh = createShared(Shared)
  initLock(sh.lock)
  initCond(sh.cond)
  var srcPath = a.src
  var zip = a.zip
  sh.src = addr srcPath
  sh.zip = addr zip
  sh.fmt = a.compression
  sh.nTargets = a.targets.len
  sh.padTo = 512
  var fds: seq[cint]
  try:
    for i, t in a.targets:
      info("Opening " & t.dest & " for writing")
      let fd = openTarget(t, a.allowSystem, a.verifyOnly and t.targetType == ttFile)
      fds.add fd
      let bs = if t.blockSize > 0: int(min(t.blockSize, SlotSize)) else: 512
      sh.targets[i] = TargetState(fd: fd, isFile: t.targetType == ttFile, blockSize: bs,
                                  active: true, verifyBuf: alignedAlloc(SlotSize, bs))
      if t.targetType != ttFile: sh.padTo = max(sh.padTo, bs)
  except CatchableError:
    for fd in fds: discard posix.close(fd)
    raise
  for i in 0 ..< Depth: sh.slots[i].buf = alignedAlloc(SlotSize, sh.padTo)

  let est = estimateSize(a.src, a.compression, a.zip)
  emit("start " & $int64(st.st_size) & " " & $(if est.exact: est.size else: -1) & " " & $a.targets.len)
  sh.hashing = a.hash
  if a.hash:
    sh.fileHasher = initHasher(a.hashAlg)
    if not a.compression.isIdentity: sh.imageHasher = initHasher(a.hashAlg)

  if not a.verifyOnly:
    emit("phase write")
    info("Writing to " & $a.targets.len & " target(s), pad to " & $sh.padTo)
    runPass(sh, emit)
    if sh.inFailed: raise wvError(sh.inErrKind, sh.inErrIo, msgOf(sh.inErrMsg))
  let written = sh.outBytes
  info("Wrote " & $written & " bytes")
  for i, t in a.targets:
    if t.targetType == ttFile and sh.targets[i].active and not a.verifyOnly and
        ftruncate(sh.targets[i].fd, Off(written)) != 0:
      acquire(sh.lock)
      failTarget(sh, i, ekOutputFile, ioKindOf(errno), osErrorText("truncating", errno))
      release(sh.lock)
  if a.hash:
    let f = sh.fileHasher.finish()
    let img = sh.imageHasher.finish()
    emit("hash " & toHex(f) & " " & (if img.len > 0: toHex(img) else: "-"))
  if (a.verify or a.verifyOnly) and activeCount(sh) > 0:
    sh.verifying = true
    sh.hashing = false
    emit("phase verify")
    info("Verifying")
    runPass(sh, emit)
    if sh.inFailed: raise wvError(sh.inErrKind, sh.inErrIo, msgOf(sh.inErrMsg))
  for i, t in a.targets:
    if t.targetType != ttFile and sh.targets[i].active:
      # Let the kernel see the new partitions right away.
      if ioctl(sh.targets[i].fd, BLKRRPART) != 0: debug("BLKRRPART failed: " & $strerror(errno))
    discard posix.close(sh.targets[i].fd)
  emit("done")
