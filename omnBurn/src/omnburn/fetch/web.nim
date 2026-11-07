## Talking to web servers through curl: fetching pages and following
## redirects. Shared by the rest of `fetch`.

import std/[json, os, osproc, strutils]

type
  FetchError* = object of IOError

proc isUrl*(s: string): bool = s.startsWith("https://") or s.startsWith("http://")

proc curl*(args: openArray[string]): (string, int) =
  if findExe("curl").len == 0: raise newException(FetchError, "curl is not installed")
  let cmd = @["curl", "-fsSL", "--max-time", "20"] & @args
  try: execCmdEx(quoteShellCommand(cmd), options = {poUsePath})
  except OSError as e: raise newException(FetchError, e.msg)

proc fetchText*(url: string): string =
  let (body, code) = curl([url])
  if code != 0: raise newException(FetchError, "couldn't reach " & url.split('/')[2])
  body

proc finalUrl*(url: string): string =
  ## Where `url` redirects to, e.g. from a "latest" alias to the versioned file.
  let (u, code) = curl(["-I", "-o", "/dev/null", "-w", "%{url_effective}", url])
  if code != 0 or not u.strip.isUrl: raise newException(FetchError, "couldn't reach " & url.split('/')[2])
  u.strip

proc fetchJson*(url: string): JsonNode =
  try: parseJson(fetchText(url))
  except JsonParsingError: raise newException(FetchError, "unexpected reply from " & url.split('/')[2])

proc dirOf*(url: string): string = url.rsplit('/', 1)[0]
