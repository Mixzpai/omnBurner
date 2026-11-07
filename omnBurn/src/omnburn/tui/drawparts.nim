## Small pieces several screens share: the status line, the main box, and
## the checksum and signature lines.

import std/options
import ../[hash, herder, sig]
import screen, widgets
import state

proc drawStatus*(a: App, b: var Buffer, y: int) =
  if a.status.len > 0:
    b.text(2, y, a.status.ellipsize(b.w - 4), if a.statusErr: a.bad else: a.warnSt)

proc mainBox*(b: Buffer, w, h: int, y = 2): Rect =
  let bw = min(b.w - 2, w)
  rect((b.w - bw) div 2, y, bw, min(h, b.h - y - 2))

proc checksumLine*(a: App): seq[Seg] =
  if a.expected.isNone:
    if a.info.windows:
      return @[("none found", a.warnSt), (" · press m to check it against Microsoft's list", a.dim)]
    return @[("none found", a.warnSt), (" · press c to enter one", a.dim)]
  let e = a.expected.get
  let src = e.alg.displayName & " from " & e.source
  if a.precheck.isSome:
    if a.precheck.get: return @[("✓ matches ", a.good), (src, a.dim)]
    return @[("✗ DOES NOT MATCH ", a.bad), (src, a.dim)]
  @[(src, a.fg), (" · checked " & (if a.hashFirst or a.winMode: "before burning" else: "while burning"), a.dim)]

proc sigLine*(a: App): seq[Seg] =
  let st = case a.sig.status
    of ssGood: a.good
    of ssBad, ssRevoked: a.bad
    of ssNoKey, ssExpired, ssError: a.warnSt
    else: a.dim
  result = @[((if a.sig.status == ssGood: "✓ " else: "") & a.sig.describe, st)]
  if a.sig.status == ssNoKey: result.add ("  (k fetches the key)", a.dim)

proc onOff*(v: bool): string = (if v: "on" else: "off")
