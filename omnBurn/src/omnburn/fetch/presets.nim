## The distributions omnBurn can download by name, and finding each one's
## current image and its checksum and signature files (this goes online).

import std/[json, os, strutils, times]
import latest, microsoft, web

type
  Preset* = enum ## in menu order: Omarchy, then by name
    psOmarchy = "omarchy", psArch = "arch", psCachyOS = "cachyos", psDebian = "debian",
    psElementary = "elementary", psEndeavourOS = "endeavouros", psFedora = "fedora",
    psKali = "kali", psMint = "mint", psManjaro = "manjaro", psNixOS = "nixos",
    psOpenSUSE = "opensuse", psPopOS = "popos", psPopOSNvidia = "popos-nvidia", psQubes = "qubes",
    psRaspiOS = "raspios", psTails = "tails", psUbuntu = "ubuntu",
    psWindows = "windows" ## not downloadable by us: see WindowsPage

  Sidecar* = object
    url*: string     ## where it's published, or "" when `content` is known up front
    suffix*: string  ## saved next to the image as <image><suffix>
    content*: string ## e.g. a hash from the distribution's own download API

  Resolved* = object ## a preset's current image and its checksum/signature files
    url*: string
    sidecars*: seq[Sidecar]

const
  ArchUrl* = "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
  PresetInfo: array[Preset, tuple[name, edition: string]] = [
    psOmarchy: ("Omarchy", "latest release"),
    psArch: ("Arch Linux", "monthly release"),
    psCachyOS: ("CachyOS", "desktop edition"),
    psDebian: ("Debian", "netinst, current stable"),
    psElementary: ("elementary OS", "latest release"),
    psEndeavourOS: ("EndeavourOS", "latest release"),
    psFedora: ("Fedora", "Workstation (GNOME)"),
    psKali: ("Kali Linux", "installer"),
    psMint: ("Linux Mint", "Cinnamon edition"),
    psManjaro: ("Manjaro", "KDE Plasma edition"),
    psNixOS: ("NixOS", "graphical installer"),
    psOpenSUSE: ("openSUSE", "Tumbleweed (DVD)"),
    psPopOS: ("Pop!_OS", "for Intel/AMD graphics"),
    psPopOSNvidia: ("Pop!_OS", "for NVIDIA graphics"),
    psQubes: ("Qubes OS", "latest release"),
    psRaspiOS: ("Raspberry Pi OS", "64-bit, for SD cards"),
    psTails: ("Tails", "USB image"),
    psUbuntu: ("Ubuntu", "Desktop, latest LTS"),
    psWindows: ("Windows 11", "from Microsoft's website")]

proc displayName*(p: Preset): string = PresetInfo[p].name
proc edition*(p: Preset): string = PresetInfo[p].edition

proc side(url, suffix: string): Sidecar = Sidecar(url: url, suffix: suffix)

proc knownHash(url, sha256: string): seq[Sidecar] =
  ## A hash from a download API, saved as <image>.sha256.
  if sha256.len == 64 and sha256.allCharsInSet(HexDigits):
    result.add Sidecar(suffix: ".sha256", content: sha256 & "  " & url.extractFilename & "\n")

proc sums(url, list, sig: string): Resolved =
  ## An image with a SHA256SUMS-style list (and its signature) next to it.
  Resolved(url: url, sidecars: @[side(url.dirOf & "/" & list, ".SHA256SUMS"),
                                 side(url.dirOf & "/" & list & sig, ".SHA256SUMS" & sig)])

proc fedora(): Resolved =
  var best = -1
  var sha = ""
  for r in fetchJson("https://fedoraproject.org/releases.json").getElems:
    let (ver, link) = (r{"version"}.getStr, r{"link"}.getStr)
    if r{"variant"}.getStr == "Workstation" and r{"arch"}.getStr == "x86_64" and
        link.isUrl and link.endsWith(".iso") and ver.len > 0 and ver.allCharsInSet(Digits) and
        parseInt(ver) > best:
      best = parseInt(ver)
      result.url = link
      sha = r{"sha256"}.getStr
  if best < 0: raise newException(FetchError, "no Fedora Workstation release found on fedoraproject.org")
  # The signed CHECKSUM file sits next to the ISO, under a name that can't be
  # worked out from the ISO's, so look it up on the main server's listing.
  let dir = result.url.dirOf.replace("://download.fedoraproject.org/", "://dl.fedoraproject.org/")
  try:
    let (name, _) = newest(fetchText(dir & "/"), "Fedora-Workstation-*-CHECKSUM")
    if name.len > 0: result.sidecars.add side(dir & "/" & name, ".CHECKSUM")
  except FetchError: discard
  if result.sidecars.len == 0: result.sidecars = knownHash(result.url, sha)

proc popOS(channel: string): Resolved =
  ## The API is per release, so try the newest possible LTS first.
  let yy = now().year mod 100
  for y in countdown(yy - yy mod 2, 22, 2):
    let (body, code) = curl(["https://api.pop-os.org/builds/" & $y & ".04/" & channel & "?arch=amd64"])
    if code != 0: continue
    try:
      let j = parseJson(body)
      let url = j{"url"}.getStr
      if url.isUrl: return Resolved(url: url, sidecars: knownHash(url, j{"sha_sum"}.getStr))
    except JsonParsingError: discard
  raise newException(FetchError, "no Pop!_OS release found on api.pop-os.org")

proc tails(): Resolved =
  for inst in fetchJson("https://tails.net/install/v2/Tails/amd64/stable/latest.json"){"installations"}.getElems:
    for path in inst{"installation-paths"}.getElems:
      if path{"type"}.getStr != "img": continue
      for f in path{"target-files"}.getElems:
        let url = f{"url"}.getStr
        if url.isUrl and url.endsWith(".img"):
          return Resolved(url: url, sidecars: knownHash(url, f{"sha256"}.getStr) & side(url & ".sig", ".sig"))
  raise newException(FetchError, "no Tails USB image found on tails.net")

proc isLts(v: seq[int]): bool = v.len == 2 and v[1] == 4 and v[0] mod 2 == 0

proc resolvePreset*(p: Preset): Resolved =
  ## Looks up the preset's current image (this goes online).
  case p
  of psOmarchy:
    let (url, _) = found(fetchText("https://omarchy.org"), "https://iso.omarchy.org/omarchy-#.iso",
                         "ISO link", "omarchy.org")
    Resolved(url: url, sidecars: @[side(url & ".sha256", ".sha256"), side(url & ".sig", ".sig")])
  of psArch:
    Resolved(url: ArchUrl, sidecars: @[side(ArchUrl.dirOf & "/sha256sums.txt", ".sha256"),
                                       side(ArchUrl & ".sig", ".sig")])
  of psCachyOS:
    let (name, v) = found(fetchText("https://cachyos.org/download/"), "cachyos-desktop-linux-#.iso",
                          "desktop ISO", "cachyos.org")
    let url = "https://cdn77.cachyos.org/ISO/desktop/" & v[0] & "/" & name
    Resolved(url: url, sidecars: @[side(url & ".sha256", ".sha256"), side(url & ".sig", ".sig")])
  of psDebian:
    sums(listed("https://cdimage.debian.org/debian-cd/current/amd64/iso-cd",
                "debian-#-amd64-netinst.iso", "netinst ISO"), "SHA256SUMS", ".sign")
  of psElementary:
    # The page's links carry a token that expires within hours, so get the
    # checksum now rather than after a long download.
    let (url, _) = found(fetchText("https://elementary.io/"),
                         "https://dl.elementaryos.org/*/elementaryos-#-stable-amd64.#.iso",
                         "ISO link", "elementary.io")
    let words = fetchText(url & ".sha256.txt").splitWhitespace
    Resolved(url: url, sidecars: knownHash(url, if words.len > 0: words[0] else: ""))
  of psEndeavourOS:
    let url = listed("https://mirror.alpix.eu/endeavouros/iso", "EndeavourOS_*-#.iso", "ISO")
    Resolved(url: url, sidecars: @[side(url & ".sha512sum", ".sha512sum"), side(url & ".sig", ".sig")])
  of psFedora: fedora()
  of psKali:
    sums(listed("https://cdimage.kali.org/current", "kali-linux-#-installer-amd64.iso",
                "installer ISO"), "SHA256SUMS", ".gpg")
  of psMint:
    let release = listed("https://mirrors.edge.kernel.org/linuxmint/stable", "#", "release")
    sums(listed(release, "linuxmint-#-cinnamon-64bit.iso", "Cinnamon ISO"), "sha256sum.txt", ".gpg")
  of psManjaro:
    let (url, _) = found(fetchText("https://manjaro.org/products/download/x86"),
                         "https://download.manjaro.org/kde/#/manjaro-kde-#-#-linux#.iso",
                         "KDE Plasma ISO", "manjaro.org")
    Resolved(url: url, sidecars: @[side(url & ".sha512", ".sha512"), side(url & ".sig", ".sig")])
  of psNixOS:
    let (alias, _) = found(fetchText("https://nixos.org/download/"),
                           "https://channels.nixos.org/nixos-#/latest-nixos-graphical-x86_64-linux.iso",
                           "graphical ISO", "nixos.org")
    let url = finalUrl(alias) # the versioned file it redirects to
    Resolved(url: url, sidecars: @[side(url & ".sha256", ".sha256")])
  of psOpenSUSE:
    # "Current" is an alias; its checksum file names the actual snapshot.
    const dir = "https://download.opensuse.org/tumbleweed/iso"
    let words = fetchText(dir & "/openSUSE-Tumbleweed-DVD-x86_64-Current.iso.sha256").splitWhitespace
    var nums: seq[string]
    if words.len < 2 or not globMatch(words[1], "openSUSE-Tumbleweed-DVD-x86_64-*.iso", nums):
      raise newException(FetchError, "no Tumbleweed snapshot found on download.opensuse.org")
    let url = dir & "/" & words[1]
    Resolved(url: url, sidecars: @[side(url & ".sha256", ".sha256"), side(url & ".sha256.asc", ".sha256.asc")])
  of psPopOS: popOS("intel")
  of psPopOSNvidia: popOS("nvidia")
  of psQubes:
    let url = listed("https://mirrors.edge.kernel.org/qubes/iso", "Qubes-R#-x86_64.iso", "ISO")
    Resolved(url: url, sidecars: @[side(url & ".DIGESTS", ".DIGESTS"), side(url & ".DIGESTS.asc", ".DIGESTS.asc")])
  of psRaspiOS:
    let url = finalUrl("https://downloads.raspberrypi.com/raspios_arm64_latest")
    Resolved(url: url, sidecars: @[side(url & ".sha256", ".sha256"), side(url & ".sig", ".sig")])
  of psTails: tails()
  of psUbuntu:
    let series = listed("https://releases.ubuntu.com", "#", "LTS release", isLts)
    sums(listed(series, "ubuntu-#-desktop-amd64.iso", "desktop ISO"), "SHA256SUMS", ".gpg")
  of psWindows:
    raise newException(FetchError, "Microsoft hands out Windows download links only on its " &
                       "website, in a browser: " & WindowsPage)
