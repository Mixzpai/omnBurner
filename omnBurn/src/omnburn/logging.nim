## Logging to a per-invocation file, plus the state directory it lives in.

import std/[os, posix, strutils, times]

const Version* = "0.2.0"

var
  logFile: File
  logOpen = false
  role = "main"

proc ensureStateDir*(): string =
  ## Directory for invocation-specific data like log files.
  result = getTempDir() / ("omnburn-" & $getpid() & "-" & $(epochTime() * 1000).int64)
  if mkdir(result.cstring, 0o700) != 0:
    raiseOSError(osLastError(), result)

proc log*(level, msg: string) =
  if not logOpen: return
  try:
    logFile.writeLine(now().format("yyyy-MM-dd HH:mm:ss'.'fff"), " ", level.alignLeft(5),
                      " [", role, " ", getpid(), "] ", msg)
    logFile.flushFile()
  except IOError: discard

proc debug*(msg: string) = log("DEBUG", msg)
proc info*(msg: string) = log("INFO", msg)
proc warn*(msg: string) = log("WARN", msg)
proc error*(msg: string) = log("ERROR", msg)

proc initLogging*(path: string, child = false) =
  ## Both the parent and the (possibly root) herder child append to one log.
  role = if child: "herder" else: "main"
  logOpen = open(logFile, path, fmAppend)
  if logOpen and not child:
    var u: Utsname
    if uname(u) == 0:
      info("uname: " & $cast[cstring](addr u.sysname) & " " & $cast[cstring](addr u.release) &
           " " & $cast[cstring](addr u.machine))
    info("omnburn " & Version & ", args: " & commandLineParams().join(" ") &
         ", euid: " & $geteuid())

proc bugReportMsg*(logPath: string): string =
  "If this looks like a bug, please report it and attach the log file at " & logPath
