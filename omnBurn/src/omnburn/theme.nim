## Colors, styles, and Omarchy theme integration.
##
## omnBurn paints itself with the palette of the currently applied Omarchy
## theme, read from `~/.local/state/omarchy/current/theme/colors.toml`. The
## file is re-checked while the UI runs, so `omarchy theme set <name>` restyles
## a burn in progress. Without an Omarchy theme (or without truecolor), we fall
## back to the terminal's 16-color palette, which Omarchy themes as well.
##
## `OMNBURN_THEME` overrides the lookup: a theme name, a path to a
## `colors.toml`, or `terminal` to force the ANSI palette. `NO_COLOR` disables
## colors entirely.

import std/[os, posix, strutils, tables, times]

type
  ColorKind* = enum
    ckDefault, ckAnsi, ckRgb

  Color* = object
    kind*: ColorKind
    v*: uint32 ## ANSI index for `ckAnsi`, 0xRRGGBB for `ckRgb`

  Style* = object
    fg*, bg*: Color
    bold*, reverse*: bool

  Theme* = object
    name*: string ## e.g. "netrunner", or "terminal" for the ANSI fallback
    path*: string ## the colors.toml we loaded, "" for the fallback
    mtime: times.Time
    fg*, bg*, dim*, bright*, accent*, muted*, selection*, track*: Color
    red*, green*, yellow*, blue*, cyan*, magenta*, orange*: Color

const DefaultColor* = Color(kind: ckDefault)

proc ansi*(i: int): Color = Color(kind: ckAnsi, v: uint32(i))
proc rgb*(v: uint32): Color = Color(kind: ckRgb, v: v)

var colorEnabled* = getEnv("NO_COLOR").len == 0
  ## Whether to emit color codes at all (bold/reverse are still emitted).

proc colorCode(c: Color, base: int): string =
  ## `base` is 30 for foreground, 40 for background.
  case c.kind
  of ckDefault: ""
  of ckAnsi:
    if c.v < 8: ";" & $(base + int(c.v)) else: ";" & $(base + 60 + int(c.v) - 8)
  of ckRgb:
    ";" & $(base + 8) & ";2;" & $((c.v shr 16) and 0xff) & ";" &
      $((c.v shr 8) and 0xff) & ";" & $(c.v and 0xff)

proc sgr*(s: Style): string =
  ## SGR escape that resets attributes, then applies `s`.
  result = "\e[0"
  if s.bold: result.add ";1"
  if s.reverse: result.add ";7"
  if colorEnabled:
    result.add colorCode(s.fg, 30)
    result.add colorCode(s.bg, 40)
  result.add "m"

var stderrStyled* = isatty(2) != 0
  ## Whether `paint` should emit escapes (stderr is where prompts go).

proc paint*(text: string, s: Style): string =
  if not stderrStyled or text.len == 0: text
  else: sgr(s) & text & "\e[0m"

proc fgs*(c: Color, bold = false): Style = Style(fg: c, bold: bold)

# ---------------------------------------------------------------------------
# Loading

proc terminalTheme(): Theme =
  Theme(name: "terminal", fg: DefaultColor, bg: DefaultColor, dim: ansi(8),
        bright: ansi(15), accent: ansi(4), muted: ansi(8), selection: ansi(8),
        track: ansi(0), red: ansi(1), green: ansi(2), yellow: ansi(3),
        blue: ansi(4), magenta: ansi(5), cyan: ansi(6), orange: ansi(11))

proc supportsTruecolor(): bool =
  let ct = getEnv("COLORTERM").toLowerAscii
  if ct in ["truecolor", "24bit"]: return true
  let term = getEnv("TERM")
  for t in ["kitty", "ghostty", "alacritty", "foot", "direct"]:
    if t in term: return true

proc userHome(): string =
  ## Under `sudo omnburn`, read the invoking user's theme rather than root's.
  let sudoUser = getEnv("SUDO_USER")
  if geteuid() == 0 and sudoUser.len > 0:
    let pw = getpwnam(sudoUser.cstring)
    if pw != nil: return $pw.pw_dir
  getHomeDir()

proc currentThemePaths(): seq[string] =
  let home = userHome()
  @[home / ".local/state/omarchy/current/theme/colors.toml",
    home / ".config/omarchy/current/theme/colors.toml"] # older Omarchy

proc namedThemePaths(name: string): seq[string] =
  let slug = name.toLowerAscii.replace(' ', '-')
  @[userHome() / ".config/omarchy/themes" / slug / "colors.toml",
    "/usr/share/omarchy/themes" / slug / "colors.toml"]

proc parseColors(path: string): Table[string, Color] =
  ## Reads the `key = "#rrggbb"` lines of an Omarchy colors.toml.
  for line in lines(path):
    let l = line.strip
    if l.len == 0 or l[0] == '#': continue
    let eq = l.find('=')
    if eq < 0: continue
    let key = l[0 ..< eq].strip
    let val = l[eq + 1 .. ^1].strip.strip(chars = {'"', '\''})
    if val.len == 7 and val[0] == '#':
      try: result[key] = rgb(uint32(parseHexInt(val[1 .. ^1])))
      except ValueError: discard

proc themeName(path: string): string =
  ## Omarchy records the applied theme's name next to the theme directory.
  let dir = path.parentDir
  let nameFile = dir.parentDir / "theme.name"
  if dir.lastPathPart == "theme" and fileExists(nameFile):
    try: return readFile(nameFile).strip
    except IOError: discard
  dir.lastPathPart

proc fromColors(path: string): Theme =
  let c = parseColors(path)
  result = terminalTheme()
  result.name = themeName(path)
  result.path = path
  result.mtime = getLastModificationTime(path)
  template pick(field: untyped, keys: varargs[string]) =
    for k in keys:
      if k in c:
        result.field = c[k]
        break
  pick(fg, "foreground")
  pick(bg, "background")
  pick(dim, "dark_foreground", "muted")
  pick(bright, "bright_foreground", "foreground")
  pick(accent, "accent", "blue")
  pick(muted, "muted", "dark_foreground")
  pick(selection, "selection", "lighter_background")
  pick(track, "lighter_background", "selection")
  pick(red, "red")
  pick(green, "green")
  pick(yellow, "yellow")
  pick(blue, "blue")
  pick(cyan, "cyan")
  pick(magenta, "magenta")
  pick(orange, "orange", "bright_yellow")

proc resolvePath(): string =
  ## The colors.toml to use, or "" for the terminal palette.
  let wanted = getEnv("OMNBURN_THEME")
  if wanted.toLowerAscii in ["terminal", "ansi"] or not supportsTruecolor():
    return ""
  let candidates =
    if wanted.len == 0: currentThemePaths()
    elif wanted.endsWith(".toml"): @[wanted.expandTilde]
    else: namedThemePaths(wanted)
  for p in candidates:
    if fileExists(p): return p

proc loadTheme*(): Theme =
  let p = resolvePath()
  if p.len > 0:
    try: return fromColors(p)
    except CatchableError: discard
  terminalTheme()

proc refresh*(t: var Theme): bool =
  ## Picks up theme changes (e.g. `omarchy theme set`). Returns true if the
  ## theme changed and the screen should be repainted.
  let p = resolvePath()
  if p.len == 0:
    if t.path.len == 0: return false
    t = terminalTheme()
    return true
  try:
    if p == t.path and getLastModificationTime(p) == t.mtime: return false
    t = fromColors(p)
    true
  except CatchableError:
    false # mid-swap by `omarchy theme set`; try again next tick
