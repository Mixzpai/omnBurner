## Downloading an image with curl, resuming a partial download, then the
## checksum and signature files that go with it.

import std/[monotimes, os, osproc, streams, strutils]
import ../[byteseries, desktop, logging]
import presets, web

type
  DlPhase* = enum
    dlFile, dlSidecars, dlDone, dlFailed

  Download* = object
    url*, dest*: string
    total*: int64 ## -1 if unknown
    phase*: DlPhase
    hist*: ByteSeries
    error*: string
    sidecars*: seq[string] ## the checksum/signature files we got
    resumedFrom*: int64
    process: Process
    candidates: seq[(string, string)] ## sidecar (url, local path)

proc fileNameOf*(url: string): string =
  result = url.split('?')[0].split('#')[0].strip(leading = false, chars = {'/'}).extractFilename
  if result.len == 0: result = "download.img"

proc remoteSize(url: string): int64 =
  ## Content-Length after redirects, or -1.
  result = -1
  try:
    let (headers, code) = curl(["-I", url])
    if code != 0: return
    for line in headers.splitLines:
      if line.toLowerAscii.startsWith("content-length:"):
        result = parseBiggestInt(line.split(':', 1)[1].strip) # the last one wins
  except CatchableError: discard

proc sidecarCandidates(url, dest: string): seq[(string, string)] =
  ## Checksum and signature files that are commonly published next to images.
  let dir = url.split('?')[0].rsplit('/', 1)[0]
  if url.startsWith("https://iso.omarchy.org/"):
    return @[(url & ".sha256", dest & ".sha256"), (url & ".sig", dest & ".sig")]
  if url == ArchUrl or "/archlinux" in url and url.endsWith(".iso"):
    return @[(dir & "/sha256sums.txt", dest & ".sha256"), (url & ".sig", dest & ".sig")]
  @[(url & ".sha256", dest & ".sha256"), (url & ".sha256sum", dest & ".sha256sum"),
    (dir & "/SHA256SUMS", dest & ".SHA256SUMS"), (dir & "/SHA256SUMS.sig", dest & ".SHA256SUMS.sig"),
    (dir & "/SHA256SUMS.gpg", dest & ".SHA256SUMS.gpg"), (dir & "/SHA256SUMS.sign", dest & ".SHA256SUMS.sign"),
    (url & ".sig", dest & ".sig"), (url & ".asc", dest & ".asc")]

proc startDownload*(url: string, dir = downloadDir(), sidecars: seq[Sidecar] = @[]): Download =
  ## Starts downloading `url` into `dir`, resuming a partial download. The
  ## checksum and signature files come from `sidecars`, or are guessed.
  createDir(dir)
  let dest = dir / fileNameOf(url)
  result = Download(url: url, dest: dest, total: remoteSize(url), hist: initByteSeries(getMonoTime()))
  if sidecars.len == 0: result.candidates = sidecarCandidates(url, dest)
  for s in sidecars:
    if s.url.len > 0: result.candidates.add (s.url, dest & s.suffix)
    else: writeFile(dest & s.suffix, s.content)
  info("Downloading " & url & " to " & dest & " (" & $result.total & " bytes)")
  let part = dest & ".part"
  if result.total > 0 and fileExists(dest) and getFileSize(dest) == result.total:
    info("Already downloaded")
    result.resumedFrom = result.total
  elif result.total > 0 and fileExists(part) and getFileSize(part) == result.total:
    moveFile(part, dest)
    result.resumedFrom = result.total
  else:
    if fileExists(part): result.resumedFrom = getFileSize(part)
    if findExe("curl").len == 0:
      result.phase = dlFailed
      result.error = "curl is not installed"
      return
    result.process = startProcess("curl", args = ["-fL", "-sS", "--retry", "3", "-C", "-",
                                                  "-o", part, url],
                                  options = {poUsePath, poStdErrToStdOut})
    return
  result.phase = dlSidecars

proc startSidecars(d: var Download) =
  d.phase = dlSidecars
  var script = ""
  for (u, p) in d.candidates:
    if fileExists(p): continue # from an earlier download of the same image
    script.add quoteShellCommand(["curl", "-fsSL", "--max-time", "20", "-o", p, u]) & "; "
  if script.len == 0: return
  d.process = startProcess("sh", args = ["-c", script & "true"],
                           options = {poUsePath, poStdErrToStdOut})

proc finishSidecars(d: var Download) =
  for (_, p) in d.candidates:
    if fileExists(p):
      if getFileSize(p) == 0 or getFileSize(p) > 1 shl 20 or
          readFile(p).toLowerAscii.contains("<html"):
        removeFile(p) # an error page, not a checksum
      else: d.sidecars.add p.extractFilename
  info("Sidecar files: " & d.sidecars.join(", "))
  d.phase = dlDone

proc startDownload*(r: Resolved, dir = downloadDir()): Download =
  startDownload(r.url, dir, r.sidecars)

proc bytesDone*(d: Download): int64 =
  case d.phase
  of dlFile:
    try: getFileSize(d.dest & ".part") except OSError: d.resumedFrom
  of dlFailed: 0
  else: max(d.total, d.hist.bytesEncountered)

proc poll*(d: var Download): bool =
  ## Advances the download. Returns true when it changes phase.
  case d.phase
  of dlFile:
    d.hist.push(getMonoTime(), d.bytesDone - d.resumedFrom)
    if d.process.peekExitCode == -1: return false
    let code = d.process.peekExitCode
    let output = d.process.outputStream.readAll.strip
    d.process.close()
    d.process = nil
    if code != 0:
      d.phase = dlFailed
      d.error = if output.len > 0: output.splitLines[^1] else: "curl exited with code " & $code
      error("Download failed: " & d.error)
      return true
    moveFile(d.dest & ".part", d.dest)
    if d.total < 0: d.total = getFileSize(d.dest)
    d.startSidecars()
    if d.process == nil: d.finishSidecars()
    true
  of dlSidecars:
    if d.process == nil:
      d.finishSidecars()
      return true
    if d.process.peekExitCode == -1: return false
    d.process.close()
    d.process = nil
    d.finishSidecars()
    true
  else: false

proc cancel*(d: var Download) =
  ## Stops the download; the .part file is kept so it can resume later.
  if d.process != nil:
    d.process.terminate()
    discard d.process.waitForExit()
    d.process.close()
    d.process = nil
  d.phase = dlFailed
  d.error = "canceled"

proc speed*(d: Download): float = d.hist.totalAvgSpeed

proc eta*(d: Download): float =
  if d.total <= 0: Inf
  else: d.hist.estimatedTimeLeft(d.total - d.resumedFrom)

proc runBlocking*(d: var Download, progress: proc (d: Download)) =
  ## For the non-interactive mode.
  while d.phase in {dlFile, dlSidecars}:
    if not d.poll(): sleep(200)
    progress(d)
