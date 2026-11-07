## GPG signature checks, run in the background while the user picks a disk.
## A signature may cover the image itself (image.iso.sig), the checksum
## file that lists it (SHA256SUMS.sig), or be inside that file (Fedora's
## cleartext-signed CHECKSUM).

import std/[os, osproc, streams, strutils]

type
  SigStatus* = enum
    ssNone = "no signature found"
    ssChecking = "checking…"
    ssGood = "good signature"
    ssBad = "BAD SIGNATURE"
    ssNoKey = "can't check: missing public key"
    ssExpired = "good signature, but the key has expired"
    ssRevoked = "signed by a REVOKED key"
    ssError = "couldn't check"

  SigCheck* = object
    status*: SigStatus
    image*: string
    sigFile*, signedFile*: string ## signedFile is "" for a cleartext signature
    signer*, keyId*, message*: string
    process: Process

proc isFinal*(c: SigCheck): bool = c.status notin {ssChecking}

const SigExts = [".sig", ".asc", ".gpg", ".sign"]

proc findSignature*(image: string): (bool, string, string) =
  ## Returns (found, signature file, the file it signs). For a checksum file
  ## with the signature inside it, the signature file is that file and the
  ## signed one is "".
  for ext in SigExts:
    if fileExists(image & ext): return (true, image & ext, image)
  let dir = image.parentDir
  let base = image.extractFilename
  for sums in [image & ".SHA256SUMS", image & ".CHECKSUM", image & ".DIGESTS", image & ".sha256",
               image & ".sha512", image & ".sha512sum", dir / "SHA256SUMS", dir / "sha256sums.txt",
               dir / "SHA512SUMS", dir / "sha512sums.txt"]:
    if not fileExists(sums): continue
    var content: string
    try:
      if getFileSize(sums) > 1 shl 20: continue
      content = readFile(sums)
    except IOError, OSError: continue
    if base notin content: continue
    for ext in SigExts:
      if fileExists(sums & ext): return (true, sums & ext, sums)
    if "-----BEGIN PGP SIGNED MESSAGE-----" in content: return (true, sums, "")

proc parseGpgStatus*(output: string): (SigStatus, string, string) =
  ## Reads gpg's --status-fd lines. Returns (status, signer, key id).
  result = (ssError, "", "")
  var good = false
  for line in output.splitLines:
    if not line.startsWith("[GNUPG:] "): continue
    let f = line[9 .. ^1].split(' ', 2)
    let rest = if f.len > 2: f[2] else: ""
    case f[0]
    of "GOODSIG": good = true; result = (ssGood, rest, f[1])
    of "EXPKEYSIG": result = (ssExpired, rest, f[1])
    of "REVKEYSIG": result = (ssRevoked, rest, f[1])
    of "BADSIG": return (ssBad, rest, f[1])
    of "NO_PUBKEY":
      if not good: result = (ssNoKey, "", f[1])
    of "ERRSIG":
      if not good and result[0] != ssNoKey: result = (ssError, "", f[1])
    else: discard

proc startCheck*(sigFile, signedFile: string): SigCheck =
  result = SigCheck(status: ssChecking, sigFile: sigFile, signedFile: signedFile)
  if findExe("gpg").len == 0:
    result.status = ssError
    result.message = "gpg is not installed"
    return
  try:
    var args = @["--batch", "--no-tty", "--status-fd", "1", "--verify", sigFile]
    if signedFile.len > 0: args.add signedFile
    result.process = startProcess("gpg", args = args, options = {poUsePath, poStdErrToStdOut})
  except OSError as e:
    result.status = ssError
    result.message = e.msg

proc checkImage*(image: string): SigCheck =
  let (found, sigFile, signed) = findSignature(image)
  if not found: return SigCheck(status: ssNone, image: image)
  result = startCheck(sigFile, signed)
  result.image = image

proc poll*(c: var SigCheck): bool =
  ## Returns true once, when the check finishes.
  if c.status != ssChecking or c.process == nil: return false
  if c.process.peekExitCode == -1: return false
  let output = c.process.outputStream.readAll
  c.process.close()
  c.process = nil
  (c.status, c.signer, c.keyId) = parseGpgStatus(output)
  if c.status == ssError and c.message.len == 0:
    for l in output.splitLines:
      if l.startsWith("gpg: ") and "Signature made" notin l and "using " notin l:
        c.message = l[5 .. ^1]
  true

proc wait*(c: var SigCheck) =
  if c.process != nil:
    discard c.process.waitForExit()
    discard c.poll()

proc cancel*(c: var SigCheck) =
  if c.process != nil:
    c.process.terminate()
    c.process.close()
    c.process = nil

proc coversImage*(c: SigCheck): bool =
  ## Whether the signature is over the image itself rather than a checksum file.
  c.signedFile.len > 0 and c.signedFile == c.image

proc describe*(c: SigCheck): string =
  result = $c.status
  case c.status
  of ssGood, ssExpired, ssRevoked, ssBad:
    if c.signer.len > 0: result.add " from " & c.signer
    if not c.coversImage:
      result.add " (on " & (if c.signedFile.len > 0: c.signedFile else: c.sigFile).extractFilename & ")"
  of ssNoKey:
    result.add " " & c.keyId
  of ssError:
    if c.message.len > 0: result.add ": " & c.message
  else: discard

proc fetchKey*(keyId: string): (bool, string) =
  ## Imports a missing public key from a keyserver (only when asked to).
  try:
    let (output, code) = execCmdEx(quoteShellCommand(["gpg", "--batch", "--keyserver",
                                   "hkps://keyserver.ubuntu.com", "--recv-keys", keyId]))
    (code == 0, output.strip.splitLines[^1])
  except OSError as e: (false, e.msg)
