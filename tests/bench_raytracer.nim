## Runs the BASIC raytracer on both execution paths.
##
## This is the realistic end of the workload range. Almost all of its time
## goes to fixed-point arithmetic, arrays, subroutine calls and host
## functions, and there is no single hot loop to speak of. It shows what
## compiling the whole program buys on real work, and checks that a script
## this large still agrees on both paths.

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
  ##
  ## A Q16.16 number holds its value times 65536, so the root of those raw
  ## bits shifted up by another 16 is exactly the root's own raw bits. The
  ## digit-by-digit method below finds it with shifts and subtractions
  ## alone, which is both faster and more predictable than iterating.
  let value = arguments[0].asFixed
  if value <= 0'fx:
    return toValue(0'fx)
  var
    remainder = int64(int32(value)) shl 16
    root = 0'i64
    bit = 1'i64 shl 46
  while bit > remainder:
    bit = bit shr 2
  while bit != 0:
    if remainder >= root + bit:
      remainder -= root + bit
      root = (root shr 1) + bit
    else:
      root = root shr 1
    bit = bit shr 2
  toValue(Fixed(int32(root)))

proc powerOf(arguments: openArray[Value]): Value =
  ## Raises a fixed-point base to a whole exponent by repeated squaring.
  ## The reference raytracer uses roughness values in the hundreds, which
  ## a multiply loop in BASIC could not afford.
  var
    base = arguments[0].asFixed
    exponent = arguments[1].asInt
    total = 1'fx
  if exponent <= 0:
    return toValue(total)
  while exponent > 0:
    if (exponent and 1) != 0:
      total = total * base
    exponent = exponent shr 1
    if exponent == 0:
      break
    base = base * base
    if base == 0'fx:
      # The base has fallen below what Q16.16 can hold, so has the result.
      return toValue(0'fx)
  toValue(total)

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
  discard result.addFunction("sqr", 1, squareRoot, workUnits = 8)
  discard result.addFunction("powerOf", 2, powerOf, workUnits = 8)
  discard result.addFunction("floorOf", 1, floorOf, workUnits = 2)
  discard result.addFunction("clampByte", 1, clampByte, workUnits = 2)
  discard result.addFunction("plot", 3, plot, workUnits = 2)
  discard result.addData("size", toValue(0'i32))
  discard result.addData("half", toValue(0'fx))
  discard result.addData("span", toValue(0'fx))

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
  runtime.setData("span", toValue(fixed(Size) * 2'fx))
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
let compiled = fast.compileNative()

let (plainTime, plainSum) = plain.render()
let (fastTime, fastSum) = fast.render()

echo &"  interpreted  {plainTime:9.2f} ms   checksum {plainSum}"
echo &"  native       {fastTime:9.2f} ms   checksum {fastSum}   " &
  &"compiled offsets {compiled}"
if compiled > 0 and fastTime > 0.0:
  echo &"  ratio        {plainTime / fastTime:9.2f}x"
echo &"  instructions charged: {plain.instructionsUsed} vs " &
  &"{fast.instructionsUsed}"

# Fixed point is the reason this VM has no floats. The same scene must
# therefore render to the same bytes on every architecture, so the
# checksum is pinned rather than merely compared between the two paths.
const ExpectedChecksum = 1356659'i32
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
