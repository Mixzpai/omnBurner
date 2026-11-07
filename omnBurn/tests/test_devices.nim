## Discovering disks, and keeping the system disk out of the list.

import std/[sets, unittest]
import ../src/omnburn/device

suite "devices":
  test "partition names":
    check partitionNode("/dev/sdb", 1) == "/dev/sdb1"
    check partitionNode("/dev/mmcblk0", 1) == "/dev/mmcblk0p1"
    check partitionNode("/dev/nvme0n1", 2) == "/dev/nvme0n1p2"
  test "virtual devices are hidden":
    for n in ["loop0", "zram0", "dm-0", "sr0", "md127", "nbd0", "ram1"]: check isVirtual(n)
  test "the system disk is detected and never offered by default":
    let system = systemDisks()
    check system.len > 0 # whatever holds / on this machine
    for d in enumerateDevices():
      check not d.system and d.isRemovable
    for d in enumerateDevices(showAll = true):
      check not isVirtual(d.name) and d.targetType == ttDisk
      check d.system == (d.name in system)
