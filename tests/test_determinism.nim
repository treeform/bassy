import
  std/[strutils, unittest],
  bassy

const
  HashStart = 0xcbf29ce484222325'u64
  HashPrime = 0x100000001b3'u64
  ExpectedReplay = 0xd6ab48683fc7afcc'u64
  ExpectedFolding = 0x7e4c60dc7f0989e2'u64
  ReplaySource = """
dim history(7)
sub advance(delta)
  velocity = velocity * .875 + delta
  position = position + velocity / 8
  gosub mirror
  exit sub
mirror:
  mirrored = -position
  return
end sub
advance(sample(tick, drive))
observed = remember(position, mirrored)
slot = tick mod 8
history(slot) = position
select case tick mod 3
case 0
  flags = flags xor 5
case 1
  flags = flags or 2
case else
  flags = flags and 7
end select
if position > 0 and tick <> 0 then flags = flags xor 8
caption$ = "p=" + str$(position)
print tick; caption$; mirrored
"""

proc number(value: Value): string =
  ## Records the numeric kind and raw bits without floating-point output.
  case value.kind
  of IntegerValue:
    return "i:" & $value.asInt
  of FixedValue:
    return "f:" & $int32(value.asFixed)
  of ArrayValue, BlobValue:
    raise newException(BasicError, "numeric trace cannot contain buffers")
  of StringValue:
    raise newException(ValueError, "expected a numeric replay value")

proc digest(rows: seq[string]): uint64 =
  ## Hashes length-prefixed UTF-8 records without native object layout.
  result = HashStart
  for row in rows:
    let size = uint64(row.len)
    for shift in countup(0, 56, 8):
      result = (result xor ((size shr shift) and 255)) * HashPrime
    for character in row:
      result = (result xor uint64(ord(character))) * HashPrime

proc replay(resetFirst = false, interleave = false): seq[string] =
  ## Recompiles and replays state, callbacks, strings, and execution budgets.
  var
    host = initHost()
    calls: seq[string]
    output: seq[string]
    limits = defaultLimits()
  limits.maxStrings = 4096
  limits.maxStringBytes = 256 * 1024
  let
    sample: NumericHostProc = proc(args: openArray[Value]): Value =
      ## Records callback order and derives a fixed-point input from the tick.
      calls.add("sample|" & number(args[0]) & "|" & number(args[1]))
      return toValue(args[0].asInt mod 7 - 3) * 0.03125'fx + args[1]
    remember: NumericHostProc = proc(args: openArray[Value]): Value =
      ## Records a callback after the subroutine and GOSUB have completed.
      calls.add("remember|" & number(args[0]) & "|" & number(args[1]))
      return args[0] + args[1]
    logger: PrintProc = proc(event: PrintEvent) =
      ## Records semantic print fields, excluding transient string handles.
      case event.kind
      of TextPrint:
        output.add("text|" & event.text)
      of ValuePrint:
        output.add("integer|" & $event.value)
      of FixedPrint:
        output.add("fixed|" & $int32(event.fixedValue) & "|" & event.text)
      of NewlinePrint:
        output.add("newline")
  discard host.addData("tick")
  discard host.addData("drive", FixedZero)
  discard host.addFunction("sample", 2, sample, workUnits = 7)
  discard host.addFunction("remember", 2, remember, workUnits = 5)
  let program = compile(ReplaySource, host, limits)
  var runtime = initRuntime(program, host, limits)
  if resetFirst:
    runtime.setGlobal("position", -7.25'fx)
    for tick in 1 .. 8:
      runtime.restart
      runtime.setData("tick", tick)
      runtime.setData("drive", -0.25'fx)
      discard runtime.run(logger)
    runtime.reset
  runtime.setGlobal("position", 1.25'fx)
  for tick in 0 ..< 256:
    calls.setLen(0)
    output.setLen(0)
    if interleave and tick mod 17 == 0:
      var noise = initRuntime(compile("noise$ = \"other\" + str$(.125)"))
      discard noise.run
      noise.reset
    runtime.restart
    runtime.setData("tick", tick)
    runtime.setData("drive", Fixed(int32((tick * 37) mod 8193) - 4096))
    let stats = runtime.run(logger)
    result.add("tick|" & $tick)
    for name in ["position", "velocity", "mirrored", "observed", "flags"]:
      result.add(name & "|" & number(runtime.getGlobalValue(name)))
    for i in 0 ..< 8:
      result.add("history|" & $i & "|" &
        number(runtime.getArrayValue("history", int32(i))))
    result.add("caption|" & runtime.getStringGlobal("caption$"))
    result.add(calls)
    result.add(output)
    result.add("budget|" & $stats.instructions & "|" & $stats.workUnits &
      "|" & $stats.printBytes & "|" & $stats.printEvents)

proc foldedTrace(): seq[string] =
  ## Compares folded expressions with host-bound execution over raw inputs.
  for i in 0 ..< 128:
    let
      left = Fixed(int32((i * 7919) mod 262145) - 131072)
      right = Fixed(int32((i * 3571) mod 65536) + 8192)
      expression = "(left * right + left / right) / 1.25"
      source = "folded = " & expression.replace("left", "(" & $left & ")")
        .replace("right", "(" & $right & ")") &
        "\nexecuted = " & expression & "\n"
    var runtime = initRuntime(compile(source))
    runtime.setGlobal("left", left)
    runtime.setGlobal("right", right)
    discard runtime.run
    let
      folded = runtime.getGlobalValue("folded")
      executed = runtime.getGlobalValue("executed")
    doAssert folded.kind == FixedValue
    doAssert number(folded) == number(executed), source
    result.add(number(folded))

suite "BASIC determinism":
  test "semantic replay has a fixed cross-platform digest":
    let
      first = replay()
      hash = digest(first)
    doAssert hash == ExpectedReplay, "replay: " & toHex(hash)
    doAssert replay(interleave = true) == first
    doAssert replay(resetFirst = true, interleave = true) == first

  test "folded and interpreted arithmetic share a fixed digest":
    let hash = digest(foldedTrace())
    doAssert hash == ExpectedFolding, "folding: " & toHex(hash)
