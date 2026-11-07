## Command-line parsing.

import std/[options, os, osproc, strutils, unittest]
import ../src/omnburn/[cli, compression, fetch, hash]
import common

suite "cli":
  let img = currentSourcePath()
  test "parse valid hash arg":
    let r = parseHashArg("sha384-" & sha384b64)
    check r.kind == haHash and r.alg == haSha384 and r.expected == b64Bytes(sha384b64)
  test "skip and ask, any case":
    for s in ["skip", "none", "NONE", "SkIp"]: check parseHashArg(s).kind == haSkip
    for s in ["ask", "ASK", "asK"]: check parseHashArg(s).kind == haAsk
  test "invalid hash args":
    for s in ["asdf-fdsu", "sha256-vf798", "sha256-", "", "f9od:fd"]:
      expect CliError: discard parseHashArg(s)
  test "burn options":
    let c = parseArgs(@["burn", img, "-o", "/tmp/x", "-o", "/tmp/y", "-z", "gz", "--hash", "skip",
                        "-f", "--root=never", "--interactive", "never", "--hash-of", "raw",
                        "--no-verify", "--hash-first", "--eject"])
    check c.kind == cmdBurn
    check c.burn.outputs == @["/tmp/x", "/tmp/y"] and c.burn.compression == caGz
    check c.burn.common.force and c.burn.common.root == usNever
    check c.burn.common.interactive == iaNever and c.burn.hash.kind == haSkip
    check not c.burn.verify and c.burn.hashFirst and c.burn.eject
    check c.burn.hashOf.hashTarget == htImage
    check parseArgs(@[img]).burn.image == img # `burn` is optional
    expect CliError: discard parseArgs(@["burn", img, "--nope"])
    expect CliError: discard parseArgs(@["burn", "/does/not/exist"])
    expect CliError: discard parseArgs(@["burn", img, "--fs", "exfat"]) # restore-only
  test "option syntaxes":
    let c = parseArgs(@["-fo/tmp/a", "-o=/tmp/b", "--hash=skip", "-zxz", img, "-o", "-"])
    check c.burn.outputs == @["/tmp/a", "/tmp/b", "-"] and c.burn.common.force
    check c.burn.hash.kind == haSkip and c.burn.compression == caXz and c.burn.image == img
    let dashed = "-omnburn-test.iso" # relative, so it really starts with a dash
    let cwd = getCurrentDir()
    setCurrentDir(getTempDir())
    defer: setCurrentDir(cwd)
    writeFile(dashed, "")
    defer: removeFile(dashed)
    check parseArgs(@["burn", "--", dashed]).burn.image == dashed
    expect CliError: discard parseArgs(@["burn", img, "-o"])
    expect CliError: discard parseArgs(@["burn", img, "--hash="])
    expect CliError: discard parseArgs(@["burn", img, "-fx"])
  test "no arguments opens the app; URLs and presets":
    check parseArgs(@[]).kind == cmdApp
    check parseArgs(@["burn"]).burn.image == ""
    check parseArgs(@["burn", "https://example.com/a.iso"]).burn.image == "https://example.com/a.iso"
    check parseArgs(@["omarchy"]).burn.preset == some(psOmarchy)
    check parseArgs(@["burn", "arch"]).burn.preset == some(psArch)
    check parseArgs(@["windows"]).burn.preset == some(psWindows)
    check parseArgs(@["elementary"]).burn.preset == some(psElementary)
  test "bare subcommands from a real command line":
    # This once read `omnburn burn` as an image called "burn", which only
    # showed up in the real binary (std/parseopt read the process's argv).
    let bin = currentSourcePath.parentDir.parentDir / "omnburn"
    if not fileExists(bin): skip()
    else:
      for (sub, msg) in [("burn", "needs at least one -o"), ("backup", "needs the disk"),
                         ("restore", "needs the disk")]:
        let (output, code) = execCmdEx(bin & " " & sub & " </dev/null")
        check code == 1 and msg in output
  test "backup and restore":
    let b = parseArgs(@["backup", "/dev/sdz", "-o", "x.img.xz", "-z", "xz"])
    check b.kind == cmdBackup and b.backup.disk == "/dev/sdz" and b.backup.compression == cfXz
    check parseArgs(@["backup"]).backup.compression == cfZst
    expect CliError: discard parseArgs(@["backup", "-z", "bz2"])
    let r = parseArgs(@["restore", "/dev/sdz", "--fs", "fat32", "--label", "STICK", "--eject"])
    check r.kind == cmdRestore and r.restore.fs == fsFat32 and r.restore.label == "STICK"
    check r.restore.eject
    check parseArgs(@["restore"]).restore.fs == fsExfat
    expect CliError: discard parseArgs(@["restore", "--fs", "fat32", "--label", "TWELVE_CHARS"])
    expect CliError: discard parseArgs(@["restore", "--fs", "ntfs"])
