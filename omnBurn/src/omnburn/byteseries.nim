## A time series of cumulative byte counts, used for speeds, graphs and ETAs.

import std/[math, monotimes, strformat, times]

type
  ByteSeries* = object
    raw*: seq[(float, int64)] ## (seconds since start, cumulative bytes)
    start*: MonoTime

proc formatBytes*(bytes: int64): string =
  ## Human-readable size with decimal units ("15.5 GB"), like caligula.
  const units = "KMGTPE"
  if bytes < 1000: return $max(bytes, 0) & " B"
  let size = float(bytes)
  var exp = int(ln(size) / ln(1000.0))
  if exp == 0: exp = 1
  exp = min(exp, units.len)
  &"{size / pow(1000.0, float(exp)):.1f} {units[exp - 1]}B"

proc formatSpeed*(bytesPerSec: float): string =
  let b = if bytesPerSec.classify in {fcNan, fcInf, fcNegInf}: 0'i64
          else: int64(bytesPerSec)
  formatBytes(b) & "/s"

proc secondsBetween*(a, b: MonoTime): float = float((b - a).inNanoseconds) / 1e9

proc initByteSeries*(start: MonoTime): ByteSeries =
  ByteSeries(start: start, raw: @[(0.0, 0'i64)])

proc push*(s: var ByteSeries, time: MonoTime, bytes: int64) =
  s.raw.add((max(secondsBetween(s.start, time), 0.0), bytes))

proc lastDatapoint*(s: ByteSeries): (float, int64) =
  if s.raw.len == 0: (0.0, 0'i64) else: s.raw[^1]

proc bytesEncountered*(s: ByteSeries): int64 = s.lastDatapoint[1]

proc totalAvgSpeed*(s: ByteSeries): float =
  ## Bytes per second over the whole series.
  let speed = float(s.bytesEncountered) / s.lastDatapoint[0]
  if speed.isNaN: 0.0 else: speed

proc estimatedTimeLeft*(s: ByteSeries, totalBytes: int64): float =
  ## Seconds left at the average speed so far; may be infinite. Bytes
  ## encountered can exceed the total because of block padding.
  float(max(totalBytes - s.bytesEncountered, 0)) / s.totalAvgSpeed

proc formatEta*(secsLeft: float, at: DateTime = now()): string =
  if secsLeft.classify in {fcNan, fcInf, fcNegInf}: return "[unknown]"
  let total = int64(round(secsLeft))
  let completion = at + initDuration(seconds = total)
  # Show the whole date only if completion is at least a day away.
  let fmtStr = if total >= 86_400: "yyyy-MM-dd HH:mm:ss" else: "HH:mm:ss"
  &"{total div 3600:02}:{(total div 60) mod 60:02}:{total mod 60:02} " &
    &"(complete at {completion.format(fmtStr)})"

proc findIdxBelow*(s: ByteSeries, t: float): int =
  ## Index of the sample right before the requested time.
  var lo = 0
  if t <= s.raw[lo][0]: return lo
  var hi = s.raw.high
  if s.raw[hi][0] <= t: return hi
  while true:
    if lo >= hi - 1: return lo
    let mid = (lo + hi) div 2
    if t < s.raw[mid][0]: hi = mid else: lo = mid

proc interp*(s: ByteSeries, t: float): float =
  ## Interpolated number of bytes encountered at time `t`.
  if t < 0.0: return float(s.raw[0][1])
  let (last, lastVal) = s.lastDatapoint
  if t >= last: return float(lastVal)
  let i0 = s.findIdxBelow(t)
  let (x0, y0) = s.raw[i0]
  let (x1, y1) = s.raw[i0 + 1]
  float(y1 - y0) * (t - x0) / (x1 - x0) + float(y0)

proc speed*(s: ByteSeries, t, window: float): float =
  (s.interp(t) - s.interp(t - window)) / window

proc recentSpeed*(s: ByteSeries, window = 10.0): float =
  ## Bytes per second over the last `window` seconds, or since the start.
  let last = s.lastDatapoint[0]
  let w = min(window, last)
  if w <= 0: 0.0 else: s.speed(last, w)
