## The programs omnBurn runs, and the packages that have them, so it can say
## what to install (install.sh offers the same packages).

import std/[os, posix, strutils]

const WindowsTools* = ["mount", "umount", "wipefs", "sfdisk", "blockdev", "mkfs.fat", "wimlib-imagex"]
  ## What making a Windows stick runs

proc findTool*(name: string): string =
  ## The program's path, or "". Looks in the sbin directories too: they
  ## aren't on an ordinary user's PATH on Debian and Ubuntu.
  result = findExe(name)
  if result.len > 0: return
  for d in ["/usr/local/sbin", "/usr/sbin", "/sbin"]:
    if fileExists(d / name): return d / name

type Distro = enum
  dUnknown, dArch, dDebian, dFedora, dSuse, dAlpine, dVoid

proc distro(osRelease: string): Distro =
  ## This distribution's family, going by /etc/os-release.
  var id, like: seq[string]
  try:
    for line in lines(osRelease):
      let eq = line.find('=')
      if eq < 0: continue
      let value = line[eq + 1 .. ^1].strip(chars = {'"', '\''}).splitWhitespace
      case line[0 ..< eq]
      of "ID": id = value
      of "ID_LIKE": like = value
      else: discard
  except IOError, OSError: return dUnknown
  for i in id & like:
    case i
    of "arch", "archarm", "manjaro", "endeavouros", "cachyos", "garuda": return dArch
    of "debian", "ubuntu", "linuxmint", "pop", "raspbian", "elementary", "zorin", "kali": return dDebian
    of "fedora", "rhel", "centos", "rocky", "almalinux", "nobara": return dFedora
    of "suse", "sles": return dSuse
    of "alpine": return dAlpine
    of "void": return dVoid
    else:
      if i.startsWith("opensuse"): return dSuse
  dUnknown

proc packageFor(d: Distro, tool: string): string =
  case tool
  of "wimlib-imagex":
    case d
    of dDebian, dSuse: "wimtools"
    of dFedora: "wimlib-utils"
    else: "wimlib"
  of "mkfs.fat": "dosfstools"
  of "sfdisk": (if d == dDebian: "fdisk" else: "util-linux")
  of "mount", "umount": (if d == dDebian: "mount" else: "util-linux")
  else: "util-linux"

proc installCommand(d: Distro, packages: openArray[string]): string =
  ## The command that installs them here, or "" if it isn't known.
  let p = packages.join(" ")
  case d
  of dArch: (if findExe("omarchy").len > 0: "omarchy pkg add " & p else: "sudo pacman -S " & p)
  of dDebian: "sudo apt install " & p
  of dFedora: "sudo dnf install " & p
  of dSuse: "sudo zypper install " & p
  of dAlpine: "doas apk add " & p
  of dVoid: "sudo xbps-install " & p
  of dUnknown: ""

proc installHint*(tools: openArray[string], osRelease = "/etc/os-release"): string =
  ## "Install them with: sudo apt install wimtools", or the like.
  let d = distro(osRelease)
  var packages: seq[string]
  for t in tools:
    let p = packageFor(d, t)
    if p notin packages: packages.add p
  let cmd = installCommand(d, packages)
  if cmd.len > 0: "Install " & (if tools.len == 1: "it" else: "them") & " with: " & cmd
  else: "Install " & packages.join(", ") & " with your package manager."

proc kernelRelease(): string =
  var u: Utsname
  if uname(u) == 0: $cast[cstring](u.release[0].addr) else: ""

proc readsUdf*(): bool =
  ## Can the kernel read UDF, the filesystem of Windows ISOs? True when it
  ## can't be told (in a container, say).
  try:
    for line in lines("/proc/filesystems"):
      if line.splitWhitespace.len > 0 and line.splitWhitespace[^1] == "udf": return true
  except IOError, OSError: discard
  for dir in ["/lib/modules", "/usr/lib/modules"]:
    let mods = dir / kernelRelease()
    if not dirExists(mods): continue
    for f in ["modules.dep", "modules.builtin"]:
      try:
        if "/udf.ko" in readFile(mods / f): return true
      except IOError, OSError: return true
    return false
  true

proc windowsProblem*(): string =
  ## Why this system can't make Windows sticks, or "" if it can. What to
  ## install goes on a line of its own.
  var missing: seq[string]
  for t in WindowsTools:
    if findTool(t).len == 0: missing.add t
  if missing.len > 0:
    return "Making a Windows stick needs " & missing.join(", ") &
           (if missing.len == 1: ", which isn't installed.\n" else: ", which aren't installed.\n") &
           installHint(missing)
  if not readsUdf():
    return "This Linux kernel can't read UDF, the filesystem of Windows ISOs, so it can't " &
           "make Windows sticks. Start the PC with your distribution's standard kernel."
  ""
