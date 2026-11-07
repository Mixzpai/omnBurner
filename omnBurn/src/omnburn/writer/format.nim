## Formatting: give a stick a fresh partition table and filesystem.

import std/[posix, strutils]
import ../device
import lowlevel, protocol

proc format*(a: Action, emit: Emit) =
  let dest = a.targets[0].dest
  let dev = fromPath(dest)
  if dev.targetType != ttDisk: raise wvError(ekRefused, ikUnknown, dest & " is not a whole disk")
  if dev.system and not a.allowSystem:
    raise wvError(ekRefused, ikUnknown, dest & " holds the running system; refusing to format it")
  # Check we may write to it before touching anything, so the parent can escalate.
  let probe = posix.open(dest.cstring, O_RDWR or O_CLOEXEC)
  if probe < 0: raise osError(ekOutputFile, "opening " & dest)
  discard posix.close(probe)
  emit("start " & $dev.size & " -1 1")
  const n = 6
  emit("step 1 " & $n & " Unmounting")
  let (ok, msg) = unmountAll(dev)
  if not ok: raise wvError(ekOutputFile, ikBusy, msg)
  emit("step 2 " & $n & " Wiping old signatures")
  discard runTool(["wipefs", "--all", "--force", dest])
  emit("step 3 " & $n & " Writing a new partition table")
  let typ = if a.fs == "fat32": "c" else: "7"
  discard runTool(["sfdisk", "--wipe", "always", "--wipe-partitions", "always", dest],
                  "label: dos\n,,"  & typ & "\n")
  emit("step 4 " & $n & " Waiting for the new partition")
  let part = waitForPartition(dest)
  emit("step 5 " & $n & " Creating the " & (if a.fs == "fat32": "FAT32" else: "exFAT") & " filesystem")
  if a.fs == "fat32":
    discard runTool(["mkfs.fat", "-F", "32", "-n", a.label.toUpperAscii, part])
  else:
    discard runTool(["mkfs.exfat", "-L", a.label, part])
  emit("step 6 " & $n & " Syncing")
  discard runTool(["sync"])
  emit("done")
