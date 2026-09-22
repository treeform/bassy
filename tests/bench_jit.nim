## Compares interpreted and natively compiled execution of the same loops.

import
  std/strformat,
  benchy,
  bassy

const
  ArithmeticSource = """
i = 0
total = 0
while i < 1000000
  total = total + i
  i = i + 1
wend
"""

  BranchSource = """
i = 0
even = 0
odd = 0
while i < 1000000
  if i mod 2 = 0 then
    even = even + 1
  else
    odd = odd + 1
  end if
  i = i + 1
wend
"""

  NestedSource = """
outer = 0
hits = 0
inner = 0
while outer < 1000
  inner = 0
  while inner < 1000
    hits = hits + 1
    inner = inner + 1
  wend
  outer = outer + 1
wend
"""

proc benchLimits(): Limits =
  ## Returns limits large enough for every benchmark workload.
  result = defaultLimits()
  result.maxInstructions = 100_000_000
  result.maxWorkUnits = 100_000_000

proc measure(name, source: string) =
  ## Times one script on both paths and prints the result of each.
  let limits = benchLimits()
  let program = compile(source, limits)

  var plain = initRuntime(program, limits)
  var fast = initRuntime(program, limits)
  let regions = fast.compileNative()

  timeIt &"{name} interpreted", 5:
    plain.restart()
    discard plain.run()

  timeIt &"{name} native ({regions} loops)", 5:
    fast.restart()
    discard fast.run()

  plain.restart()
  discard plain.run()
  fast.restart()
  discard fast.run()
  var agree = true
  for index in 0 ..< program.globals:
    if plain.globalValue(int32(index)).asInt !=
        fast.globalValue(int32(index)).asInt:
      agree = false
  echo &"  results agree: {agree}, instructions charged: " &
    &"{plain.instructionsUsed} vs {fast.instructionsUsed}"

echo "native compilation available: ", jitSupported()
measure("arithmetic", ArithmeticSource)
measure("branches", BranchSource)
measure("nested", NestedSource)
