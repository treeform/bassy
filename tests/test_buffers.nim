import bassy

proc fails(action: proc() {.closure.}): bool =
  ## Recognizes controlled boundary errors without swallowing defects.
  try:
    action()
  except BasicError:
    return true

proc results(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Returns values from a static or dynamic input array.
  let view = runtime.arrayView(arguments[0])
  var values: seq[Value]
  for i in 0 ..< view.len:
    values.add view[i]
  runtime.putArray(values)

proc advance(runtime: Runtime, arguments: openArray[Value]): Value =
  ## Commits state after constructing the returned numeric array.
  let next = runtime.getBlob(arguments[0]) & "x"
  runtime.checkNativeMemory(512)
  result = runtime.putArray([toValue(next.len), toValue(1.5'fx)])
  runtime.putBlob(arguments[0], next, "test-model")

proc makeHost(): Host =
  ## Registers independent native callbacks for buffer behavior tests.
  result = initHost()
  result.addBufferFunctions()
  discard result.addFunction("results", 1, results, 1)
  discard result.addFunction("advance", 1, advance, 1)

echo "Testing returned arrays and explicit mutable blobs"
block:
  let
    host = makeHost()
    program = compile("""
dim data(1)
if initialized = 0 then
  state = blobCreate()
  alias = state
  initialized = 1
end if
data(0) = 3.25
data(1) = 4
res = results(data)
copy = res
res(0) = res(0) + 1
first = copy(0)
res = advance(alias)
steps = res(0)
second = res(1)
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobalValue("first").asFixed == 4.25'fx
  doAssert runtime.getGlobalValue("second").asFixed == 1.5'fx
  doAssert runtime.getGlobal("steps") == 1
  let state = runtime.getGlobalValue("state")
  doAssert runtime.getBlob(state) == "x"
  doAssert runtime.blobBinding(state) == "test-model"
  for i in 0 ..< 1000:
    runtime.restart()
    discard runtime.run()
  doAssert runtime.getGlobal("steps") == 1001
  doAssert runtime.nativeMemoryBytes < 4096
  runtime.reset()
  doAssert fails(proc() = discard runtime.getBlob(state))
  discard runtime.run()
  doAssert runtime.getGlobal("steps") == 1

block:
  let
    host = makeHost()
    program = compile("""
state = blobCreate()
alias = state
res = advance(state)
blobClear(alias)
res = advance(state)
steps = res(0)
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("steps") == 1

block:
  let
    host = makeHost()
    program = compile("state = blobCreate()\n", host)
  var
    runtime = initRuntime(program, host)
    other = initRuntime(program, host)
  discard runtime.run()
  discard other.run()
  let state = runtime.getGlobalValue("state")
  doAssert fails(proc() = discard other.getBlob(state))
  doAssert fails(proc() = other.setGlobal("state", state))
  doAssert fails(proc() = discard runtime.getBlob(toValue(0)))
  runtime.reset()
  discard runtime.run()
  doAssert fails(proc() = discard runtime.getBlob(state))

block:
  let host = makeHost()
  for source in [
    "dim a(0)\nr = results(a)\nx = r(-1)\n",
    "dim a(0)\nr = results(a)\nr(1) = 2\n",
    "dim a(0)\nr = 0\nx = r(0)\n",
    "b = blobCreate()\nx = b(0)\n",
    "b = blobCreate()\nx = b + 1\n"
  ]:
    var runtime = initRuntime(compile(source, host), host)
    doAssert fails(proc() = discard runtime.run())

block:
  let host = makeHost()
  var limits = defaultLimits()
  limits.maxNativeMemoryBytes = 1024
  var runtime = initRuntime(compile("state = blobCreate()\n", host), host, limits)
  discard runtime.run()
  let state = runtime.getGlobalValue("state")
  runtime.putBlob(state, "old", "binding")
  let before = runtime.nativeMemoryBytes
  doAssert fails(proc() = runtime.putBlob(state, newString(1024), "new"))
  doAssert runtime.getBlob(state) == "old"
  doAssert runtime.blobBinding(state) == "binding"
  doAssert runtime.nativeMemoryBytes == before
  runtime.reserveNativeMemory(200)
  doAssert runtime.nativeMemoryBytes == before + 200
  doAssert fails(proc() = runtime.reserveNativeMemory(1024))
  runtime.releaseNativeMemory(200)
  doAssert runtime.nativeMemoryBytes == before
  doAssert fails(proc() = runtime.releaseNativeMemory(1))

echo "Testing buffer churn within a single decision"
block:
  let host = makeHost()
  var limits = defaultLimits()
  limits.maxNativeMemoryBytes = 1024
  var runtime = initRuntime(compile("""
dim data(1)
for i = 0 to 9999
  res = results(data)
  value = res(0)
next i
""", host), host, limits)
  discard runtime.run()
  doAssert runtime.nativeMemoryBytes < 1024
