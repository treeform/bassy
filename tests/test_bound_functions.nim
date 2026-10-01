import bassy

proc programFor(output: ref seq[int]): Program =
  var host = initHost()
  discard host.addFunction("EMIT", 1,
    proc(runtime: Runtime, arguments: openArray[Value]): Value =
      output[].add int(arguments[0].asInt)
      Value(0),
    bindAtCompile = true
  )
  compile("EMIT(42)", host)

var first, second: ref seq[int]
new(first)
new(second)
let a = programFor(first)
let b = programFor(second)
# Runtime hosts need not repeat the bound function. A same-named runtime
# callback cannot redirect the trusted binding captured by compilation.
var host = initHost()
discard host.addFunction("EMIT", 1,
  proc(runtime: Runtime, arguments: openArray[Value]): Value =
    doAssert false, "runtime host replaced a program binding"
    Value(0)
)
var ra = initRuntime(a, host)
var rb = initRuntime(b)
discard ra.run
discard rb.run
doAssert first[] == @[42]
doAssert second[] == @[42]
var resettable = ra
resettable.reset
discard resettable.run
doAssert first[] == @[42, 42]
doAssert second[] == @[42]
echo "Program-bound callbacks retain separate closures and survive reset"
