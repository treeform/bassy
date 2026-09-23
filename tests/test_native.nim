## Checks that a whole program compiled to machine code is
## indistinguishable from the same program interpreted.
##
## Generated programs mix whole numbers, fixed point and strings, arrays,
## subs, GOSUB, host functions, printing, and every way a script can fail:
## bad indices, zero divisors, wrong kinds, exhausted budgets, deep calls,
## and host code that raises. Each runs down both paths and everything a
## host could observe afterwards is compared: every global and array cell,
## every print event, both budgets, the offset it stopped at, the string
## storage, and the exact failure, including its exception type.

import
  std/[random, strformat, strutils, tables],
  bassy

const
  Scalars = ["a", "b", "c", "d"]
  Decimals = ["x", "y"]
  Texts = ["s$", "t$"]
  Cells = 6
  TextCells = 3

var
  failures = 0
  compiled = 0
  handed = 0'i64
  executed = 0'i64

proc render(runtime: Runtime, value: Value): string =
  ## Renders one value with its kind, and a string by its content.
  case value.kind
  of IntegerValue: "i" & $value.asInt
  of FixedValue: "f" & $int32(value.asFixed)
  of StringValue:
    try:
      "s" & runtime.getString(value).escape
    except CatchableError:
      "s<stale>"

proc makeHost(): Host =
  ## Builds host data and functions of every kind a script can call.
  result = initHost()
  discard result.addData("seed", toValue(7'i32))
  discard result.addData("scale", toValue(fixed(3'i32) / fixed(2'i32)))
  discard result.addData("mail$", "hello")
  discard result.addFunction("twice", 1,
    proc(arguments: openArray[int32]): int32 =
      if arguments[0] == 13:
        raise newException(ValueError, "host refuses thirteen")
      arguments[0] *% 2
  )
  discard result.addFunction("halve", 1,
    proc(arguments: openArray[Value]): Value =
      if arguments[0].kind == FixedValue:
        toValue(arguments[0].asFixed / fixed(2'i32))
      else:
        toValue(arguments[0].asInt div 2)
  )
  discard result.addFunction("pick", 2,
    proc(arguments: openArray[int32]): int32 =
      if arguments[0] > arguments[1]: arguments[0] else: arguments[1]
  , 3)

proc observe(source: string, native: bool, limits: Limits,
    runs: int): string =
  ## Runs a program and writes down everything a host could observe.
  var transcript: seq[string]
  let host = makeHost()
  let program = compile(source, host, limits)
  var runtime = initRuntime(program, host, limits)
  if native:
    let count = runtime.compileNative()
    if jitSupported():
      doAssert count == program.instructions,
        "the whole program should compile"
      inc compiled
  for run in 0 ..< runs:
    # The second run carries on from wherever the first stopped, which
    # after a failure is part way through a block; the third restarts.
    if run == 2:
      runtime.restart
    var events: seq[string]
    let print = proc(event: PrintEvent) =
      events.add(&"{event.kind}:{event.text.escape}:{event.value}:" &
        &"{int32(event.fixedValue)}")
    try:
      let stats = runtime.run(print)
      transcript.add(&"stats {stats.instructions} {stats.workUnits} " &
        &"{stats.printBytes} {stats.printEvents}")
    except CatchableError as error:
      transcript.add(&"raised {error.name}: {error.msg}")
    transcript.add("printed " & events.join(" "))
    if native:
      executed += runtime.instructionsUsed
    let (instructions, work) = runtime.remainingBudget
    transcript.add(&"budget {instructions} {work} at {runtime.offset}")
    transcript.add(&"strings {runtime.stringCount} {runtime.stringBytes}")
    for index in 0 ..< program.globals:
      transcript.add(&"global {index} " &
        runtime.render(runtime.globalValue(int32(index))))
    for index in 0 ..< Cells:
      transcript.add(&"cell {index} " &
        runtime.render(runtime.getArrayValue("cells", int32(index))))
    for index in 0 ..< TextCells:
      transcript.add(&"text {index} " &
        runtime.render(runtime.getArrayValue("words$", int32(index))))
  if native:
    handed += runtime.handedBack
  transcript.join("\n")

proc agree(name, source: string, limits = defaultLimits(), runs = 3) =
  ## Requires both paths to leave exactly the same trail.
  let plain = observe(source, false, limits, runs)
  let fast = observe(source, true, limits, runs)
  if plain != fast:
    inc failures
    echo &"FAIL  {name}"
    echo source
    let plainLines = plain.splitLines
    let fastLines = fast.splitLines
    for index in 0 ..< max(plainLines.len, fastLines.len):
      let left = if index < plainLines.len: plainLines[index] else: ""
      let right = if index < fastLines.len: fastLines[index] else: ""
      if left != right:
        echo &"  interpreted  {left}"
        echo &"  native       {right}"
  else:
    echo &"  ok  {name}"

## Programs worth naming

const Preamble = """
dim cells(5)
dim words$(2)
"""

agree("arithmetic of every kind", Preamble & """
a = 7
b = -3
x = 1.5
y = -0.25
c = a * b + a \ b - a mod b
d = x * y + x / y - x
e = -x
f = a / b
g = (a < b) + (x >= y) * 2 + (a = 7)
h = not a and 12 or 3 xor 5
i = a eqv b
j = a imp b
k = x + 2
l = 2 * y
""")

agree("strings through every function", Preamble & """
s$ = "Hello, World"
t$ = s$ + " again"
a = len(t$)
words$(0) = left$(s$, 5)
words$(1) = right$(s$, 5)
words$(2) = mid$(s$, 3, 4)
s$ = ucase$(s$) + lcase$(t$) + trim$("  x  ") + ltrim$(" y") + rtrim$("z ")
b = asc("A")
t$ = chr$(66) + space$(2) + string$(3, "q") + str$(42) + str$(-1.5)
c = instr(s$, "WORLD")
d = s$ < t$
e = s$ = s$
print s$; t$
print a, b, c
""")

agree("subs, recursion, and GOSUB", Preamble & """
sub fact(n)
  if n <= 1 then
    a = a + 1
    exit sub
  end if
  b = b + n
  fact(n - 1)
end sub
sub shared(n)
  gosub bump
  gosub bump
  c = c + n
  exit sub
bump:
  n = n + 1
  return
end sub
fact(10)
shared(5)
gosub outer
d = 99
end
outer:
  cells(1) = cells(1) + 1
  return
""")

agree("an array index out of range", Preamble & """
a = 3
cells(a) = 4
a = a + 3
cells(a) = 5
""")

agree("a fixed-point index names a whole cell", Preamble & """
x = 2.0
cells(x) = 9
y = 2.5
cells(y) = 1
""")

agree("dividing by zero", Preamble & """
a = 5
b = 0
c = a \ b
""")

agree("fixed-point division by zero", Preamble & """
x = 5.5
y = 0.0
c = x / y
""")

agree("a whole number too wide for fixed point", Preamble & """
a = 40000
x = 0.5
y = a + x
""")

agree("adding a string to a number", Preamble & """
s$ = "a"
a = len(s$)
t$ = s$ + str$(a)
b = a + len(t$)
""")

agree("host code that raises", Preamble & """
a = twice(6)
b = halve(a)
x = halve(3.0)
c = pick(a, b)
d = twice(13)
e = 1
""")

agree("host data", Preamble & """
a = seed + seed
x = scale * 2
s$ = mail$ + "!"
b = a + seed
""")

agree("printing", Preamble & """
print "a"; 1; -2
print 1.5, -0.125
s$ = "text"
print s$
print
""")

agree("call depth runs out", Preamble & """
sub deep(n)
  a = a + 1
  deep(n + 1)
end sub
deep(0)
""")

agree("GOSUB depth runs out", Preamble & """
again:
a = a + 1
gosub again
""")

block:
  var limits = defaultLimits()
  limits.maxInstructions = 777
  agree("the instruction budget runs out part way", Preamble & """
while 1
  a = a + 1
  cells(a mod 6) = a
wend
""", limits)

block:
  var limits = defaultLimits()
  limits.maxWorkUnits = 901
  agree("the work budget runs out part way", Preamble & """
while 1
  a = a + 1
  b = a \ 3
wend
""", limits)

block:
  var limits = defaultLimits()
  limits.maxPrintEvents = 5
  agree("the print budget runs out part way", Preamble & """
while 1
  a = a + 1
  print a
wend
""", limits)

block:
  var limits = defaultLimits()
  limits.maxStrings = 6
  agree("string storage runs out part way", Preamble & """
while 1
  s$ = s$ + "x"
  a = a + 1
wend
""", limits)

agree("wrapping at both ends", Preamble & """
a = 2147483647
a = a + 1
b = -2147483647 - 1
c = b \ -1
d = b mod -1
e = b * -1
f = -b
x = 32767.5
x = x + 1
y = -32768
y = y - 0.5
""")

agree("select, for, do, and on-goto", Preamble & """
for i = 1 to 10 step 3
  select case i
  case 1, 4
    a = a + i
  case 7 to 9
    b = b + i
  case else
    c = c + i
  end select
next
do while d < 5
  d = d + 1
  if d = 3 then exit do
loop
e = 2
on e goto first, second, third
first:
  f = 1
second:
  g = 2
third:
  h = 3
""")

block:
  # A host function that writes the script's own state from inside a run
  # must be seen at once, by both paths, including inside a loop.
  proc pokeRun(native: bool): string =
    var host = makeHost()
    var target: Runtime
    discard host.addFunction("poke", 1,
      proc(arguments: openArray[int32]): int32 =
        target.setGlobal("a", arguments[0] *% 3)
        target.setArray("cells", 0, arguments[0])
        0
    )
    let program = compile(Preamble & """
while b < 50
  b = b + 1
  a = a + b
  c = c + a + cells(0)
  if b mod 7 = 0 then d = poke(b)
wend
""", host)
    target = initRuntime(program, host)
    if native:
      discard target.compileNative()
    discard target.run()
    $target.getGlobal("a") & " " & $target.getGlobal("c") & " " &
      $target.getArray("cells", 0)
  let plain = pokeRun(false)
  let fast = pokeRun(true)
  if plain == fast:
    echo "  ok  host code writing globals mid-run"
  else:
    inc failures
    echo &"FAIL  host code writing globals mid-run: {plain} then {fast}"

## Generated programs

type Generator = object
  random: Rand
  depth: int
  labels: int

proc pick[T](g: var Generator, items: openArray[T]): T =
  ## Picks one item.
  items[g.random.rand(0 ..< items.len)]

proc chance(g: var Generator, percent: int): bool =
  ## Reports true about this often.
  g.random.rand(0 ..< 100) < percent

proc literal(g: var Generator): string =
  ## A whole-number or fixed-point constant, with the edges favoured.
  case g.random.rand(0 .. 9)
  of 0: $g.pick([0, 1, -1, 2147483647, -2147483647, 32767, -32768, 13])
  of 1, 2: &"{g.random.rand(-40 .. 40)}.{g.pick([0, 5, 25, 125, 75])}"
  else: $g.random.rand(-20 .. 20)

proc divisor(g: var Generator): string =
  ## A divisor that is usually safe, and now and then zero or minus one.
  case g.random.rand(0 .. 19)
  of 0: "0"
  of 1: "-1"
  else: $g.pick([2, 3, 4, 5, 7, 8, 16, -3, -8, 1000])

proc whole(g: var Generator): string =
  ## A whole-number expression of bounded depth, safe to index and divide.
  inc g.depth
  defer: dec g.depth
  if g.depth > 3 or g.chance(35):
    case g.random.rand(0 .. 6)
    of 0, 1: return $g.random.rand(-20 .. 20)
    of 2: return $g.pick([0, 1, -1, 2147483647, -2147483647, 13, 65536])
    of 3, 4, 5: return g.pick(Scalars)
    else: return "cells(" & $g.random.rand(0 ..< Cells) & ")"
  case g.random.rand(0 .. 11)
  of 0 .. 3:
    let op = g.pick(["+", "-", "*", "+", "-"])
    "(" & g.whole() & " " & op & " " & g.whole() & ")"
  of 4, 5:
    let op = g.pick(["\\", "mod"])
    "(" & g.whole() & " " & op & " " & g.divisor() & ")"
  of 6:
    let op = g.pick(["=", "<>", "<", "<=", ">", ">="])
    "(" & g.whole() & " " & op & " " & g.whole() & ")"
  of 7:
    let op = g.pick(["and", "or", "xor", "eqv", "imp"])
    "(" & g.whole() & " " & op & " " & g.whole() & ")"
  of 8: "(not " & g.whole() & ")"
  of 9: "-" & g.whole()
  of 10: "twice(" & g.whole() & ")"
  else: "pick(" & g.whole() & ", " & g.whole() & ")"

proc numeric(g: var Generator): string

proc cellIndex(g: var Generator): string =
  ## An index that is usually in range and sometimes not.
  if g.chance(90):
    $g.random.rand(0 ..< Cells)
  elif g.chance(50):
    "(" & g.whole() & " mod 6)"
  else:
    g.numeric()

proc numeric(g: var Generator): string =
  ## A numeric expression of bounded depth, either kind.
  inc g.depth
  defer: dec g.depth
  if g.depth > 3 or g.chance(30):
    case g.random.rand(0 .. 5)
    of 0, 1: return g.literal()
    of 2, 3: return g.pick(Scalars)
    of 4: return g.pick(Decimals)
    else: return "cells(" & g.cellIndex() & ")"
  case g.random.rand(0 .. 16)
  of 0 .. 4:
    let op = g.pick(["+", "-", "*", "+", "-"])
    "(" & g.numeric() & " " & op & " " & g.numeric() & ")"
  of 5:
    "(" & g.numeric() & " / " & g.pick(["2", "0.5", "-4", "3", "0"]) & ")"
  of 6:
    "(" & g.numeric() & " / " & g.numeric() & ")"
  of 7:
    let op = g.pick(["\\", "mod"])
    "(" & g.numeric() & " " & op & " " & g.divisor() & ")"
  of 8, 9:
    let op = g.pick(["=", "<>", "<", "<=", ">", ">="])
    "(" & g.numeric() & " " & op & " " & g.numeric() & ")"
  of 10:
    let op = g.pick(["and", "or", "xor", "eqv", "imp"])
    "(" & g.numeric() & " " & op & " " & g.numeric() & ")"
  of 11: "(not " & g.numeric() & ")"
  of 12: "-" & g.numeric()
  of 13: "halve(" & g.numeric() & ")"
  of 14: "len(" & g.pick(Texts) & ")"
  of 15: g.whole()
  else: "twice(" & g.whole() & ")"

proc text(g: var Generator): string =
  ## A string expression.
  case g.random.rand(0 .. 8)
  of 0: "\"" & g.pick(["", "a", "abc", " pad ", "Mixed"]) & "\""
  of 1: g.pick(Texts)
  of 2: g.pick(Texts) & " + " & g.pick(Texts)
  of 3: "left$(" & g.pick(Texts) & ", " & $g.random.rand(0 .. 4) & ")"
  of 4: "mid$(" & g.pick(Texts) & ", " & $g.random.rand(1 .. 4) & ")"
  of 5: "str$(" & g.numeric() & ")"
  of 6: "words$(" & $g.random.rand(0 ..< TextCells) & ")"
  of 7: "mid$(" & g.pick(Texts) & ", " & g.whole() & ", " & g.whole() & ")"
  else: "chr$(" & $g.random.rand(60 .. 90) & ")"

proc statement(g: var Generator, indent: string, room: int): string

proc body(g: var Generator, indent: string, room: int): string =
  ## A few statements.
  for _ in 0 ..< g.random.rand(1 .. 4):
    result.add(g.statement(indent, room))

proc statement(g: var Generator, indent: string, room: int): string =
  ## One statement, nesting only while there is room.
  let choice = g.random.rand(0 .. (if room > 0: 16 else: 9))
  case choice
  of 0 .. 3:
    indent & g.pick(Scalars) & " = " &
      (if g.chance(80): g.whole() else: g.numeric()) & "\n"
  of 4:
    indent & g.pick(Decimals) & " = " & g.numeric() & "\n"
  of 5:
    indent & "cells(" & g.cellIndex() & ") = " &
      (if g.chance(70): g.whole() else: g.numeric()) & "\n"
  of 6:
    indent & g.pick(Texts) & " = " & g.text() & "\n"
  of 7:
    indent & "words$(" & $g.random.rand(0 ..< TextCells) & ") = " &
      g.text() & "\n"
  of 8:
    indent & "print " & g.numeric() & "; " & g.text() & "\n"
  of 9:
    indent & g.pick(["bump(" & g.whole() & ")", "gosub tally",
      "a = a + 1", "b = b - 1"]) & "\n"
  of 10 .. 12:
    let condition = g.numeric()
    var text = indent & "if " & condition & " then\n" &
      g.body(indent & "  ", room - 1)
    if g.chance(50):
      text.add(indent & "else\n" & g.body(indent & "  ", room - 1))
    text & indent & "end if\n"
  of 13, 14:
    let counter = g.pick(Scalars)
    indent & "for " & counter & " = 0 to " & $g.random.rand(0 .. 12) &
      "\n" & g.body(indent & "  ", room - 1) & indent & "next\n"
  else:
    let counter = g.pick(Scalars)
    indent & "while " & counter & " < " & $g.random.rand(-5 .. 30) & "\n" &
      indent & "  " & counter & " = " & counter & " + 1\n" &
      g.body(indent & "  ", room - 1) & indent & "wend\n"

proc generated(seed: int64): string =
  ## Builds one program out of everything the language offers.
  var g = Generator(random: initRand(seed))
  result = Preamble
  for name in Scalars:
    if g.chance(70):
      result.add(name & " = " & g.literal() & "\n")
  for name in Decimals:
    if g.chance(70):
      result.add(name & " = " & g.literal() & "\n")
  result.add(g.body("", 2))
  result.add(g.body("", 2))
  result.add("end\n")
  result.add("tally:\n  c = c + " & g.literal() & "\n  return\n")
  result.add("sub bump(n)\n  d = d + n\n" & g.body("  ", 1) &
    "  if n < 3 then bump(n + 1)\nend sub\n")

var
  tried = 0
  disagreed = 0
  outcomes: CountTable[string]
for seed in 1'i64 .. 1500'i64:
  let source = generated(seed)
  var limits = defaultLimits()
  limits.maxCallDepth = 16
  limits.maxInstructions = [300'i64, 5_000, 200_000][int(seed mod 3)]
  limits.maxStrings = 64
  try:
    discard compile(source, makeHost(), limits)
  except BasicError:
    continue
  inc tried
  let plain = observe(source, false, limits, 3)
  for line in plain.splitLines:
    if line.startsWith("raised "):
      outcomes.inc(line[0 ..< min(line.len, 60)])
    elif line.startsWith("stats "):
      outcomes.inc("finished")
  let fast = observe(source, true, limits, 3)
  if plain != fast:
    inc disagreed
    if disagreed <= 2:
      echo &"FAIL  generated seed {seed}"
      echo source
      let plainLines = plain.splitLines
      let fastLines = fast.splitLines
      for index in 0 ..< max(plainLines.len, fastLines.len):
        let left = if index < plainLines.len: plainLines[index] else: ""
        let right = if index < fastLines.len: fastLines[index] else: ""
        if left != right:
          echo &"  interpreted  {left}"
          echo &"  native       {right}"
if disagreed > 0:
  inc failures
  echo &"FAIL  {disagreed} of {tried} generated programs disagreed"
else:
  echo &"  ok  {tried} generated programs agree"
for outcome, count in outcomes:
  echo &"      {count:>5}  {outcome}"
echo &"      {handed} of {executed} instructions handed back to interpreter code"

if failures > 0:
  quit(&"{failures} native checks failed")
echo &"whole programs compiled natively: {compiled}"
echo "compiled programs are indistinguishable from interpreted ones"
