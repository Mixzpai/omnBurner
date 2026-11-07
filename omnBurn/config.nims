# Small, fast release builds by default; pass -d:debug for a debug build.
when not defined(debug):
  switch("define", "release")
  switch("opt", "size")
  switch("passL", "-s")
switch("threads", "on")
