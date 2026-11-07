## The parent's view of a job, built from the writer's messages, and escalating to root.

import std/[monotimes, posix, times, unittest]
import ../src/omnburn/[byteseries, device, herder, writer]

suite "job state":
  let t0 = getMonoTime()
  proc at(s: int): MonoTime = t0 + initDuration(seconds = s)
  let disks = @[WriteTarget(name: "sdy", devnode: "/dev/sdy", targetType: ttDisk),
                WriteTarget(name: "sdz", devnode: "/dev/sdz", targetType: ttDisk)]

  test "progress and ratios":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(0), "start 80 400 2")
    j.onLine(at(0), "phase write")
    j.onLine(at(1), "bytes 20 40 30")
    check j.phase == phWrite and j.rawTotal == 80 and j.outTotal == 400
    check j.readHist.lastDatapoint == (1.0, 20'i64)
    check j.targets[1].write.lastDatapoint == (1.0, 30'i64)
    check j.writeRatio(j.targets[0]) == 0.1
    j.outTotal = -1 # unknown decompressed size: go by the input read
    check j.writeRatio(j.targets[0]) == 0.25
  test "full happy path":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(0), "start 100 512 2")
    j.onLine(at(0), "phase write")
    j.onLine(at(1), "bytes 100 512 512")
    j.onLine(at(1), "hash aa bb")
    j.onLine(at(1), "phase verify")
    check j.phase == phVerify and j.writtenBytes == 512 and j.hasVerify
    check j.fileHash == "aa" and j.imageHash == "bb"
    j.onLine(at(2), "bytes 100 256 512")
    check j.verifyRatio(j.targets[0]) == 0.5
    j.onLine(at(2), "done")
    check j.isFinished and j.ok and j.finishTime == at(2)
  test "one of two targets fails":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(0), "start 100 512 2")
    j.onLine(at(1), "fail 1 end_of_output unknown no space left")
    j.onLine(at(1), "bytes 100 512 0")
    j.onLine(at(2), "done")
    check j.phase == phDone and not j.ok and j.okCount == 1
    check j.targets[1].failed and j.targets[1].error.kind == ekEndOfOutput
    check j.targets[1].write.bytesEncountered == 0
  test "all targets fail":
    var j = newJob(opBurn, disks[0 .. 0], t0)
    j.onLine(at(1), "fail 0 verification_failed unknown mismatch near byte 4")
    j.onLine(at(2), "done")
    check j.phase == phFailed and j.error.kind == ekVerificationFailed
  test "sudden termination is an error; finishing is idempotent":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(1), "bytes 20 20 20")
    j.onEof(at(2))
    check j.isFinished and not j.ok and j.error.kind == ekUnexpectedTermination
    check j.finishTime == at(2)
    var k = newJob(opBurn, disks, t0)
    k.onLine(at(1), "done")
    k.onEof(at(3))
    k.onLine(at(4), "error unknown unknown late")
    check k.ok and k.finishTime == at(1)
  test "error lines and permissions":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(1), "error output permission_denied opening /dev/sdz: Permission denied")
    check j.error.kind == ekOutputFile and j.error.io == ikPermissionDenied
    check $j.error == "Error handling output: Permission denied while opening file!"
    check j.needsRoot == (geteuid() != 0)
  test "format steps and backup results":
    var f = newJob(opFormat, disks[0 .. 0], t0)
    f.onLine(at(1), "step 3 6 Writing a new partition table")
    check f.step == 3 and f.steps == 6 and f.stepText == "Writing a new partition table"
    var b = newJob(opBackup, disks[0 .. 0], t0)
    b.onLine(at(1), "done abc123")
    check b.ok and b.extra == "abc123"
  test "malformed lines are ignored":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(1), "bytes x y")
    j.onLine(at(1), "fail nope")
    j.onLine(at(1), "data 0 zz")
    j.onLine(at(1), "")
    check not j.isFinished and j.data.len == 0

  test "data for the hex view":
    var j = newJob(opBurn, disks, t0)
    j.onLine(at(1), "phase write")
    j.onLine(at(1), "data 1048576 004869ff")
    j.onLine(at(2), "phase verify")
    j.onLine(at(2), "data 0 41")
    check j.data.len == 2
    check j.data[0].offset == 1048576 and j.data[0].bytes == "\0Hi\xff" and not j.data[0].verify
    check j.data[1].offset == 0 and j.data[1].bytes == "A" and j.data[1].verify
    for i in 0 ..< 500: j.onLine(at(3), "data " & $i & " 00")
    check j.data.len == 200 and j.data[^1].offset == 499 # only the latest are kept

suite "escalation":
  test "wrapping commands":
    let cmd = @["some/proc", "two", "--three", "\"four\""]
    check wrapCommand(emSudo, cmd) == @["sudo", "sh", "-c", "some/proc two --three '\"four\"'"]
    check wrapCommand(emSudo, cmd, noPrompt = true)[0 .. 3] == @["sudo", "-n", "sh", "-c"]
    check wrapCommand(emSu, cmd)[0 .. 2] == @["su", "root", "-c"]
