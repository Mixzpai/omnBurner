## Becoming root with sudo, with the password typed into the app rather than
## at sudo's prompt on the terminal, which would mean leaving the app's screen.
##
## `sudo -S -v` checks the password, reading it from a pipe, and makes sudo
## remember it for a few minutes. The herder is then started with `sudo -n`,
## which uses that and never asks (`spawnHerder(..., noPrompt = true)`).
##
## The password only ever goes to that `sudo -v`. The herder reads its stdin
## as the action and logs it, so a password written there, when sudo happened
## not to need one, would end up in the log.
##
## sudo is made to forget any password it remembers before asking, so the
## user always types it, and again once the herder is running.

import std/[posix, strutils]
from std/unicode import lastRune
import herder

const Prompt = "omnBurn-sudo-password: "
  ## The prompt sudo is told to use (`-p`), counted to tell when it asks.

type
  SudoAuth* = object
    ## A `sudo -v` checking a password, fed by `onReadable`.
    child: Child          ## stderr merged into stdout, which is where -S prompts
    buf: string
    asked, sent: int      ## prompts seen, passwords sent
    replied*: bool        ## the user has sent something
    said*: string         ## sudo's latest message, like "Sorry, try again."
    prompt*: string       ## a prompt of PAM's own (not sudo's) that's waiting
    done*, ok*: bool      ## sudo has exited; with 0

proc wipe*(s: var string) =
  ## Zeroes `s` before emptying it, so a password doesn't linger in memory.
  for c in s.mitems: c = '\0'
  s.setLen(0)

proc wipeLastRune*(s: var string) =
  ## Backspace, for a password.
  if s.len == 0: return
  let keep = s.len - s.lastRune(s.high)[1]
  for i in keep ..< s.len: s[i] = '\0'
  s.setLen(keep)

proc runQuiet(argv: openArray[string]): bool =
  ## Runs a command with no input or output. True if it exits with 0.
  let args = allocCStringArray(argv)
  defer: deallocCStringArray(args)
  let null = posix.open("/dev/null", O_RDWR or O_CLOEXEC)
  defer: (if null >= 0: discard posix.close(null))
  let pid = fork()
  if pid < 0: return false
  if pid == 0:
    for fd in 0.cint .. 2.cint: discard dup2(null, fd)
    signal(SIGPIPE, SIG_DFL)
    discard execvp(args[0], args)
    exitnow(127)
  var status: cint
  while waitpid(pid, status, 0) < 0 and errno == EINTR: discard
  WIFEXITED(status) and WEXITSTATUS(status) == 0

proc forgetSudo*() =
  ## `sudo -k`: sudo forgets the password it remembers, so it asks again.
  discard runQuiet(["sudo", "-k"])

proc sudoRemembers*(): bool =
  ## Would `sudo -n` work now, without asking? Not if sudo is set never to
  ## remember a password (`timestamp_timeout=0`).
  runQuiet(["sudo", "-n", "-v"])

proc startSudoAuth*(): SudoAuth =
  ## Starts a `sudo -v` to check a password, after making sudo forget any
  ## password it remembers.
  forgetSudo()
  result.child = spawnPiped(@["sudo", "-S", "-p", Prompt, "-v"], errFd = 1)

proc running*(s: SudoAuth): bool = s.child.pid > 0 and not s.done

proc fd*(s: SudoAuth): cint =
  ## What to poll for sudo's output, or -1 (which poll skips).
  if s.running: s.child.outFd else: -1

proc asking*(s: SudoAuth): bool =
  ## Is sudo waiting for the user?
  s.running and (s.asked > s.sent or s.prompt.len > 0)

proc wrong*(s: SudoAuth): bool =
  ## Did sudo turn the last password down, and ask again?
  s.running and s.sent > 0 and s.asked > s.sent

proc checking*(s: SudoAuth): bool =
  ## Has sudo got a password it hasn't answered yet?
  s.running and s.sent > 0 and not s.asking

proc clean(line: string): string =
  for c in line.strip:
    result.add(if c < ' ': ' ' else: c)

proc parse(s: var SudoAuth) =
  ## Takes the prompts and messages out of what sudo has printed so far.
  while true:
    let p = s.buf.find(Prompt)
    let nl = s.buf.find('\n')
    if nl >= 0 and (p < 0 or nl < p):
      let line = s.buf[0 ..< nl].clean
      if line.len > 0: s.said = line
      s.buf = s.buf[nl + 1 .. ^1]
    elif p >= 0:
      let line = s.buf[0 ..< p].clean
      if line.len > 0: s.said = line
      s.buf = s.buf[p + Prompt.len .. ^1]
      inc s.asked
    else: break
  # What's left is half a line: our prompt, still arriving, or one of PAM's own.
  s.prompt = if Prompt.startsWith(s.buf): "" else: s.buf.clean

proc finish(s: var SudoAuth) =
  var status: cint
  while waitpid(s.child.pid, status, 0) < 0 and errno == EINTR: discard
  discard posix.close(s.child.inFd)
  discard posix.close(s.child.outFd)
  if s.buf.clean.len > 0: s.said = s.buf.clean
  s.done = true
  s.ok = WIFEXITED(status) and WEXITSTATUS(status) == 0
  s.prompt = ""

proc onReadable*(s: var SudoAuth) =
  ## Reads what sudo printed. Call when `fd` is readable.
  var tmp: array[512, char]
  let n = posix.read(s.child.outFd, addr tmp, tmp.len)
  if n > 0:
    for i in 0 ..< n: s.buf.add tmp[i]
    s.parse()
  elif n == 0 or errno != EINTR: s.finish()

proc send*(s: var SudoAuth, password: var string) =
  ## Hands sudo the password, and wipes it. Sending it before sudo has asked
  ## is fine: only sudo reads this pipe, and the password waits there.
  if s.running:
    password.add '\n'
    discard posix.write(s.child.inFd, addr password[0], password.len)
    if s.prompt.len > 0:
      s.prompt = "" # that answered a prompt of PAM's own
      s.buf.setLen(0)
    else: inc s.sent
    s.replied = true
    s.said = ""
  password.wipe()

proc cancel*(s: var SudoAuth) =
  ## Stops sudo. With SIGKILL, so that PAM doesn't get to count a password it
  ## was still waiting for as a failed attempt: a few of those lock the account.
  if not s.running: return
  discard posix.kill(s.child.pid, SIGKILL)
  s.finish()
  s.ok = false
