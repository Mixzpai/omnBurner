## omnBurn: a lightweight, user-friendly disk imaging tool with a TUI that
## follows your Omarchy theme.
##
## It began as a Nim port of caligula (https://github.com/ifd3f/caligula) by
## Astrid Yu, and has since been substantially rewritten and extended. GPL-3.0,
## like caligula; see LICENSE.

import std/[os, posix]
import omnburn/[cli, compression, fetch, logging, plain, term, theme, writer]
import omnburn/tui/app

proc crashAndBurn(e: ref Exception, logPath: string) =
  error("Crashing and burning with error! " & e.msg)
  error(e.getStackTrace())
  say([("omnBurn encountered a fatal error and had to abort!", fgs(plain.th.red, bold = true))])
  say("")
  say(e.msg)
  say("")
  say([(bugReportMsg(logPath), fgs(plain.th.dim))])
  quit(1)

proc mainUi(cmd: Command) =
  let stateDir = ensureStateDir()
  let logPath = stateDir / "omnburn.log"
  initLogging(logPath)
  signal(SIGPIPE, SIG_IGN)
  var theme = loadTheme()
  plain.th = theme
  info("Theme: " & theme.name & " (" & (if theme.path.len > 0: theme.path else: "ANSI palette") & ")")
  let common = case cmd.kind
    of cmdBurn: cmd.burn.common
    of cmdBackup: cmd.backup.common
    of cmdRestore: cmd.restore.common
    else: Common()
  let interactive = common.interactive.isInteractive
  saveTty()
  var code = 0
  try:
    if interactive:
      let (c, summary) = runApp(cmd, logPath, theme)
      plain.th = theme
      if summary.len > 0: say(summary)
      code = c
    else:
      code = case cmd.kind
        of cmdBurn: runBurn(cmd.burn, logPath)
        of cmdBackup: runBackup(cmd.backup, logPath)
        of cmdRestore: runRestore(cmd.restore, logPath)
        else:
          say("omnBurn's app needs a terminal. See omnburn --help for the non-interactive mode.")
          2
  except NotATty:
    say(getCurrentExceptionMsg())
    code = 2
  except PlainError, FetchError, DecompressError, ValueError:
    say([(getCurrentExceptionMsg(), fgs(plain.th.red, bold = true))])
    code = 1
  except CatchableError as e:
    restoreTty()
    crashAndBurn(e, logPath)
  finally:
    restoreTty()
  quit(code)

proc main() =
  let cmd =
    try: parseArgs(commandLineParams())
    except CliError as e:
      stderr.writeLine "error: " & e.msg & "\n\nFor more information, try '--help'."
      quit(2)
  case cmd.kind
  of cmdHelp: stdout.write HelpText
  of cmdVersion: echo versionText()
  of cmdHerder: herderMain(cmd.herderLog)
  else: mainUi(cmd)

when isMainModule:
  main()
