## Byte series: interpolation, speeds, ETAs and byte formatting.

import std/[monotimes, times, unittest]
import ../src/omnburn/byteseries

suite "byteseries":
  proc example2s(): ByteSeries =
    let t0 = getMonoTime()
    result = initByteSeries(t0)
    for (s, b) in [(0.1, 10'i64), (0.2, 20'i64), (0.5, 30'i64), (1.0, 40'i64), (1.5, 80'i64),
                   (2.0, 100'i64)]:
      result.push(t0 + initDuration(milliseconds = int(s * 1000)), b)

  test "findIdxBelow":
    let s = example2s()
    for (t, i) in [(0.0, 0), (-10.0, 0), (0.4, 2), (0.5, 3), (2.0, 6), (3.0, 6)]:
      check s.findIdxBelow(t) == i
  test "interp":
    let s = example2s()
    for (t, v) in [(0.0, 0.0), (-10.0, 0.0), (0.75, 35.0), (0.5, 30.0), (2.0, 100.0), (3.0, 100.0)]:
      check abs(s.interp(t) - v) < 1e-9
  test "the speed just now":
    let s = example2s()
    check abs(s.recentSpeed(1.0) - 60.0) < 1e-9 # 40 -> 100 bytes in the last second
    check abs(s.recentSpeed() - 50.0) < 1e-9    # under 10 s so far: since the start
    check initByteSeries(getMonoTime()).recentSpeed == 0.0
  test "ETA display":
    let at = dateTime(2025, mOct, 21, 10, 0, 5, zone = local())
    for (secs, expected) in [(Inf, "[unknown]"),
                             (39_562.0, "10:59:22 (complete at 20:59:27)"),
                             (86_400.0, "24:00:00 (complete at 2025-10-22 10:00:05)"),
                             (133_800.0, "37:10:00 (complete at 2025-10-22 23:10:05)"),
                             (60.5, "00:01:01 (complete at 10:01:06)"),
                             (59.4, "00:00:59 (complete at 10:01:04)")]:
      check formatEta(secs, at) == expected
  test "formatBytes":
    check formatBytes(999) == "999 B"
    check formatBytes(1000) == "1.0 KB"
    check formatBytes(15_500_000_000) == "15.5 GB"
