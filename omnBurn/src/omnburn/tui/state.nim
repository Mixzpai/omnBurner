## The app's state (`App`), and small helpers that read it: styles, names
## and paths, and checks such as whether a drive is too small for the image.

import std/[math, monotimes, options, os, strformat, strutils, times]
from std/posix import Statvfs, statvfs
from std/unicode import lastRune
import ../[cli, compression, desktop, device, fetch, hash, herder, image, sig, sudoauth, theme,
           writer]
import screen

const
  TickMs* = 100
  ScanMs* = 1000
  ImageExts* = [".iso", ".img", ".raw", ".bin", ".dd", ".wic", ".hddimg", ".gz", ".xz", ".bz2",
               ".zst", ".lz4", ".zip"]

type
  Screen* = enum
    scHome, scBrowse, scDownload, scWindows, scUrl, scFetching, scImage, scHashing, scDisks,
    scBackupOpts, scRestoreOpts, scConfirm, scRun, scDone

  Mode* = enum
    mBurn = "Burn", mBackup = "Back up", mRestore = "Restore"

  ModalKind* = enum
    mdNone, mdEscalate, mdPassword, mdQuit, mdStopDownload, mdTypeConfirm

  Entry* = object
    name*, path*: string
    dir*: bool
    size*: int64
    mtime*: times.Time

  HashCanceled* = object of CatchableError

  App* = ref object
    th*: Theme
    logPath*: string
    prev*: Buffer
    screen*, imageBack*: Screen
    mode*: Mode
    args*: BurnArgs
    common*: Common
    quit*: bool
    modal*: ModalKind
    status*: string
    statusErr*: bool
    homeSel*: int
    # browse
    cwd*: string
    listing*: seq[Entry]
    sel*, top*: int
    filter*: string
    allFiles*: bool
    # download
    dlSel*, dlTop*: int
    url*: string
    dl*: Download
    # Windows: the ISO comes from Microsoft's page, in the browser
    winFlow*: bool          ## the image is meant to come from that page
    winSeen*: string        ## a Windows ISO that was already in Downloads
    winIso*: string         ## the newest one, and how long its size has held
    winSize*: int64
    winStable*: int
    lastWinScan*: MonoTime
    msPending*: bool        ## check the loaded image against Microsoft's list
    winProblem*: string     ## what this system lacks to make a Windows stick
    # image
    image*: string
    fmt*: CompressionFormat
    zip*: ZipEntry
    est*: SizeEstimate
    info*: ImageInfo
    expected*: Option[ExpectedHash]
    editHash*: bool
    hashInput*: string
    precheck*: Option[bool]
    hashDone*, hashTotal*: int64
    hashTitle*: string
    sig*: SigCheck
    verify*, hashFirst*, eject*: bool
    autoStart*: bool
    # disks
    disks*: seq[WriteTarget]
    diskSel*: int
    picked*: seq[string]
    showAll*: bool
    lastScan*: MonoTime
    targets*: seq[WriteTarget]
    # backup / restore
    backupOut*: string
    backupFmt*: CompressionFormat
    fs*: FsKind
    label*: string
    typed*: string
    # job
    action*: Action
    jobTargets*: seq[WriteTarget]
    escMethod*: EscalationMethod
    auth*: SudoAuth         ## sudo checking the password typed in `mdPassword`
    password*: string
    child*: Child
    running*: bool
    job*: Job
    hadJob*: bool
    jobStarted*: bool
    focus*: int
    verdict*: Option[bool]
    powerMsgs*: seq[(bool, string)]
    powered*: bool

# ---------------------------------------------------------------------------
# Helpers

proc tilde*(p: string): string =
  let home = getHomeDir()
  if p.startsWith(home): "~/" & p[home.len .. ^1] elif p & "/" == home: "~" else: p

proc fmtDuration*(secs: float): string =
  if secs != secs or secs < 0: return "?"
  let s = int(secs)
  if s >= 3600: &"{s div 3600}h {s div 60 mod 60:02}m"
  elif s >= 60: &"{s div 60}m {s mod 60:02}s"
  else: &"{s}s"

proc fmtEtaShort*(secs: float): string =
  if secs.classify in {fcInf, fcNegInf, fcNan}: "[unknown]" else: fmtDuration(secs) & " left"

proc freeSpace*(dir: string): int64 =
  var s: Statvfs
  if statvfs(dir.cstring, s) == 0: int64(s.f_bavail) * int64(s.f_frsize) else: -1

proc dropLastRune*(s: var string) =
  if s.len > 0: s.setLen(s.len - s.lastRune(s.high)[1])

proc setStatus*(a: App, msg: string, err = true) =
  a.status = msg
  a.statusErr = err

proc fg*(a: App): Style = fgs(a.th.fg)
proc dim*(a: App): Style = fgs(a.th.dim)
proc bright*(a: App): Style = fgs(a.th.bright, bold = true)
proc acc*(a: App): Style = fgs(a.th.accent, bold = true)
proc good*(a: App): Style = fgs(a.th.green, bold = true)
proc warnSt*(a: App): Style = fgs(a.th.yellow)
proc bad*(a: App): Style = fgs(a.th.red, bold = true)

proc isImageName*(name: string): bool =
  let l = name.toLowerAscii
  for e in ImageExts:
    if l.endsWith(e): return true

proc risky(t: WriteTarget): bool =
  t.targetType != ttFile and (t.system or not t.isRemovable)

proc winMode*(a: App): bool =
  ## Burning builds a Windows installer stick from the ISO's files.
  a.mode == mBurn and a.info.windowsStick(a.fmt)

proc tooSmall*(a: App, t: WriteTarget): bool =
  a.mode == mBurn and a.est.known and t.size >= 0 and a.est.size > t.size

proc details*(t: WriteTarget): string =
  if t.targetType == ttFile: "file " & t.devnode.tilde
  else: t.modelStr & "  " & t.sizeStr & (if t.bus != busUnknown: "  " & $t.bus else: "")

proc names*(ts: seq[WriteTarget]): string =
  var n: seq[string]
  for t in ts: n.add t.name
  n.join(", ")

proc defaultBackupPath*(t: WriteTarget, cf: CompressionFormat): string =
  var slug = ""
  for c in (if t.model.len > 0: t.modelStr else: "").toLowerAscii:
    if c in {'a' .. 'z', '0' .. '9'}: slug.add c
    elif slug.len > 0 and slug[^1] != '-': slug.add '-'
  slug = slug.strip(chars = {'-'})
  downloadDir() / (t.name & (if slug.len > 0: "-" & slug else: "") & "-" &
                   now().format("yyyy-MM-dd") & ".img" & cf.extension)

proc defaultLabel*(fs: FsKind): string = "USB"

proc visibleEntries*(a: App): seq[Entry] =
  let f = a.filter.toLowerAscii
  for e in a.listing:
    if e.name == "..":
      if f.len == 0: result.add e
      continue
    if not e.dir and not a.allFiles and not e.name.isImageName: continue
    if f.len > 0 and f notin e.name.toLowerAscii: continue
    result.add e

proc powerTargets*(a: App): seq[WriteTarget] =
  if a.job.op == opBackup: return a.targets
  for t in a.job.targets:
    if t.target.targetType == ttDisk and not t.failed: result.add t.target

proc confirmText*(a: App): string =
  ## What the user must type to go ahead, or "" if a key press is enough.
  if a.mode == mBackup: return ""
  var n: seq[string]
  for t in a.targets:
    if t.risky: n.add t.name
  n.join(" ")
