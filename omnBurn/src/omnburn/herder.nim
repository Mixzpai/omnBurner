## Parent side of the writer: spawning the herder child (escalating to root if
## needed), talking to it, and tracking a job's state from its messages.

import std/[monotimes, options, os, posix, strutils]
import byteseries, compression, device, hash, logging, writer

export options, writer.ErrorKind, writer.IoKind, writer.Op

type
  WorkflowError* = object
    kind*: ErrorKind
    io*: IoKind
    raw*: string

  Phase* = enum
    phStarting, phWrite, phVerify, phDone, phFailed

  TargetProgress* = object
    target*: WriteTarget
    write*, verify*: ByteSeries
    failed*: bool
    error*: WorkflowError

  DataLine* = object
    ## The first bytes of a MiB that went out, for the app's hex view.
    offset*: int64
    bytes*: string
    verify*: bool ## sent while verifying

  Job* = object
    ## A state machine tracking a burn, backup or format, fed by `onLine`.
    op*: Op
    phase*: Phase
    rawTotal*: int64     ## input bytes: the file, or the disk being backed up
    outTotal*: int64     ## decompressed size if known exactly, else -1
    readHist*: ByteSeries ## input bytes read (write pass)
    targets*: seq[TargetProgress]
    hasVerify*: bool
    writtenBytes*: int64 ## bytes written per target, once the write pass is over
    fileHash*, imageHash*: string ## hex, "" until the child reports them
    step*, steps*: int
    stepText*: string
    extra*: string       ## from "done": the backup's sha256
    data*: seq[DataLine] ## the latest `KeepData` of them, oldest first
    error*: WorkflowError
    startTime*, finishTime*, verifyStart*: MonoTime

proc `$`*(e: WorkflowError): string = describe(e.kind, e.io, e.raw)

proc newJob*(op: Op, targets: seq[WriteTarget], now = getMonoTime()): Job =
  result = Job(op: op, phase: phStarting, outTotal: -1, readHist: initByteSeries(now),
               startTime: now)
  for t in targets:
    result.targets.add TargetProgress(target: t, write: initByteSeries(now))

proc isFinished*(j: Job): bool = j.phase in {phDone, phFailed}

proc okCount*(j: Job): int =
  for t in j.targets:
    if not t.failed: inc result

proc ok*(j: Job): bool = j.phase == phDone and j.okCount == j.targets.len

proc failJob*(j: var Job, now: MonoTime, err: WorkflowError) =
  if j.isFinished: return
  j.phase = phFailed
  j.error = err
  j.finishTime = now

proc maxWritten*(j: Job): int64 =
  for t in j.targets:
    if not t.failed: result = max(result, t.write.bytesEncountered)

proc leadVerify*(j: Job): int64 =
  for t in j.targets:
    if not t.failed: result = max(result, t.verify.bytesEncountered)

proc writeRatio*(j: Job, t: TargetProgress): float =
  ## How far along a target's write is, estimated from the input read when
  ## we don't know the decompressed size.
  let r =
    if j.op == opBackup or j.outTotal < 0:
      if j.rawTotal > 0: float(j.readHist.bytesEncountered) / float(j.rawTotal) else: 0.0
    else:
      if j.outTotal > 0: float(t.write.bytesEncountered) / float(j.outTotal) else: 1.0
  if r != r: 0.0 else: clamp(r, 0.0, 1.0)

proc verifyRatio*(j: Job, t: TargetProgress): float =
  if j.writtenBytes <= 0: 0.0
  else: clamp(float(t.verify.bytesEncountered) / float(j.writtenBytes), 0.0, 1.0)

proc writeEta*(j: Job): float =
  if j.op != opBackup and j.outTotal >= 0:
    var best = Inf
    for t in j.targets:
      if not t.failed: best = min(best, t.write.estimatedTimeLeft(j.outTotal))
    best
  else: j.readHist.estimatedTimeLeft(j.rawTotal)

proc verifyEta*(j: Job): float =
  var best = Inf
  for t in j.targets:
    if not t.failed: best = min(best, t.verify.estimatedTimeLeft(j.writtenBytes))
  best

proc parseErrorFields(fields: seq[string], line: string): WorkflowError =
  ## fields: kind, io kind, message
  result.kind = ekUnknown
  if fields.len >= 2:
    try:
      result.kind = parseEnum[ErrorKind](fields[0])
      result.io = parseEnum[IoKind](fields[1])
    except ValueError: discard
  result.raw = if fields.len >= 3: fields[2] else: line

proc parseErrorLine*(line: string): WorkflowError =
  parseErrorFields(line.split(' ', 3)[1 .. ^1], line)

const KeepData = 200 ## enough to fill the tallest hex view

proc onLine*(j: var Job, now: MonoTime, line: string) =
  ## Applies one line of child output.
  let parts = line.split(' ')
  if parts.len == 0 or parts[0].len == 0: return
  try:
    case parts[0]
    of "start":
      if parts.len >= 3:
        j.rawTotal = parseBiggestInt(parts[1])
        j.outTotal = parseBiggestInt(parts[2])
    of "phase":
      if parts.len >= 2 and parts[1] == "write":
        j.phase = phWrite
      elif parts.len >= 2 and parts[1] == "verify":
        info("Transition to verifying")
        j.phase = phVerify
        j.hasVerify = true
        j.writtenBytes = j.maxWritten
        j.verifyStart = now
        for t in j.targets.mitems: t.verify = initByteSeries(now)
    of "bytes":
      if j.phase == phStarting: j.phase = phWrite
      if j.phase == phWrite: j.readHist.push(now, parseBiggestInt(parts[1]))
      for i in 0 ..< min(parts.len - 2, j.targets.len):
        let b = parseBiggestInt(parts[i + 2])
        if j.targets[i].failed: continue
        if j.phase == phVerify: j.targets[i].verify.push(now, b)
        else: j.targets[i].write.push(now, b)
    of "data":
      if parts.len >= 3:
        j.data.add DataLine(offset: parseBiggestInt(parts[1]), bytes: parseHexStr(parts[2]),
                            verify: j.phase == phVerify)
        if j.data.len > KeepData: j.data.delete(0)
    of "hash":
      if parts.len >= 3:
        j.fileHash = parts[1]
        j.imageHash = if parts[2] == "-": "" else: parts[2]
    of "fail":
      let f = line.split(' ', 4)
      let i = parseInt(f[1])
      if i in 0 ..< j.targets.len:
        j.targets[i].failed = true
        j.targets[i].error = parseErrorFields(f[2 .. ^1], line)
        warn(j.targets[i].target.devnode & " failed: " & $j.targets[i].error)
    of "step":
      let f = line.split(' ', 3)
      j.step = parseInt(f[1])
      j.steps = parseInt(f[2])
      j.stepText = if f.len > 3: f[3] else: ""
      if j.phase == phStarting: j.phase = phWrite
    of "done":
      if j.isFinished: return
      info("Received done")
      if j.phase == phWrite: j.writtenBytes = j.maxWritten
      j.extra = if parts.len > 1: parts[1] else: ""
      j.finishTime = now
      if j.okCount == 0:
        j.phase = phFailed
        j.error = j.targets[0].error
      else: j.phase = phDone
    of "error": j.failJob(now, parseErrorLine(line))
    else: warn("Unexpected line from child: " & line)
  except ValueError, IndexDefect:
    warn("Malformed line from child: " & line)

proc onEof*(j: var Job, now: MonoTime) =
  ## The child's output ended.
  if not j.isFinished: info("Messages terminated unexpectedly")
  j.failJob(now, WorkflowError(kind: ekUnexpectedTermination))

proc hashResult*(j: Job): HashResult =
  HashResult(file: decodeBase16(j.fileHash)[1], image: decodeBase16(j.imageHash)[1])

# ---------------------------------------------------------------------------
# Actions

proc burnAction*(image: string, cf: CompressionFormat, zip: ZipEntry, targets: seq[WriteTarget],
                 verify: bool, hashAlg: Option[HashAlg], allowSystem: bool): Action =
  ## Paths are made absolute: an escalated child may start in another directory.
  result = Action(op: opBurn, src: absolutePath(image), compression: cf, zip: zip, verify: verify,
                  hash: hashAlg.isSome, hashAlg: hashAlg.get(haSha256),
                  allowSystem: allowSystem, uid: -1, gid: -1)
  for t in targets:
    result.targets.add TargetSpec(dest: absolutePath(t.devnode), targetType: t.targetType,
                                  blockSize: t.blockSize)

proc windowsAction*(image: string, targets: seq[WriteTarget], verify, allowSystem: bool): Action =
  ## A Windows installer stick on each target, built from the ISO's files.
  result = Action(op: opWindows, src: absolutePath(image), compression: cfIdentity, verify: verify,
                  hashAlg: haSha256, allowSystem: allowSystem, uid: -1, gid: -1, label: "WINDOWS")
  for t in targets:
    result.targets.add TargetSpec(dest: absolutePath(t.devnode), targetType: t.targetType,
                                  blockSize: t.blockSize)

proc backupAction*(disk: WriteTarget, dest: string, cf: CompressionFormat): Action =
  Action(op: opBackup, src: disk.devnode, compression: cf, hashAlg: haSha256,
         targets: @[TargetSpec(dest: absolutePath(dest), targetType: ttFile)],
         uid: int(getuid()), gid: int(getgid()))

proc formatAction*(disk: WriteTarget, fs, label: string, allowSystem: bool): Action =
  Action(op: opFormat, src: "", compression: cfIdentity, hashAlg: haSha256,
         targets: @[TargetSpec(dest: disk.devnode, targetType: ttDisk)],
         fs: fs, label: label, allowSystem: allowSystem, uid: -1, gid: -1)

# ---------------------------------------------------------------------------
# Escalation

type
  EscalationMethod* = enum
    emSudo = "sudo", emDoas = "doas", emRun0 = "run0", emSu = "su"

proc detectEscalation*(): (bool, EscalationMethod) =
  ## The first escalation tool found, in order of preference.
  for m in [emSudo, emDoas, emRun0, emSu]:
    if findExe($m).len > 0: return (true, m)

proc wrapCommand*(m: EscalationMethod, cmd: seq[string], noPrompt = false): seq[string] =
  ## With `noPrompt` (sudo only), sudo uses the password it remembers from a
  ## `sudo -v` (see `sudoauth`), and fails rather than ask for one.
  let raw = quoteShellCommand(cmd)
  case m
  of emSudo: (if noPrompt: @["sudo", "-n", "sh", "-c", raw] else: @["sudo", "sh", "-c", raw])
  of emDoas, emRun0: @[$m, "sh", "-c", raw]
  of emSu: @["su", "root", "-c", raw]

# ---------------------------------------------------------------------------
# Child process

type
  Child* = object
    pid*: Pid
    inFd*, outFd*: cint
    buf: string
    eof*: bool
    escalated*: bool

proc spawnPiped*(argv: seq[string], errFd: cint = 2): Child =
  ## fork/exec with piped stdin/stdout. stderr becomes `errFd`: by default
  ## it's inherited, so that sudo's prompts and complaints (e.g. a wrong
  ## password) stay visible, and 1 merges it into the stdout pipe.
  var inPipe, outPipe: array[2, cint]
  if pipe(inPipe) != 0 or pipe(outPipe) != 0: raiseOSError(osLastError(), "pipe")
  let cargs = allocCStringArray(argv)
  defer: deallocCStringArray(cargs)
  let pid = fork()
  if pid < 0: raiseOSError(osLastError(), "fork")
  if pid == 0:
    discard dup2(inPipe[0], 0)
    discard dup2(outPipe[1], 1)
    if errFd != 2: discard dup2(errFd, 2)
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1]]: discard posix.close(fd)
    signal(SIGINT, SIG_DFL)
    signal(SIGPIPE, SIG_DFL)
    discard execvp(cargs[0], cargs)
    exitnow(127)
  discard posix.close(inPipe[0])
  discard posix.close(outPipe[1])
  discard fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
  discard fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)
  Child(pid: pid, inFd: inPipe[1], outFd: outPipe[0])

proc selfExe(escalated: bool): string =
  ## The running binary. /proc/self/exe keeps working if the file was replaced
  ## since it started (omnBurn reinstalled while open); sudo and friends need
  ## a path, and get the file that's there now.
  if not escalated and fileExists("/proc/self/exe"): return "/proc/self/exe"
  result = getAppFilename()
  if result.endsWith(" (deleted)"): result.setLen(result.len - " (deleted)".len)

proc spawnHerder*(logPath: string, escalation = none(EscalationMethod), noPrompt = false): Child =
  ## With `noPrompt` (see `wrapCommand`), the child's stderr goes to the log
  ## rather than the terminal, which the app is drawing on.
  let cmd = @[selfExe(escalation.isSome), "_herder", logPath]
  let argv = if escalation.isSome: wrapCommand(escalation.get, cmd, noPrompt) else: cmd
  debug("Starting child process: " & quoteShellCommand(argv))
  var errFd: cint = 2
  if noPrompt:
    errFd = posix.open(logPath.cstring, O_WRONLY or O_APPEND or O_CREAT or O_CLOEXEC, 0o600)
    if errFd < 0: errFd = 2
  try: result = spawnPiped(argv, errFd)
  finally:
    if errFd != 2: discard posix.close(errFd)
  result.escalated = escalation.isSome

proc pump*(c: var Child): bool =
  ## One read() of child output into the buffer. Returns false at EOF.
  var tmp: array[4096, char]
  while true:
    let n = posix.read(c.outFd, addr tmp, tmp.len)
    if n < 0 and errno == EINTR: continue
    if n <= 0:
      c.eof = true
      return false
    for i in 0 ..< n: c.buf.add tmp[i]
    return true

proc popLine*(c: var Child, line: var string): bool =
  let nl = c.buf.find('\n')
  if nl < 0: return false
  line = c.buf[0 ..< nl]
  c.buf = c.buf[nl + 1 .. ^1]
  true

proc readLineBlocking(c: var Child, line: var string): bool =
  while not c.popLine(line):
    if c.eof or not c.pump(): return false
  true

proc reap*(c: var Child, kill = false) =
  ## Closes our ends of the pipes; with `kill`, also asks the child to stop.
  ## We don't wait: a child stuck on a slow USB stick shouldn't hang our exit.
  if c.pid <= 0: return
  if kill: discard posix.kill(c.pid, SIGTERM)
  discard posix.close(c.inFd)
  discard posix.close(c.outFd)
  var status: cint
  discard waitpid(c.pid, status, WNOHANG)
  c.pid = 0

proc start*(c: var Child, action: Action, job: var Job): bool =
  ## Sends the action and waits for the child to open its files. Returns true
  ## if it started; otherwise `job` holds the error.
  let msg = toJson(action) & "\n"
  if posix.write(c.inFd, unsafeAddr msg[0], msg.len) != msg.len:
    job.failJob(getMonoTime(), WorkflowError(kind: ekUnexpectedTermination))
    return false
  var line: string
  while c.readLineBlocking(line):
    if line.startsWith("start "):
      info("Got initial info from child: " & line)
      job.onLine(getMonoTime(), line)
      return true
    if line.startsWith("error "):
      job.failJob(getMonoTime(), parseErrorLine(line))
      return false
  job.failJob(getMonoTime(), WorkflowError(kind: ekUnexpectedTermination))
  false

proc needsRoot*(j: Job): bool =
  ## Did the job fail for lack of permissions, so that root would help?
  j.phase == phFailed and j.error.kind in {ekOutputFile, ekInputFile} and
    j.error.io == ikPermissionDenied and geteuid() != 0

proc retryable*(j: var Job) =
  ## Resets a job that failed to start, to try again (escalated).
  let t = j.targets
  var targets: seq[WriteTarget]
  for x in t: targets.add x.target
  j = newJob(j.op, targets)
