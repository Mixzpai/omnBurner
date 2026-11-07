## Command-line interface.

import std/[options, os, posix, strutils]
import compression, fetch, hash, logging

type
  CompressionArg* = enum
    caAsk = "ask", caAuto = "auto", caNone = "none", caGz = "gz", caBz2 = "bz2",
    caXz = "xz", caLz4 = "lz4", caZst = "zst", caZip = "zip"

  HashArgKind* = enum
    haAsk, haSkip, haHash

  HashArg* = object
    kind*: HashArgKind
    alg*: HashAlg
    expected*: seq[byte]

  HashOf* = enum
    hoRaw = "raw", hoCompressed = "compressed"

  Interactive* = enum
    iaAuto = "auto", iaAlways = "always", iaNever = "never"

  UseSudo* = enum
    usAsk = "ask", usAlways = "always", usNever = "never"

  FsKind* = enum
    fsExfat = "exfat", fsFat32 = "fat32"

  Common* = object
    interactive*: Interactive
    force*: bool
    root*: UseSudo
    showAllDisks*: bool

  BurnArgs* = object
    image*: string ## a path, a URL, or "" to pick one in the app
    preset*: Option[Preset]
    outputs*: seq[string] ## empty means: pick disks
    compression*: CompressionArg
    hash*: HashArg
    hashFile*: string
    hashOf*: Option[HashOf]
    verify*: bool
    hashFirst*: bool
    eject*: bool
    common*: Common

  BackupArgs* = object
    disk*: string ## "" to pick one
    output*: string
    compression*: CompressionFormat
    common*: Common

  RestoreArgs* = object
    disk*: string
    fs*: FsKind
    label*: string
    eject*: bool
    common*: Common

  CommandKind* = enum
    cmdApp, cmdBurn, cmdBackup, cmdRestore, cmdHerder, cmdHelp, cmdVersion

  Command* = object
    kind*: CommandKind
    burn*: BurnArgs
    backup*: BackupArgs
    restore*: RestoreArgs
    herderLog*: string

  CliError* = object of ValueError

proc presetNames(): string =
  ## The preset names, wrapped for the help text.
  var line = " "
  for p in Preset:
    if line.len + len($p) > 78:
      result.add line & "\n"
      line = " "
    line.add " " & $p
  result.add line

const HelpText* = """
omnBurn: a lightweight, user-friendly disk imaging tool

Usage: omnburn                              open the app
       omnburn [burn] [OPTIONS] <IMAGE>     burn an image to one or more disks
       omnburn backup [OPTIONS] [DISK]      save a disk as a (compressed) image
       omnburn restore [OPTIONS] [DISK]     turn a burned stick back into a normal drive
       omnburn help

<IMAGE> is a file (.iso, .img, optionally .gz/.bz2/.xz/.lz4/.zst/.zip), an
http(s) URL to download first, or one of these names for that system's
latest release (downloaded with its checksum and signature):
""" & presetNames() & """


`windows` is the exception: Microsoft hands out Windows downloads only on its
website, so omnBurn opens that page and takes the ISO from your browser. For a
Windows ISO, omnBurn builds a bootable stick from its files (FAT32, UEFI).

Burn options:
  -o <OUT>                         Where to write. Repeat it to burn several disks at once.
                                   If not supplied, you pick disks in the app
  -z, --compression <COMPRESSION>  What compression the image uses [default: auto]
                                   [possible values: ask, auto, none, gz, bz2, xz, lz4, zst, zip]
  -s, --hash <HASH>                The hash of the image [default: ask] (see below)
      --hash-file <HASH_FILE>      Where to look for the hash of the image
      --hash-of <HASH_OF>          Is the hash of the decompressed image or of the file as is?
                                   [possible values: raw, compressed] [default: either]
      --hash-first                 Check the hash before burning instead of while burning
      --no-verify                  Don't read the disks back to verify them
      --eject                      Power off the disks when done, so they can be pulled out

Backup options:
  -o <OUT>                         The image to write [default: ~/Downloads/<disk>-<date>.img.zst]
  -z, --compression <COMPRESSION>  zst, xz, gz or none [default: zst]

Restore options:
      --fs <FS>                    exfat or fat32 [default: exfat]
      --label <LABEL>              The new volume label [default: USB]
      --eject                      Power off the disk when done

Common options:
      --show-all-disks             Also list non-removable disks (the system disk is flagged)
      --interactive <INTERACTIVE>  auto, always, never [default: auto]
  -f, --force                      Don't ask for confirmation before destroying your disk
      --root <ROOT>                If we don't have permissions on the disk, should we try to
                                   become root? [default: ask] [possible values: ask, always, never]
  -h, --help                       Print help
  -V, --version                    Print version

Hash (-s/--hash):
  ask            use a SHA256SUMS-style file found next to the image, or ask for a hash
  skip | none    do not check the image against a hash
  <alg>-<hash>   SRI-like, base16 or base64, e.g. sha256-EVSTQN3/azprGF...
  <hash>         just the value; the algorithm is guessed from its length
  Supported algorithms: md5, sha1, sha224, sha256, sha384, sha512

Theme:
  Colors follow the active Omarchy theme and update live when you change it.
  OMNBURN_THEME=<name | path/to/colors.toml | terminal> overrides it; NO_COLOR disables color.
"""

proc cliError(msg: string): ref CliError = newException(CliError, msg)

proc parseHashArg*(h: string): HashArg =
  case h.toLowerAscii
  of "ask": HashArg(kind: haAsk)
  of "skip", "none": HashArg(kind: haSkip)
  else:
    let (algs, expected) =
      try: parseHashInput(h)
      except HashParseError as e: raise cliError(e.msg)
    if algs.len > 1:
      var names: seq[string]
      for a in algs: names.add a.displayName
      raise cliError("Ambiguous hash algorithm! Could be one of: " & names.join(", ") &
                     ". Please specify by prepending [alg]- to your hash.")
    HashArg(kind: haHash, alg: algs[0], expected: expected)

proc parseValue[T: enum](opt, val: string): T =
  try: parseEnum[T](val)
  except ValueError:
    var allowed: seq[string]
    for v in T: allowed.add $v
    raise cliError("invalid value '" & val & "' for '" & opt & "'\n  [possible values: " &
                   allowed.join(", ") & "]")

proc checkImage(image: string): (string, Option[Preset]) =
  if image.isUrl: return (image, none(Preset))
  if not fileExists(image) and not dirExists(image):
    for p in Preset:
      if image.toLowerAscii == $p: return ("", some(p))
    raise cliError("invalid value '" & image & "' for '<IMAGE>': path does not exist")
  if not fileExists(image):
    raise cliError("invalid value '" & image & "' for '<IMAGE>': path is not a file or symlink to a file")
  (image, none(Preset))

type ArgKind = enum akArgument, akShort, akLong

iterator tokens(args: seq[string], valued: seq[string]): (ArgKind, string, string) =
  ## GNU-style options: `--name=value`, `--name value`, `-o value`, `-ovalue`
  ## and bundled flags like `-fh`. Everything after `--` is an argument.
  ## (std/parseopt only reads `-o value` from Nim 2.2.8 on, and reads the
  ## process's own command line when given no arguments.)
  var i = 0
  var onlyArgs = false
  while i < args.len:
    let a = args[i]
    inc i
    if onlyArgs or a.len < 2 or a[0] != '-':
      yield (akArgument, a, "")
    elif a == "--":
      onlyArgs = true
    elif a.startsWith("--"):
      let eq = a.find('=')
      if eq >= 0:
        yield (akLong, a[2 ..< eq], a[eq + 1 .. ^1])
      elif a[2 .. ^1] in valued and i < args.len:
        yield (akLong, a[2 .. ^1], args[i])
        inc i
      else:
        yield (akLong, a[2 .. ^1], "")
    else:
      for j in 1 ..< a.len:
        let key = $a[j]
        if key notin valued:
          yield (akShort, key, "")
        elif j + 1 < a.len:
          yield (akShort, key, a[j + 1 .. ^1].strip(trailing = false, chars = {'='}))
          break
        elif i < args.len:
          yield (akShort, key, args[i])
          inc i
          break
        else:
          yield (akShort, key, "")

proc parseArgs*(args: seq[string]): Command =
  if args.len == 0: return Command(kind: cmdApp)
  if args[0] in ["help", "-h", "--help"]: return Command(kind: cmdHelp)
  if args[0] in ["-V", "--version"]: return Command(kind: cmdVersion)
  if args[0] == "_herder":
    if args.len != 2: raise cliError("_herder takes exactly one argument")
    return Command(kind: cmdHerder, herderLog: args[1])

  let sub = if args[0] in ["burn", "backup", "restore"]: args[0] else: "burn"
  let rest = if args[0] == sub: args[1 .. ^1] else: args
  var c = Common(root: usAsk)
  var b = BurnArgs(compression: caAuto, hash: HashArg(kind: haAsk), verify: true)
  var bk = BackupArgs(compression: cfZst)
  var rs = RestoreArgs(fs: fsExfat, label: "USB")
  var positional: seq[string]
  const
    commonFlags = ["f", "force", "show-all-disks", "h", "help", "V", "version"]
    commonValued = ["interactive", "root"]
  let (flags, valued) = case sub
    of "burn": (@commonFlags & @["hash-first", "no-verify", "eject"],
                @commonValued & @["o", "z", "compression", "s", "hash", "hash-file", "hash-of"])
    of "backup": (@commonFlags, @commonValued & @["o", "z", "compression"])
    else: (@commonFlags & @["eject"], @commonValued & @["fs", "label"])
  for kind, key, val in tokens(rest, valued):
    case kind
    of akArgument: positional.add key
    of akShort, akLong:
      let opt = (if kind == akLong: "--" else: "-") & key
      if key notin flags and key notin valued:
        raise cliError("unexpected argument '" & opt & "' found")
      if key in valued and val.len == 0:
        raise cliError("a value is required for '" & opt & "' but none was supplied")
      case key
      of "o":
        if sub == "burn": b.outputs.add val else: bk.output = val
      of "z", "compression":
        if sub == "burn": b.compression = parseValue[CompressionArg](opt, val)
        else:
          let cf = parseValue[CompressionFormat](opt, val)
          if cf notin BackupFormats:
            raise cliError("invalid value '" & val & "' for '" & opt & "'\n  [possible values: zst, xz, gz, none]")
          bk.compression = cf
      of "s", "hash":
        try: b.hash = parseHashArg(val)
        except CliError as e: raise cliError("invalid value '" & val & "' for '" & opt & "': " & e.msg)
      of "hash-file":
        if not fileExists(val):
          raise cliError("invalid value '" & val & "' for '--hash-file': file does not exist")
        b.hashFile = val
      of "hash-of": b.hashOf = some(parseValue[HashOf](opt, val))
      of "hash-first": b.hashFirst = true
      of "no-verify": b.verify = false
      of "eject": b.eject = true; rs.eject = true
      of "fs": rs.fs = parseValue[FsKind](opt, val)
      of "label":
        if val.len > 15: raise cliError("--label can be at most 15 characters (11 for FAT32)")
        rs.label = val
      of "show-all-disks": c.showAllDisks = true
      of "interactive": c.interactive = parseValue[Interactive](opt, val)
      of "f", "force": c.force = true
      of "root": c.root = parseValue[UseSudo](opt, val)
      of "h", "help": return Command(kind: cmdHelp)
      of "V", "version": return Command(kind: cmdVersion)
      else: raise cliError("unexpected argument '" & opt & "' found")

  if positional.len > 1: raise cliError("unexpected argument '" & positional[1] & "' found")
  let arg = if positional.len == 1: positional[0] else: ""
  case sub
  of "burn":
    b.common = c
    if arg.len > 0: (b.image, b.preset) = checkImage(arg)
    Command(kind: cmdBurn, burn: b)
  of "backup":
    bk.common = c
    bk.disk = arg
    Command(kind: cmdBackup, backup: bk)
  else:
    rs.common = c
    rs.disk = arg
    if rs.fs == fsFat32 and rs.label.len > 11: raise cliError("FAT32 labels can be at most 11 characters")
    Command(kind: cmdRestore, restore: rs)

proc isInteractive*(i: Interactive): bool =
  case i
  of iaAuto: isatty(0) != 0 and isatty(1) != 0
  of iaAlways: true
  of iaNever: false

proc associatedFormat*(c: CompressionArg): Option[CompressionFormat] =
  case c
  of caAsk, caAuto: none(CompressionFormat)
  of caNone: some(cfIdentity)
  of caGz: some(cfGz)
  of caBz2: some(cfBz2)
  of caXz: some(cfXz)
  of caLz4: some(cfLz4)
  of caZst: some(cfZst)
  of caZip: some(cfZip)

proc hashTarget*(h: Option[HashOf]): HashTarget =
  if h.isNone: htEither
  elif h.get == hoRaw: htImage
  else: htFile

proc versionText*(): string = "omnburn " & Version
