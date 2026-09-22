## Runs the BASIC raytracer on both execution paths.
##
## This is the realistic end of the workload range. Almost all of its time
## goes to fixed-point arithmetic, arrays, and subroutine calls, none of
## which the native compiler models, so it compiles no loops at all. It is
## here to show where the speedup does not yet reach, and to check that a
## script this large still agrees on both paths.

import
  std/[monotimes, strformat, times],
  bassy

const
  Source = staticRead("raytracer.bas")
  Size = 48
  Runs = 3

var pixels: seq[byte]

proc squareRoot(arguments: openArray[Value]): Value =
  ## Returns the fixed-point square root of a non-negative number.
  let value = arguments[0].asFixed
  if value <= 0'fx:
    return toValue(0'fx)
  # Newton's method, which settles well inside Q16.16 in a few rounds.
  var estimate = value
  if estimate < 1'fx:
    estimate = 1'fx
  for round in 1 .. 12:
    estimate = (estimate + value / estimate) / 2'fx
  toValue(estimate)

proc floorOf(arguments: openArray[Value]): Value =
  ## Returns the largest whole number not greater than the argument.
  ## Fixxy's own conversions are used because a plain int32 conversion
  ## would read the raw Q16.16 bits rather than the whole part.
  toValue(arguments[0].asFixed.floor.toInt)

proc clampByte(arguments: openArray[Value]): Value =
  ## Converts a colour channel to the usual zero to 255 range.
  let value = arguments[0].asFixed
  if value <= 0'fx:
    return toValue(0'i32)
  if value >= 1'fx:
    return toValue(255'i32)
  toValue((value * 255'fx).toInt)

proc plot(arguments: openArray[Value]): Value =
  ## Collects one rendered pixel so the image can be written out.
  for index in 0 .. 2:
    pixels.add(byte(arguments[index].asInt and 0xFF))
  toValue(0'i32)

proc buildHost(): Host =
  ## Supplies the numeric helpers BASIC does not provide itself.
  result = initHost()
  discard result.addFunction("sqr", 1, squareRoot, workUnits = 20)
  discard result.addFunction("floorOf", 1, floorOf, workUnits = 2)
  discard result.addFunction("clampByte", 1, clampByte, workUnits = 2)
  discard result.addFunction("plot", 3, plot, workUnits = 2)
  discard result.addData("size", toValue(0'i32))
  discard result.addData("half", toValue(0'fx))

proc traceLimits(): Limits =
  ## Returns limits large enough to finish the image.
  result = defaultLimits()
  result.maxInstructions = 2_000_000_000
  result.maxWorkUnits = 2_000_000_000
  result.maxCallDepth = 64

proc renderOnce(runtime: var Runtime): (float, int32) =
  ## Renders the image once and returns the elapsed milliseconds.
  runtime.restart()
  runtime.setData("size", toValue(Size))
  runtime.setData("half", toValue(fixed(Size) / 2'fx))
  pixels.setLen(0)
  let started = getMonoTime()
  discard runtime.run()
  let elapsed = (getMonoTime() - started).inNanoseconds.float / 1_000_000.0
  (elapsed, runtime.getGlobal("checksum"))

proc render(runtime: var Runtime): (float, int32) =
  ## Returns the fastest of several renders and the checksum.
  result[0] = Inf
  for attempt in 1 .. Runs:
    let (elapsed, checksum) = runtime.renderOnce()
    if elapsed < result[0]:
      result[0] = elapsed
    result[1] = checksum

var host = buildHost()
let limits = traceLimits()
let program = compile(Source, host, limits)

echo &"native compilation available: {jitSupported()}"
echo &"host: {hostCPU} {hostOS}"
echo &"image: {Size} by {Size}, bytecode {program.instructions} instructions"

var plain = initRuntime(program, host, limits)
var fast = initRuntime(program, host, limits)
let regions = fast.compileNative()

let (plainTime, plainSum) = plain.render()
let (fastTime, fastSum) = fast.render()

echo &"  interpreted  {plainTime:9.2f} ms   checksum {plainSum}"
echo &"  native       {fastTime:9.2f} ms   checksum {fastSum}   " &
  &"compiled loops {regions}"
if regions > 0 and fastTime > 0.0:
  echo &"  ratio        {plainTime / fastTime:9.2f}x"
echo &"  instructions charged: {plain.instructionsUsed} vs " &
  &"{fast.instructionsUsed}"

# Fixed point is the reason this VM has no floats. The same scene must
# therefore render to the same bytes on every architecture, so the
# checksum is pinned rather than merely compared between the two paths.
const ExpectedChecksum = 1488834'i32
if plainSum != ExpectedChecksum:
  quit(&"expected checksum {ExpectedChecksum} but rendered {plainSum}")

if plainSum != fastSum:
  quit("the two paths disagreed on the image")
if plain.instructionsUsed != fast.instructionsUsed:
  quit("the two paths disagreed on the budget")

if pixels.len == Size * Size * 3:
  var text = &"P6\n{Size} {Size}\n255\n"
  for value in pixels:
    text.add(char(value))
  writeFile("tests/raytracer.ppm", text)
  echo "  wrote tests/raytracer.ppm"

echo "raytracer agrees on both paths"
