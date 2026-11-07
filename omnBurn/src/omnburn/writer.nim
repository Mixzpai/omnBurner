## The writer ("herder") child process. It burns an image onto one or more
## disks at once, backs a disk up into a compressed image, formats a stick,
## or builds Windows installer sticks, and reports to the parent as lines on
## stdout:
##
##   start <input bytes> <decompressed bytes or -1> <targets>
##   phase write|verify
##   bytes <input bytes read> <bytes done on target 0> <target 1> ...
##   hash <file hash or -> <decompressed image hash or ->
##   fail <target> <kind> <io kind> <raw message>   (that target is out)
##   step <n> <of> <description>                    (formatting, Windows sticks)
##   done [extra]                                    (backup: sha256 of the image)
##   error <kind> <io kind> <raw message>            (the whole job failed)
##
## It runs as a separate process so that it alone can be re-spawned as root
## (via sudo and friends) when we lack permissions on the disk.
##
## IT IS NOT TO BE USED DIRECTLY BY THE USER! ITS API HAS NO STABILITY
## GUARANTEES!
##
## The code lives in `writer/`:
##
## - `protocol`: the `Action` the parent sends, and the errors sent back
## - `lowlevel`: aligned buffers, full reads/writes, opening targets, running tools
## - `burn`:     the burn pipeline (decompress, write, verify)
## - `backup`:   disk -> (compressed) image file
## - `format`:   a fresh partition table and filesystem
## - `windows`:  Windows installer sticks

import std/[posix, strutils]
import logging
import writer/[backup, burn, format, lowlevel, protocol, windows]

export protocol except ioKindOf, osErrorText, osError
export alignedAlloc

proc run*(a: Action, emit: Emit) =
  case a.op
  of opBurn: burn(a, emit)
  of opBackup: backup(a, emit)
  of opFormat: format(a, emit)
  of opWindows: windows(a, emit)

proc herderMain*(logPath: string) =
  initLogging(logPath, child = true)
  signal(SIGPIPE, SIG_IGN)
  let emit = proc (line: string) =
    let s = line.replace('\n', ' ') & "\n"
    var off = 0
    while off < s.len:
      let w = posix.write(1, unsafeAddr s[off], s.len - off)
      if w < 0:
        if errno == EINTR: continue
        error("Parent went away, exiting")
        quit(1)
      off += w
  var line: string
  if not stdin.readLine(line): quit(1)
  info("Received action " & line)
  try:
    run(parseAction(line), emit)
    info("Finished successfully")
  except WVError as e:
    error(e.msg & " (" & e.raw & ")")
    emit("error " & $e.kind & " " & $e.io & " " & e.raw)
  except CatchableError as e:
    error("Unexpected error: " & e.msg)
    emit("error " & $ekUnknown & " " & $ikUnknown & " " & e.msg)
