## Small desktop integrations: the XDG downloads directory, notifications and
## opening web pages.

import std/[os, osproc, strutils]

proc downloadDir*(): string =
  ## $XDG_DOWNLOAD_DIR from user-dirs.dirs, else ~/Downloads.
  let home = getHomeDir()
  let conf = getConfigDir() / "user-dirs.dirs"
  if fileExists(conf):
    try:
      for line in lines(conf):
        if line.startsWith("XDG_DOWNLOAD_DIR="):
          let v = line.split('=', 1)[1].strip(chars = {'"'})
          return v.replace("$HOME", home.strip(leading = false, chars = {'/'}))
    except IOError: discard
  home / "Downloads"

proc startDir*(): string =
  ## Where the file browser opens.
  let d = downloadDir()
  if dirExists(d): d else: getHomeDir()

proc notify*(summary, body: string, urgent = false) =
  ## A desktop notification via notify-send, if there's a desktop to show it.
  if findExe("notify-send").len == 0: return
  if getEnv("WAYLAND_DISPLAY").len == 0 and getEnv("DISPLAY").len == 0: return
  var cmd = @["notify-send", "-a", "omnBurn", "-i", "drive-removable-media"]
  if urgent: cmd.add ["-u", "critical"]
  cmd.add [summary, body]
  discard execCmd(quoteShellCommand(cmd) & " >/dev/null 2>&1 &")

proc openUrl*(url: string): bool =
  ## Opens a web page in the user's browser, if there's a desktop to show it.
  if findExe("xdg-open").len == 0: return false
  if getEnv("WAYLAND_DISPLAY").len == 0 and getEnv("DISPLAY").len == 0: return false
  # In the background and detached from the terminal, which the UI owns.
  execCmd("(" & quoteShellCommand(["xdg-open", url]) & " </dev/null >/dev/null 2>&1 &)") == 0
