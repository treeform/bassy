import
  std/strutils,
  bassy

proc refuses(action: proc() {.closure.}, text: string): bool =
  ## Checks lazy storage failures remain controlled BASIC errors.
  try:
    action()
  except BasicError as error:
    result = text in error.msg

echo "Testing lazy arrays agree in the interpreter and native compiler"
for native in [false, true]:
  let program = compile("""
TYPE Sample
  hp AS INTEGER
  x AS FIXED
END TYPE
DIM samples(3) AS Sample
DIM numbers(3)
if phase = 0 then end
i = 1
delta = 3
samples(i).hp = samples(i).hp + delta
samples(i).x = samples(i).x + 0.5
total = 0
total = total + numbers(i)
numbers(i) = numbers(i) + delta
answer = samples(i).hp + numbers(i)
position = samples(i).x
""")
  var
    runtime = initRuntime(program)
    loads = 0
    epoch = 10
  for name in ["samples.hp", "samples.x", "numbers"]:
    runtime.setArrayLoader(name, proc(view: ArrayView) =
      ## Populates the requested column through its checked typed view.
      inc loads
      for i in 0 ..< view.len:
        view[i] = toValue(epoch + i)
    )
  if native and jitSupported():
    doAssert runtime.compileNative() == program.instructions
  discard runtime.run
  doAssert loads == 0
  runtime.restart()
  runtime.setGlobal("phase", 1)
  let first = runtime.run
  doAssert loads == 3
  doAssert runtime.getGlobal("answer") == 28
  doAssert runtime.getGlobalValue("position").asFixed == 11.5'fx
  doAssert runtime.getArray("numbers", 1) == 14
  doAssert loads == 3
  runtime.restart()
  discard runtime.run
  doAssert loads == 3
  doAssert runtime.getGlobal("answer") == 34
  epoch = 20
  runtime.invalidateArrays()
  runtime.restart()
  let second = runtime.run
  doAssert loads == 6
  doAssert runtime.getGlobal("answer") == 48
  doAssert runtime.getGlobalValue("position").asFixed == 21.5'fx
  doAssert first.instructions == second.instructions
  doAssert first.workUnits == second.workUnits
  runtime.arrayView("numbers").invalidate()
  doAssert runtime.getArray("numbers", 1) == 21
  doAssert loads == 7

  runtime.reset()
  runtime.setGlobal("phase", 1)
  discard runtime.run
  doAssert loads == 10
  doAssert runtime.getGlobal("answer") == 48
  doAssert refuses(proc() = discard runtime.getArray("numbers", -1),
    "outside")
  doAssert refuses(proc() = discard runtime.getArray("numbers", 4),
    "outside")
  doAssert loads == 10

for native in [false, true]:
  echo "Testing writes load untouched cells and loader errors remain retryable"
  var
    runtime = initRuntime(compile("dim a(1)\na(0) = 5\nanswer = a(1)"))
    loads = 0
    fail = true
  runtime.setArrayLoader("a", proc(view: ArrayView) =
    ## Simulates a host refresh that initially fails.
    inc loads
    view[1] = toValue(8)
    if fail:
      raise newException(BasicError, "temporary load failure")
  )
  if native and jitSupported():
    doAssert runtime.compileNative() > 0
  doAssert refuses(proc() = discard runtime.run, "temporary load failure")
  doAssert loads == 1
  fail = false
  runtime.restart()
  discard runtime.run
  doAssert loads == 2
  doAssert runtime.getArray("a", 0) == 5
  doAssert runtime.getGlobal("answer") == 8
  runtime.setArrayLoader("a", nil)
  runtime.invalidateArrays()
  doAssert runtime.getArray("a", 0) == 5
  doAssert loads == 2

block:
  echo "Testing a binding change retires an active compiled program"
  var
    runtime: Runtime
    host = initHost()
  discard host.addFunction("bind", 0, proc(args: openArray[int32]): int32 =
    ## Changes a binding from an ordinary mutating host command.
    runtime.setArrayLoader("a", proc(view: ArrayView) =
      ## Publishes a value after compiled code has already started.
      view[0] = toValue(42)
    )
    1
  )
  runtime = initRuntime(compile("dim a(0)\nbind()\nanswer = a(0)", host), host)
  if jitSupported():
    doAssert runtime.compileNative() > 0
  discard runtime.run
  doAssert runtime.getGlobal("answer") == 42

echo "Testing invalid indices fail before native or interpreted loading"
for native in [false, true]:
  for index in [-1, 4]:
    var
      runtime = initRuntime(compile("dim a(3)\nanswer = a(index)"))
      loads = 0
    runtime.setArrayLoader("a", proc(view: ArrayView) =
      ## Counts unexpected access to an invalid array index.
      inc loads
    )
    runtime.setGlobal("index", index)
    if native and jitSupported():
      doAssert runtime.compileNative() > 0
    doAssert refuses(proc() = discard runtime.run, "outside")
    doAssert loads == 0

echo "Testing loaders reject read-only arrays and disabled fixed values"
block:
  var runtime = initRuntime(compile("dim text$(0)\ndata constants = 1, 2"))
  let loader: ArrayLoader = proc(view: ArrayView) =
    ## Writes one numeric sample when a mutable numeric column is loaded.
    view[0] = toValue(1)
  doAssert refuses(proc() = runtime.setArrayLoader("text$", loader),
    "numeric")
  doAssert refuses(proc() = runtime.setArrayLoader("constants", loader),
    "read-only")

for native in [false, true]:
  var limits = defaultLimits()
  limits.disableFixed = true
  var runtime = initRuntime(compile("dim a(0)\nanswer = a(0)", limits),
    limits)
  runtime.setArrayLoader("a", proc(view: ArrayView) =
    ## Attempts to publish a disallowed fixed-point observation.
    view[0] = toValue(1.5'fx)
  )
  if native and jitSupported():
    doAssert runtime.compileNative() > 0
  doAssert refuses(proc() = discard runtime.run, "disabled")

echo "Lazy array checks passed"
