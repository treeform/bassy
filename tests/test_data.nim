import std/strutils, bassy

proc rejects(action: proc() {.closure.}, message: string) =
  ## Requires a BASIC error with the expected diagnostic.
  var caught = false
  try:
    action()
  except BasicError as error:
    caught = true
    doAssert message in error.msg, error.msg
  doAssert caught, "expected BASIC error: " & message

echo "Testing typed DATA, continuations, and runtime lifecycle"
block:
  let program = compile("""
DATA integers AS int32 = -2147483648, _
  2147483647, +12, 0
DATA fractions AS fixed32 = _
  -0.252276, 1, 0.5
DATA mixed = 1, -0.34, 7
DIM output(0)
output(0) = output(0) + integers(2)
value = fractions(0)
""")
  var runtime = initRuntime(program)
  doAssert runtime.getArray("integers", 0) == low(int32)
  doAssert runtime.getArray("integers", 1) == high(int32)
  doAssert runtime.getArrayValue("fractions", 1).kind == FixedValue
  doAssert runtime.getArrayValue("mixed", 0).kind == IntegerValue
  doAssert runtime.getArrayValue("mixed", 1).kind == FixedValue
  discard runtime.run()
  doAssert runtime.getArray("output", 0) == 12
  runtime.restart()
  discard runtime.run()
  doAssert runtime.getArray("output", 0) == 24
  runtime.reset()
  doAssert runtime.getArray("integers", 2) == 12
  doAssert runtime.getArray("output", 0) == 0
  rejects(proc() = runtime.setArray("integers", 0, 5), "read-only")

for source in [
  "data weights = 1, 2\nweights(0) = 7",
  "data weights = 1, 2\nweights(0) = weights(0) + 7"
]:
  rejects(proc() = discard compile(source), "read-only")

for source in [
  "data weights =",
  "data weights = 1,",
  "data weights = 1 + 2",
  "data weights = value",
  "data weights = 2147483648",
  "data weights as int32 = 0.5",
  "data weights as fixed32 = 100000",
  "data weights as float32 = 1",
  "data weights$ = 1",
  "data weights = 1\ndata weights = 2",
  "if 1 then\ndata weights = 1\nend if",
  "sub foo()\ndata weights = 1\nend sub"
]:
  rejects(proc() = discard compile(source), "")

echo "Testing DATA structural and live memory bounds"
block:
  var limits = defaultLimits()
  limits.maxArrayElements = 2
  rejects(
    proc() = discard compile("dim input(0)\ndata weights = 1, 2", limits),
    "element limit"
  )
  limits = defaultLimits()
  limits.maxMemoryBytes = 16
  rejects(
    proc() = discard compile("data weights = 1, 2", limits),
    "memory limit"
  )
  limits = defaultLimits()
  limits.disableFixed = true
  rejects(
    proc() = discard compile("data weights as fixed32 = 1", limits),
    "disabled"
  )
  let program = compile("data weights = 1, 2, 3")
  var runtime = initRuntime(program)
  limits = defaultLimits()
  limits.maxMemoryBytes = runtime.memoryBytes
  discard initRuntime(program, limits)
  dec limits.maxMemoryBytes
  rejects(proc() = discard initRuntime(program, limits), "memory limit")

echo "Testing checked host array views and callback binding"
block:
  var host = initHost()
  let callback: ContextHostProc = proc(
      runtime: Runtime,
      arguments: openArray[Value]
  ): Value =
    ## Copies two entries only after reserving their work.
    let
      source = runtime.arrayView(arguments[0])
      target = runtime.arrayView(arguments[1], writable = true)
    runtime.chargeOperations(2)
    for i in 0 ..< 2:
      target[i] = source[i]
    toValue(0)
  discard host.addFunction("copy", 2, callback)
  let program = compile("""
data weights = 12, 34
dim output(1)
copy(weights, output())
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getArray("output", 1) == 34
  let view = runtime.arrayView(toValue(0))
  rejects(proc() = view[0] = 6, "read-only")
  rejects(proc() = discard view[-1], "outside")
  rejects(proc() = discard view[2], "outside")
  rejects(proc() = discard runtime.arrayView(toValue(-1)), "handle")
  rejects(proc() = discard runtime.arrayView(toValue(2)), "handle")
  rejects(
    proc() = discard runtime.arrayView(toValue(0.5'fx)),
    "int32"
  )
  var wrong = initHost()
  discard wrong.addFunction("copy", 2, proc(args: openArray[Value]): Value =
    ## Supplies a deliberately incompatible callback signature.
    toValue(0)
  )
  rejects(proc() = discard initRuntime(program, wrong), "incompatible")

echo "Testing context callbacks receive owned strings, not literal IDs"
block:
  var host = initHost()
  let callback: ContextHostProc = proc(
      runtime: Runtime,
      arguments: openArray[Value]
  ): Value =
    ## Reads the actual string passed through a runtime-aware callback.
    toValue(runtime.getString(arguments[0]).len)
  discard host.addFunction("nativeLength", 1, callback)
  let program = compile("""
direct = nativeLength("literal")
text$ = "variable"
indirect = nativeLength(text$)
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("direct") == 7
  doAssert runtime.getGlobal("indirect") == 8

echo "Testing atomic dynamic instruction and work reservation"
for instructionLimit in [true, false]:
  var limits = defaultLimits()
  if instructionLimit:
    limits.maxInstructions = 4
  else:
    limits.maxWorkUnits = 4
  let runtime = initRuntime(compile("end"), limits)
  runtime.chargeOperations(3)
  doAssert runtime.instructionsUsed == 3
  doAssert runtime.workUsed == 3
  rejects(proc() = runtime.chargeOperations(2), "limit exceeded")
  doAssert runtime.instructionsUsed == 3
  doAssert runtime.workUsed == 3
  runtime.chargeOperations(1)
  rejects(proc() = runtime.chargeOperations(-1), "limit exceeded")

echo "test_data: all checks passed"
