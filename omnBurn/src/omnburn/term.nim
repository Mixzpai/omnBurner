## Low-level terminal handling: raw mode, size, key input, and restoring the
## TTY's state when we're done.

import std/[posix, termios]

type
  KeyKind* = enum
    kNone, kChar, kEnter, kEsc, kBackspace, kTab, kUp, kDown, kLeft, kRight,
    kPageUp, kPageDown, kCtrlC, kCtrlD, kOther

  Key* = object
    kind*: KeyKind
    ch*: string ## UTF-8 text for `kChar`

  NotATty* = object of CatchableError

proc isTty*(fd: cint): bool = isatty(fd) != 0

proc termSize*(fd: cint = 2): tuple[w, h: int] =
  var ws: IOctl_WinSize
  if ioctl(fd, TIOCGWINSZ, addr ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0:
    (int(ws.ws_col), int(ws.ws_row))
  else:
    (80, 24)

# ---------------------------------------------------------------------------
# TTY state

var
  origTty: Termios
  origTtySaved = false
  rawSaved: Termios
  rawActive = false

proc saveTty*() =
  ## Remembers the state of /dev/tty so `restoreTty` can put it back, no matter
  ## how the program (or a sudo prompt) left it.
  let fd = posix.open("/dev/tty", O_RDONLY)
  if fd < 0: return
  origTtySaved = tcGetAttr(fd, addr origTty) == 0
  discard posix.close(fd)

proc restoreTty*() =
  if not origTtySaved: return
  let fd = posix.open("/dev/tty", O_RDONLY)
  if fd < 0: return
  discard tcSetAttr(fd, TCSANOW, addr origTty)
  discard posix.close(fd)

proc enableRaw*() =
  ## Raw-ish mode on stdin: no echo, no line buffering, no signals. Output
  ## processing stays on, so "\n" still returns the carriage.
  if rawActive: return
  if not isTty(0) or tcGetAttr(0, addr rawSaved) != 0:
    raise newException(NotATty, "The input device is not a TTY")
  var t = rawSaved
  t.c_iflag = t.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  t.c_lflag = t.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
  t.c_cflag = t.c_cflag or CS8
  t.c_cc[VMIN] = char(1)
  t.c_cc[VTIME] = char(0)
  discard tcSetAttr(0, TCSAFLUSH, addr t)
  rawActive = true

proc disableRaw*() =
  if rawActive:
    discard tcSetAttr(0, TCSAFLUSH, addr rawSaved)
    rawActive = false

# ---------------------------------------------------------------------------
# Keys

var pending: string

proc fillPending(timeoutMs: int): bool =
  var pfd = TPollfd(fd: 0, events: POLLIN)
  if poll(addr pfd, 1, cint(timeoutMs)) <= 0: return false
  var buf: array[256, char]
  let n = posix.read(0, addr buf, buf.len)
  if n <= 0: return false
  for i in 0 ..< n: pending.add buf[i]
  true

proc consume(n: int) = pending = pending[n .. ^1]

proc utf8Len(c: char): int =
  let b = ord(c)
  if b < 0xc0: 1
  elif b < 0xe0: 2
  elif b < 0xf0: 3
  else: 4

proc parseKey(): Key =
  let c = pending[0]
  case c
  of '\r', '\n': consume(1); Key(kind: kEnter)
  of '\x7f', '\x08': consume(1); Key(kind: kBackspace)
  of '\t': consume(1); Key(kind: kTab)
  of '\x03': consume(1); Key(kind: kCtrlC)
  of '\x04': consume(1); Key(kind: kCtrlD)
  of '\e':
    # A lone ESC is the Escape key; ESC followed by more bytes is a sequence.
    if pending.len == 1 and not fillPending(25):
      consume(1)
      return Key(kind: kEsc)
    if pending[1] notin {'[', 'O'}:
      consume(1)
      return Key(kind: kEsc)
    var i = 2
    while i < pending.len and pending[i] notin {'@' .. '~'}: inc i
    if i >= pending.len:
      pending.setLen(0)
      return Key(kind: kOther)
    let params = pending[2 ..< i]
    let final = pending[i]
    consume(i + 1)
    case final
    of 'A': Key(kind: kUp)
    of 'B': Key(kind: kDown)
    of 'C': Key(kind: kRight)
    of 'D': Key(kind: kLeft)
    of '~':
      if params == "5": Key(kind: kPageUp)
      elif params == "6": Key(kind: kPageDown)
      else: Key(kind: kOther)
    else: Key(kind: kOther)
  of '\0' .. '\x02', '\x05' .. '\x07', '\x0b', '\x0c', '\x0e' .. '\x1a', '\x1c' .. '\x1f':
    consume(1)
    Key(kind: kOther)
  else:
    let n = min(utf8Len(c), pending.len)
    let ch = pending[0 ..< n]
    consume(n)
    Key(kind: kChar, ch: ch)

proc readKey*(timeoutMs = -1): Key =
  ## Reads one key from stdin (which must be in raw mode). Returns `kNone` if
  ## nothing arrived within `timeoutMs` (-1 waits forever).
  if pending.len == 0 and not fillPending(timeoutMs):
    return Key(kind: kNone)
  parseKey()

proc hasPendingKeys*(): bool = pending.len > 0
