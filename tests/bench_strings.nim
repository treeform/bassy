## Runs the BASIC text workload on both execution paths.
##
## The string counterpart of the raytracer: splitting, slicing, reversing,
## encoding, comparing and scoring words, where nearly every instruction
## touches a string. It shows what compiling buys when most of the work is
## string storage rather than arithmetic, and checks that a script this
## string-heavy still agrees on both paths.

import
  std/[monotimes, strformat, times],
  bassy

const
  Source = staticRead("strings.bas")
  Rounds = 200
  Runs = 5

proc textLimits(): Limits =
  ## Returns limits large enough for every string the workload builds.
  result = defaultLimits()
  result.maxInstructions = 2_000_000_000
  result.maxWorkUnits = 2_000_000_000
  result.maxStrings = 200_000
  result.maxStringBytes = 4 * 1024 * 1024
  result.maxMemoryBytes = 256 * 1024 * 1024

proc processOnce(runtime: var Runtime): (float, int32) =
  ## Runs the workload once from a fresh state, timing it.
  runtime.reset()
  runtime.setGlobal("rounds", toValue(Rounds.int32))
  let started = getMonoTime()
  discard runtime.run()
  let elapsed = (getMonoTime() - started).inNanoseconds.float / 1_000_000.0
  (elapsed, runtime.getGlobal("checksum"))

proc process(runtime: var Runtime): (float, int32) =
  ## Returns the fastest of several runs and the checksum.
  result[0] = Inf
  for attempt in 1 .. Runs:
    let (elapsed, checksum) = runtime.processOnce()
    if elapsed < result[0]:
      result[0] = elapsed
    result[1] = checksum

let limits = textLimits()
let program = compile(Source, limits)

echo &"native compilation available: {jitSupported()}"
echo &"host: {hostCPU} {hostOS}"
echo &"rounds: {Rounds}, bytecode {program.instructions} instructions"

var plain = initRuntime(program, limits)
var fast = initRuntime(program, limits)
let compiled = fast.compileNative()

let (plainTime, plainSum) = plain.process()
let (fastTime, fastSum) = fast.process()

echo &"  interpreted  {plainTime:9.2f} ms   checksum {plainSum}"
echo &"  native       {fastTime:9.2f} ms   checksum {fastSum}   " &
  &"compiled offsets {compiled}"
if compiled > 0 and fastTime > 0.0:
  echo &"  ratio        {plainTime / fastTime:9.2f}x"
echo &"  instructions charged: {plain.instructionsUsed} vs " &
  &"{fast.instructionsUsed}"
echo &"  work charged: {plain.workUsed} vs {fast.workUsed}"
echo &"  strings: {plain.stringCount} vs {fast.stringCount}, " &
  &"bytes {plain.stringBytes} vs {fast.stringBytes}"

# The checksum is pinned, so every architecture must build the very same
# strings, not merely agree with the interpreter running beside it.
const ExpectedChecksum = 350997'i32
if plainSum != ExpectedChecksum:
  quit(&"expected checksum {ExpectedChecksum} but computed {plainSum}")

if plainSum != fastSum:
  quit("the two paths disagreed on the checksum")
if plain.instructionsUsed != fast.instructionsUsed:
  quit("the two paths disagreed on the instruction budget")
if plain.workUsed != fast.workUsed:
  quit("the two paths disagreed on the work budget")
if plain.stringCount != fast.stringCount or
    plain.stringBytes != fast.stringBytes:
  quit("the two paths disagreed on the strings they built")

echo "the text workload agrees on both paths"
