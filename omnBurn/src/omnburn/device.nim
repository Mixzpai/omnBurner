## Discovering disks to burn to (via /sys/class/block and udev's database),
## what's mounted on them, which one holds the running system, and
## unmounting / powering them off.

import std/[algorithm, os, osproc, posix, sets, strutils, tables]
import byteseries

type
  TargetType* = enum
    ttFile = "file", ttDisk = "disk", ttPartition = "partition"

  Removable* = enum
    rmYes = "yes", rmNo = "no", rmUnknown = "unknown"

  Bus* = enum
    busUnknown = "", busUsb = "USB", busMmc = "SD card", busNvme = "NVMe", busAta = "SATA",
    busScsi = "SCSI"

  Partition* = object
    name*, devnode*: string
    size*: int64
    fsType*, label*: string
    mountpoints*: seq[string]

  WriteTarget* = object
    name*: string ## user-friendly name (sda, nvme0n1, or a file path)
    devnode*: string
    size*: int64 ## -1 if unknown
    model*: string ## "" if unknown
    vendor*: string
    removable*: Removable
    targetType*: TargetType
    blockSize*: int64 ## 0 if unknown
    bus*: Bus
    system*: bool ## holds the running system: /, /boot, /home, swap, ...
    readOnly*: bool
    partitions*: seq[Partition]

  Mount* = object
    source*, mountpoint*: string

  DeviceNotFound* = object of CatchableError

const
  SysBlock = "/sys/class/block"
  SystemMounts = ["/", "/boot", "/boot/efi", "/efi", "/usr", "/var", "/home", "/nix"]
  VirtualPrefixes = ["loop", "ram", "zram", "dm-", "md", "nbd", "sr", "fd"]

proc sizeStr*(t: WriteTarget): string =
  if t.size < 0: "[unknown size]" else: formatBytes(t.size)

proc modelStr*(t: WriteTarget): string =
  let m = (if t.model.len > 0 and not t.model.startsWith(t.vendor): t.vendor & " " & t.model
           else: t.model).strip
  if m.len == 0: "[unknown model]" else: m

proc blockSizeStr*(t: WriteTarget): string =
  if t.blockSize <= 0: "[unknown block size]" else: $t.blockSize & " B"

proc isRemovable*(t: WriteTarget): bool =
  ## USB enclosures often claim not to be removable, so trust the bus too.
  t.removable == rmYes or t.bus in {busUsb, busMmc}

proc mountpoints*(t: WriteTarget): seq[string] =
  for p in t.partitions: result.add p.mountpoints

proc `$`*(t: WriteTarget): string =
  if t.targetType == ttDisk:
    t.name & " | " & t.modelStr & " - " & t.sizeStr & " (" & $t.targetType &
      ", removable: " & (if t.isRemovable: "yes" else: $t.removable) & ")"
  else:
    t.name & " | " & t.modelStr & " - " & t.sizeStr & " (" & $t.targetType & ")"

proc readSys(p: string): string =
  try: readFile(p).strip except IOError, OSError: ""

proc realPath(p: string): string =
  var buf: array[4096, char]
  if realpath(p.cstring, cast[cstring](addr buf)) != nil: $cast[cstring](addr buf) else: p

# ---------------------------------------------------------------------------
# Mounts and the system disk

proc unescapeMount(s: string): string =
  ## /proc/self/mountinfo writes spaces and friends as \040 etc.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 3 < s.len and s[i + 1] in {'0' .. '3'}:
      try:
        result.add char(parseOctInt(s[i + 1 .. i + 3]))
        i += 4
        continue
      except ValueError: discard
    result.add s[i]
    inc i

proc readMounts*(): seq[Mount] =
  for line in lines("/proc/self/mountinfo"):
    let parts = line.split(' ')
    let sep = parts.find("-")
    if sep < 0 or parts.len < sep + 3 or parts.len < 5: continue
    let source = unescapeMount(parts[sep + 2])
    if source.startsWith("/dev/"):
      result.add Mount(source: source, mountpoint: unescapeMount(parts[4]))

proc baseDisks*(name: string): seq[string] =
  ## The whole disks under a block device: a partition's disk, or for device
  ## mapper (LUKS, LVM) and md devices, the disks of what they're built on.
  let sys = SysBlock / name
  if fileExists(sys / "partition"):
    return @[realPath(sys).parentDir.lastPathPart]
  var slaves: seq[string]
  try:
    for _, p in walkDir(sys / "slaves"): slaves.add p.lastPathPart
  except OSError: discard
  if slaves.len == 0: return @[name]
  for s in slaves:
    for d in baseDisks(s):
      if d notin result: result.add d

proc devName(path: string): string = realPath(path).lastPathPart

proc systemDisks*(mounts = readMounts()): HashSet[string] =
  for m in mounts:
    if m.mountpoint in SystemMounts:
      for d in baseDisks(devName(m.source)): result.incl d
  try:
    for line in lines("/proc/swaps"):
      let f = line.splitWhitespace
      if f.len >= 2 and f[1] == "partition" and f[0].startsWith("/dev/"):
        for d in baseDisks(devName(f[0])): result.incl d
  except IOError, OSError: discard

proc mountsOn*(disk: string, mounts = readMounts()): seq[Mount] =
  ## Everything mounted from `disk` (a name like "sdb"), deepest first.
  for m in mounts:
    if disk in baseDisks(devName(m.source)): result.add m
  result.sort(proc (a, b: Mount): int = cmp(b.mountpoint.len, a.mountpoint.len))

# ---------------------------------------------------------------------------
# Devices

proc udevProps(sys: string): Table[string, string] =
  let dev = readSys(sys / "dev")
  if dev.len == 0: return
  try:
    for line in lines("/run/udev/data/b" & dev):
      if line.startsWith("E:"):
        let eq = line.find('=')
        if eq > 0: result[line[2 ..< eq]] = line[eq + 1 .. ^1]
  except IOError, OSError: discard

proc isVirtual*(name: string): bool =
  for p in VirtualPrefixes:
    if name.startsWith(p): return true
  "/devices/virtual/" in realPath(SysBlock / name)

proc detectBus(name, sys: string, props: Table[string, string]): Bus =
  let path = realPath(sys)
  if "/usb" in path or props.getOrDefault("ID_BUS") == "usb": busUsb
  elif name.startsWith("mmcblk"): busMmc
  elif name.startsWith("nvme"): busNvme
  elif props.getOrDefault("ID_BUS") == "ata": busAta
  elif props.getOrDefault("ID_BUS") == "scsi": busScsi
  else: busUnknown

proc readPartitions(disk: string, mounts: seq[Mount]): seq[Partition] =
  let sys = SysBlock / disk
  try:
    for kind, p in walkDir(sys):
      let n = p.lastPathPart
      if kind == pcDir and n.startsWith(disk) and fileExists(p / "partition"):
        let props = udevProps(p)
        var part = Partition(name: n, devnode: "/dev" / n, size: -1,
                             fsType: props.getOrDefault("ID_FS_TYPE"),
                             label: props.getOrDefault("ID_FS_LABEL"))
        try: part.size = parseBiggestInt(readSys(p / "size")) * 512
        except ValueError: discard
        var sources = @[n] # the partition, or LUKS/LVM devices built on it
        for _, h in walkDir(p / "holders"): sources.add h.lastPathPart
        for m in mounts:
          if devName(m.source) in sources and m.mountpoint notin part.mountpoints:
            part.mountpoints.add m.mountpoint
        result.add part
  except OSError: discard
  result.sort(proc (a, b: Partition): int = cmp(a.name, b.name))

proc fromDevName(name: string, mounts: seq[Mount], system: HashSet[string]): WriteTarget =
  let devnode = "/dev" / name
  var st: Stat
  if stat(devnode.cstring, st) != 0: # fileExists() is false for block devices
    raise newException(DeviceNotFound, "Could not find " & devnode)
  let sys = SysBlock / name
  let props = udevProps(sys)
  result = WriteTarget(name: name, devnode: devnode, size: -1,
                       model: readSys(sys / "device/model"),
                       vendor: readSys(sys / "device/vendor"))
  if result.model.len == 0: result.model = props.getOrDefault("ID_MODEL").replace('_', ' ')
  result.removable = case readSys(sys / "removable")
    of "0": rmNo
    of "1": rmYes
    else: rmUnknown
  try: result.size = parseBiggestInt(readSys(sys / "size")) * 512
  except ValueError: discard
  result.targetType = if fileExists(sys / "partition"): ttPartition else: ttDisk
  try: result.blockSize = parseBiggestInt(readSys(sys / "queue/physical_block_size"))
  except ValueError: discard
  result.bus = detectBus(name, sys, props)
  result.readOnly = readSys(sys / "ro") == "1"
  for d in baseDisks(name):
    if d in system: result.system = true
  if result.targetType == ttDisk:
    result.partitions = readPartitions(name, mounts)
  else:
    for m in mounts:
      if devName(m.source) == name:
        result.partitions.add Partition(name: name, devnode: devnode, size: result.size,
                                        mountpoints: @[m.mountpoint])

proc fromPath*(path: string): WriteTarget =
  ## Anything under /dev (symlinks like /dev/disk/by-id/* included) is looked
  ## up as a block device; everything else is treated as a regular file.
  let resolved = realPath(path)
  if resolved.startsWith("/dev/") or resolved.startsWith(SysBlock & "/"):
    let mounts = readMounts()
    return fromDevName(resolved.lastPathPart, mounts, systemDisks(mounts))
  WriteTarget(name: path, devnode: path, size: -1, removable: rmUnknown,
              targetType: ttFile)

proc refreshed*(t: WriteTarget): WriteTarget =
  ## Re-reads a device's details (mounts change, sticks get unplugged).
  if t.targetType == ttFile: t else: fromPath(t.devnode)

proc enumerateDevices*(showAll = false): seq[WriteTarget] =
  ## Whole disks worth burning to: removable ones, or with `showAll`, every
  ## real disk (the system disk included, flagged). Loop devices, zram,
  ## device mapper, optical drives and empty card readers are never listed.
  let mounts = readMounts()
  let system = systemDisks(mounts)
  for kind, p in walkDir(SysBlock):
    let name = p.lastPathPart
    if isVirtual(name) or fileExists(p / "partition"): continue
    try:
      let t = fromDevName(name, mounts, system)
      if t.size == 0: continue
      if showAll or (t.isRemovable and not t.system): result.add t
    except CatchableError: discard
  result.sort(proc (a, b: WriteTarget): int = cmp(a.devnode, b.devnode))

proc partitionNode*(disk: string, n: int): string =
  ## /dev/sdb + 1 -> /dev/sdb1, /dev/mmcblk0 + 1 -> /dev/mmcblk0p1
  if disk.len > 0 and disk[^1] in Digits: disk & "p" & $n else: disk & $n

# ---------------------------------------------------------------------------
# Unmounting and powering off

proc umount2(target: cstring, flags: cint): cint {.importc, header: "<sys/mount.h>".}

proc run(cmd: openArray[string]): (bool, string) =
  if findExe(cmd[0]).len == 0: return (false, cmd[0] & " not found")
  try:
    let (output, code) = execCmdEx(quoteShellCommand(cmd))
    (code == 0, output.strip)
  except OSError as e: (false, e.msg)

proc unmountAll*(t: WriteTarget): (bool, string) =
  ## Unmounts everything on the disk (via udisks, or directly as root), and
  ## closes unlocked LUKS containers on it. Returns (false, why) on failure.
  if t.targetType == ttFile: return (true, "")
  let name = realPath(t.devnode).lastPathPart
  for m in mountsOn(name):
    var (ok, msg) = run(["udisksctl", "unmount", "--no-user-interaction", "-b", m.source])
    if not ok and geteuid() == 0:
      ok = umount2(m.mountpoint.cstring, 0) == 0
      if not ok: msg = $strerror(errno)
    if not ok:
      return (false, m.source & " is mounted at " & m.mountpoint & " and couldn't be unmounted: " & msg)
  let sys = SysBlock / name
  try:
    for kind, p in walkDir(sys):
      if kind != pcDir or not fileExists(p / "partition"): continue
      for _, h in walkDir(p / "holders"):
        if h.lastPathPart.startsWith("dm-"):
          let (ok, msg) = run(["udisksctl", "lock", "--no-user-interaction", "-b", "/dev" / p.lastPathPart])
          if not ok:
            return (false, "/dev/" & p.lastPathPart & " is in use by /dev/" & h.lastPathPart &
                    " and couldn't be closed: " & msg)
  except OSError: discard
  (true, "")

proc powerOff*(t: WriteTarget): (bool, string) =
  ## Flushes and powers off the drive, so it can be pulled out safely.
  if t.targetType == ttFile: return (true, "")
  discard run(["sync"])
  run(["udisksctl", "power-off", "--no-user-interaction", "-b", t.devnode])
