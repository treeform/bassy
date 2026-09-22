## Reports how much faster compiled loops run than the interpreter.
## Times its own runs so it can execute on any CI machine without pulling
## in a benchmarking dependency.

import
  std/[monotimes, strformat, times],
  bassy

const
  Runs = 5

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

proc fastest(runtime: var Runtime): float =
  ## Returns the shortest of several runs, in milliseconds.
  result = Inf
  for run in 1 .. Runs:
    runtime.restart()
    let started = getMonoTime()
    discard runtime.run()
    let elapsed = (getMonoTime() - started).inNanoseconds.float / 1_000_000.0
    if elapsed < result:
      result = elapsed

proc measure(name, source: string) =
  ## Times one script on both paths and reports the ratio.
  let limits = benchLimits()
  let program = compile(source, limits)

  var plain = initRuntime(program, limits)
  var fast = initRuntime(program, limits)
  let regions = fast.compileNative()

  let plainTime = plain.fastest()
  let fastTime = fast.fastest()

  var agree = true
  for index in 0 ..< program.globals:
    if plain.globalValue(int32(index)).asInt !=
        fast.globalValue(int32(index)).asInt:
      agree = false
  let charged = plain.instructionsUsed == fast.instructionsUsed

  let ratio =
    if fastTime > 0.0 and regions > 0: &"{plainTime / fastTime:6.1f}x"
    else: "     --"
  echo &"  {name:<12} interpreted {plainTime:8.3f} ms   " &
    &"native {fastTime:8.3f} ms   {ratio}   " &
    &"loops {regions}  results {agree}  budget {charged}"
  if not agree or not charged:
    quit("the two paths disagreed")

echo &"native compilation available: {jitSupported()}"
echo &"host: {hostCPU} {hostOS}"
measure("arithmetic", ArithmeticSource)
measure("branches", BranchSource)
measure("nested", NestedSource)
