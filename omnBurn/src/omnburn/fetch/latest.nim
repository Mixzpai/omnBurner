## Finding the newest release in a directory listing or a web page, by the
## version numbers in its name.

import std/strutils
import web

proc globMatch*(s, pat: string, nums: var seq[string]): bool =
  ## `*` matches anything and `#` a version number like 26.04.1, which is
  ## added to `nums`. Longer matches are tried first.
  proc go(i, j: int, nums: var seq[string]): bool =
    if j == pat.len: return i == s.len
    case pat[j]
    of '*':
      for k in countdown(s.len, i):
        if go(k, j + 1, nums): return true
    of '#':
      var e = i
      while e < s.len and s[e] in {'0' .. '9', '.'}: inc e
      while e > i:
        if s[e - 1] in Digits and s[i] in Digits:
          nums.add s[i ..< e]
          if go(e, j + 1, nums): return true
          nums.setLen(nums.len - 1)
        dec e
    else:
      if i < s.len and s[i] == pat[j]: return go(i + 1, j + 1, nums)
    false
  nums.setLen(0)
  go(0, 0, nums)

proc versionKey(nums: seq[string]): seq[int] =
  for n in nums:
    for part in n.split('.'):
      if part.len > 0: result.add parseInt(part)

proc newer(a, b: seq[int]): bool =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return a[i] > b[i]
  a.len > b.len

const UrlChars = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_', '-', '~', '+', ':', '/', '='}

proc newest*(text, pattern: string, accept: proc (v: seq[int]): bool = nil): (string, seq[string]) =
  ## The newest name in `text` (a directory listing, a web page, JSON...)
  ## that matches `pattern`, and its version numbers. A pattern with a "/"
  ## matches whole URLs; one without matches file and directory names.
  var best: seq[int]
  var i = 0
  while i < text.len:
    if text[i] notin UrlChars:
      inc i
      continue
    var j = i
    while j < text.len and text[j] in UrlChars: inc j
    var token = text[i ..< j]
    i = j
    if '/' notin pattern: token = token.strip(leading = false, chars = {'/'}).rsplit('/', 1)[^1]
    var nums: seq[string]
    if globMatch(token, pattern, nums):
      let key = versionKey(nums)
      if (accept == nil or accept(key)) and (result[0].len == 0 or newer(key, best)):
        result = (token, nums)
        best = key

proc listed*(dir, pattern, what: string, accept: proc (v: seq[int]): bool = nil): string =
  ## The URL of the newest entry matching `pattern` in a directory listing.
  let (name, _) = newest(fetchText(dir & "/"), pattern, accept)
  if name.len == 0: raise newException(FetchError, "no " & what & " found at " & dir.split('/')[2])
  if name.isUrl: name else: dir & "/" & name

proc found*(text, pattern, what, site: string): (string, seq[string]) =
  result = newest(text, pattern)
  if result[0].len == 0: raise newException(FetchError, "no " & what & " found on " & site)
