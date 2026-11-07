## Typing the sudo password into the app: reading sudo's prompts and messages,
## and handing it the password. sudo itself isn't run.

import std/unittest
include ../src/omnburn/sudoauth

proc fake(): SudoAuth =
  ## A SudoAuth that looks running, writing to a pipe instead of sudo.
  var fds: array[2, cint]
  doAssert pipe(fds) == 0
  result.child = Child(pid: high(int32), inFd: fds[1], outFd: fds[0])

proc said(s: var SudoAuth, text: string) =
  s.buf.add text
  s.parse()

proc readBack(s: SudoAuth): string =
  var buf: array[256, char]
  let n = posix.read(s.child.outFd, addr buf, buf.len)
  for i in 0 ..< n: result.add buf[i]

suite "sudo password":
  test "a prompt counts once it has all arrived":
    var s = fake()
    check not s.asking and not s.checking
    s.said("omnBurn-sudo-pa")
    check not s.asking and s.prompt == ""
    s.said("ssword: ")
    check s.asking and not s.wrong

  test "a wrong password, sent before sudo asked":
    var s = fake()
    var pw = newStringOfCap(64)
    pw.add "hunter2"
    s.send(pw)
    check pw.len == 0 and s.replied
    check s.readBack == "hunter2\n"
    check s.checking
    s.said(Prompt) # sudo asks, and reads what's waiting
    check s.checking
    s.said("Sorry, try again.\n" & Prompt)
    check s.wrong and s.said == "Sorry, try again."

  test "messages before the prompt":
    var s = fake()
    s.said("\nWe trust you have received the usual lecture.\n\n  #3) With great power\e[0m.\n" & Prompt)
    check s.asking and s.said == "#3) With great power [0m."

  test "a prompt of PAM's own":
    var s = fake()
    s.said("Verification code: ")
    check s.asking and s.prompt == "Verification code:"
    var code = "123456"
    s.send(code)
    check s.readBack == "123456\n"
    check s.prompt == "" and not s.asking
    s.said(Prompt)
    check s.asking and not s.wrong

  test "wiping":
    var pw = newStringOfCap(64) # as in the app: one buffer, never reallocated
    pw.add "pässword"           # 9 bytes: ä is 2
    let p = cast[ptr UncheckedArray[char]](addr pw[0])
    pw.wipeLastRune
    pw.wipeLastRune
    check pw == "pässwo" and p[7] == '\0' and p[8] == '\0'
    for i in 1 .. 4: pw.wipeLastRune
    check pw == "pä"
    pw.wipeLastRune
    check pw == "p" and p[1] == '\0' and p[2] == '\0'
    pw.add "ass"
    pw.wipe
    check pw == "" and p[0] == '\0' and p[3] == '\0'
