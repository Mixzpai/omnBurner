## Finding the programs omnBurn runs, and what to install when they're missing.

import std/[os, unittest]
import ../src/omnburn/tools
import scratch

suite "tools":
  proc hint(osRelease: string, tools: varargs[string]): string =
    let f = dir / "os-release"
    writeFile(f, osRelease)
    installHint(tools, f)
  test "finds programs in sbin that aren't on the PATH":
    let saved = getEnv("PATH")
    putEnv("PATH", "/nonexistent")
    defer: putEnv("PATH", saved)
    check findTool("sh").len == 0 or findTool("sh") in ["/usr/local/sbin/sh", "/usr/sbin/sh", "/sbin/sh"]
    if fileExists("/usr/sbin/mkfs.fat"): check findTool("mkfs.fat") == "/usr/sbin/mkfs.fat"
    check findTool("no-such-tool-anywhere").len == 0
  test "the packages to install, per distribution":
    check hint("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n", "wimlib-imagex", "mkfs.fat", "sfdisk") ==
      "Install them with: sudo apt install wimtools dosfstools fdisk"
    check hint("ID=fedora\n", "wimlib-imagex") == "Install it with: sudo dnf install wimlib-utils"
    check hint("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n", "wimlib-imagex", "wipefs") ==
      "Install them with: sudo zypper install wimtools util-linux"
    check hint("ID=alpine\n", "wimlib-imagex", "blockdev") == "Install them with: doas apk add wimlib util-linux"
    check hint("ID=void\n", "mkfs.fat") == "Install it with: sudo xbps-install dosfstools"
    check hint("ID=pop\nID_LIKE=\"ubuntu debian\"\n", "mount") == "Install it with: sudo apt install mount"
    check hint("ID=nixos\n", "wimlib-imagex", "mkfs.fat") ==
      "Install wimlib, dosfstools with your package manager."
    check installHint(["wimlib-imagex"], dir / "missing") ==
      "Install wimlib with your package manager."
    let arch = hint("ID=arch\n", "wimlib-imagex")
    check arch in ["Install it with: sudo pacman -S wimlib", "Install it with: omarchy pkg add wimlib"]

removeDir(dir)
