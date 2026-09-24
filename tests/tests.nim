import
  std/strutils,
  bassy,
  test_controls, test_fixed, test_booleans, test_strings, test_determinism,
  test_data

proc errorContains(
    action: proc() {.closure.},
    expected: string
): bool =
  ## Returns whether an action raises the expected BASIC error text.
  try:
    action()
  except BasicError as error:
    result = expected in error.msg

echo "Testing BASIC arithmetic and case-insensitive globals"
block:
  let program = compile("""
Value = 2 + 3 * 4
wrapped = 2147483647 + 1
logic = value = 14 and not false
let oldStyle = value + 1
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("value") == 14
  doAssert runtime.getGlobal("VALUE") == 14
  doAssert runtime.getGlobal("wrapped") == low(int32)
  doAssert runtime.getGlobal("logic") == -1
  doAssert runtime.getGlobal("oldStyle") == 15

echo "Testing BASIC arrays and while loops"
block:
  let program = compile("""
dim scores(3)
i = 0
while i <= 3
  scores(i) = i * i
  i = i + 1
wend
""")
  var runtime = initRuntime(program)
  let stats = runtime.run
  doAssert runtime.arrayLength("scores") == 4
  doAssert runtime.getArray("scores", 0) == 0
  doAssert runtime.getArray("scores", 1) == 1
  doAssert runtime.getArray("scores", 2) == 4
  doAssert runtime.getArray("scores", 3) == 9
  doAssert stats.instructions > 0
  doAssert stats.workUnits > 0

echo "Testing BASIC if blocks, subs, and local parameters"
block:
  let program = compile("""
dim scores(4)

sub addScore(player, amount)
  if player >= 0 and player <= 4 then
    scores(player) = scores(player) + amount
    accepted = accepted + 1
  else
    rejected = rejected + 1
  end if
end sub

addScore(2, 7)
ADDSCORE(5, 9)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getArray("scores", 2) == 7
  doAssert runtime.getGlobal("accepted") == 1
  doAssert runtime.getGlobal("rejected") == 1

echo "Testing scalar names shared with string functions"
block:
  let program = compile("""
len = 7
asc = 8
instr = 9
sub measure(len, asc, instr)
  localTotal = len + asc + instr
  textTotal = len("abc") + asc("A") + instr("abc", "b")
  len = len + 1
  adjusted = len
end sub
measure(2, 3, 4)
globalTotal = len + asc + instr
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("localTotal") == 9
  doAssert runtime.getGlobal("textTotal") == 70
  doAssert runtime.getGlobal("adjusted") == 3
  doAssert runtime.getGlobal("globalTotal") == 24

echo "Testing BASIC recursion and exit sub"
block:
  let program = compile("""
sub accumulate(n)
  if n <= 0 then
    exit sub
  end if
  total = total + n
  accumulate(n - 1)
end sub

accumulate(5)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("total") == 15

echo "Testing fused scalar, array, branch, and call operations"
block:
  let program = compile("""
dim values(7)

sub addParam(value)
  parameterTotal = parameterTotal + value
end sub

i = 0
total = 0
even = 0
odd = 0
while i < 8
  index = i mod 8
  values(index) = values(index) + i
  total = total + values(index)
  if i mod 2 = 0 then
    even = even + 1
  else
    odd = odd + 1
  end if
  i = i + 1
wend
copy = total
addParam(copy)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("index") == 7
  doAssert runtime.getArray("values", 7) == 7
  doAssert runtime.getGlobal("total") == 28
  doAssert runtime.getGlobal("even") == 4
  doAssert runtime.getGlobal("odd") == 4
  doAssert runtime.getGlobal("copy") == 28
  doAssert runtime.getGlobal("parameterTotal") == 28

echo "Testing print events without BASIC string values"
block:
  let program = compile("""
score = 7
print "score", score
print "done";
""")
  var
    runtime = initRuntime(program)
    output = ""
  let logger: PrintProc = proc(event: PrintEvent) =
    case event.kind
    of TextPrint, FixedPrint:
      output.add event.text
    of ValuePrint:
      output.add $event.value
    of NewlinePrint:
      output.add '\n'
  let stats = runtime.run(logger)
  doAssert output == "score 7\ndone"
  doAssert stats.printBytes == int64(output.len)
  doAssert stats.printEvents == 5

echo "Testing host access and reset"
block:
  let program = compile("""
dim values(1)
counter = counter + 1
values(0) = counter
""")
  var runtime = initRuntime(program)
  runtime.setGlobal("COUNTER", 9)
  runtime.setArray("VALUES", 1, 23)
  discard runtime.run
  doAssert runtime.getGlobal("counter") == 10
  doAssert runtime.getArray("values", 0) == 10
  doAssert runtime.getArray("values", 1) == 23
  runtime.reset
  doAssert runtime.getGlobal("counter") == 0
  doAssert runtime.getArray("values", 1) == 0
  discard runtime.run
  doAssert runtime.getGlobal("counter") == 1

echo "Testing named host data and function calls"
block:
  var
    host = initHost()
    actionCount = 0'i32
    lastEntity = 0'i32
    lastX = 0'i32
    lastY = 0'i32
  discard host.addData("tick", 10)
  let add: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 2
    arguments[0] +% arguments[1]
  let readSecret: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 0
    5
  let moveEntity: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 3
    inc actionCount
    lastEntity = arguments[0]
    lastX = arguments[1]
    lastY = arguments[2]
    arguments[0] +% arguments[1] +% arguments[2]
  discard host.addFunction("add", 2, add, 4)
  discard host.addFunction("readSecret", 0, readSecret, 3)
  discard host.addFunction("moveEntity", 3, moveEntity, 12)
  let program = compile("""
nested = add(add(tick, readSecret()), add(3, 4))
result = moveEntity(7, nested, tick)
moveEntity(8, 1, 2)
""", host)
  var runtime = initRuntime(program, host)
  let tickId = program.hostDataIndex("tick")
  doAssert tickId >= 0
  runtime.setData(tickId, 11)
  doAssert runtime.getData("tick") == 11
  runtime.setData("TICK", 12)
  doAssert runtime.getData("tick") == 12
  runtime.setData(tickId, 11)
  let stats = runtime.run
  doAssert runtime.getData("tick") == 11
  doAssert runtime.getGlobal("nested") == 23
  doAssert runtime.getGlobal("result") == 41
  doAssert actionCount == 2
  doAssert lastEntity == 8
  doAssert lastX == 1
  doAssert lastY == 2
  doAssert stats.instructions > 0
  doAssert stats.workUnits >= 35
  doAssert errorContains(
    proc() = discard compile("tick = 1\n", host),
    "read-only"
  )
  doAssert errorContains(
    proc() = discard initRuntime(program),
    "missing BASIC host data binding"
  )

echo "Testing persistent restart, isolated runtimes, and a host action"
block:
  var
    host = initHost()
    lastX = 0'i32
    lastY = 0'i32
  let goTo: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 2
    lastX = arguments[0]
    lastY = arguments[1]
    1
  discard host.addFunction("walkTo", 2, goTo, 20)
  let program = compile("""
runs = runs + 1
walkTo(runs, 34)
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert runtime.getGlobal("runs") == 1
  doAssert lastX == 1
  doAssert lastY == 34
  runtime.restart
  discard runtime.run
  doAssert runtime.getGlobal("runs") == 2
  doAssert lastX == 2
  var otherRuntime = initRuntime(program, host)
  discard otherRuntime.run
  doAssert otherRuntime.getGlobal("runs") == 1
  doAssert runtime.getGlobal("runs") == 2

block:
  var
    host = initHost()
    calls = 0
    limits = defaultLimits()
  let blocked: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 0
    inc calls
    1
  discard host.addFunction("blocked", 0, blocked, 20)
  limits.maxWorkUnits = 10
  let program = compile("blocked()\n", host, limits)
  var runtime = initRuntime(program, host, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "work limit"
  )
  doAssert calls == 0
  var instructionLimits = defaultLimits()
  instructionLimits.maxInstructions = 0
  var instructionRuntime = initRuntime(
    program,
    host,
    instructionLimits
  )
  doAssert errorContains(
    proc() = discard instructionRuntime.run,
    "instruction limit"
  )
  doAssert calls == 0
  let memoryBytes = initRuntime(program, host).memoryBytes
  var memoryLimits = defaultLimits()
  memoryLimits.maxMemoryBytes = memoryBytes - 1
  doAssert errorContains(
    proc() = discard initRuntime(program, host, memoryLimits),
    "memory limit"
  )

echo "Testing work, memory, output, bounds, and call limits"
block:
  var limits = defaultLimits()
  limits.maxInstructions = 2
  let program = compile("first = 1\nsecond = 2\n", limits)
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "instruction limit"
  )
  doAssert runtime.instructionsUsed == 0

block:
  var limits = defaultLimits()
  limits.maxInstructions = 3
  let program = compile("first = 1\nsecond = 2\n", limits)
  var runtime = initRuntime(program, limits)
  let stats = runtime.run
  doAssert stats.instructions == 3
  doAssert runtime.instructionsUsed == 3

block:
  var limits = defaultLimits()
  limits.maxWorkUnits = 30
  let program = compile("""
i = 0
while true
  i = i + 1
wend
""")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "work limit"
  )

block:
  var limits = defaultLimits()
  limits.maxMemoryBytes = 16
  let program = compile("dim values(100)\n")
  doAssert errorContains(
    proc() = discard initRuntime(program, limits),
    "memory limit"
  )

block:
  let program = compile("dim values(1)\nvalues(-1) = 3\n")
  var runtime = initRuntime(program)
  doAssert errorContains(
    proc() = discard runtime.run,
    "outside 0"
  )

block:
  var limits = defaultLimits()
  limits.maxCallDepth = 4
  let program = compile("""
sub recurse(n)
  recurse(n + 1)
end sub
recurse(0)
""")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "call depth"
  )

block:
  var limits = defaultLimits()
  limits.maxPrintBytes = 2
  let program = compile("print \"long\"\n")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "print byte limit"
  )

echo "Testing BASIC syntax and type restrictions"
block:
  doAssert errorContains(
    proc() = discard compile("value = \"not a value\"\n"),
    "assignment type mismatch"
  )
  doAssert errorContains(
    proc() = discard compile("if true then\nvalue = 1\n"),
    "missing 'end if'"
  )
  doAssert errorContains(
    proc() = discard compile("dim values(2)\ndim values(3)\n"),
    "duplicate BASIC name"
  )
  doAssert errorContains(
    proc() = discard compile("goto = 10\n"),
    "expected a label"
  )

echo "Testing malformed source remains a controlled BASIC error"
block:
  let malformed = [
    "sub",
    "sub example(",
    "sub example()\n",
    "sub outer()\nsub inner()\nend sub\nend sub\n",
    "if true then\nsub nested()\nend sub\nend if\n",
    "if true then\ndim nested(1)\nend if\n",
    "end if\n",
    "if then\nend if\n",
    "value =\n",
    "dim\n",
    "dim values(\n",
    "missing(\n",
    "print 1 +\n",
    "values[0] = 1\n",
    "while\nwend\n"
  ]
  for source in malformed:
    doAssert errorContains(
      proc() = discard compile(source),
      ""
    )

block:
  let program = compile("rem Anything here is ignored: !@#$%^&*\nvalue = 3\n")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("value") == 3

block:
  let source =
    "value = " & "(".repeat(DefaultMaxSyntaxDepth + 1) & "1" &
    ")".repeat(DefaultMaxSyntaxDepth + 1) & "\n"
  doAssert errorContains(
    proc() = discard compile(source),
    "syntax nesting"
  )

block:
  const Alphabet =
    "abcdefghijklmnopqrstuvwxyz0123456789()=+-*/<>,;:\n\"' "
  var fuzzState = 0x51a7e123'u32
  for caseIndex in 0 ..< 2000:
    fuzzState = fuzzState xor (fuzzState shl 13)
    fuzzState = fuzzState xor (fuzzState shr 17)
    fuzzState = fuzzState xor (fuzzState shl 5)
    let length = int(fuzzState mod 80) + 1
    var source = newStringOfCap(length)
    for characterIndex in 0 ..< length:
      fuzzState = fuzzState xor (fuzzState shl 13)
      fuzzState = fuzzState xor (fuzzState shr 17)
      fuzzState = fuzzState xor (fuzzState shl 5)
      let index = int(
        (fuzzState xor uint32(caseIndex + characterIndex)) mod
        uint32(Alphabet.len)
      )
      source.add Alphabet[index]
    try:
      discard compile(source)
    except BasicError:
      discard

proc stringVm(
    source: string,
    limits = defaultStringLimits()
): tuple[runtime: Runtime, pool: StringPool] =
  ## Compiles a script against the string toolkit and binds one pool.
  var host = initHost()
  let pool = initStringPool(limits)
  host.addStringFunctions(pool)
  let program = compile(source, host)
  pool.bindProgram(program)
  (initRuntime(program, host), pool)

echo "Testing string literals as call arguments"
block:
  var host = initHost()
  var seen = ""
  var program: Program
  let recordProc: HostProc = proc(arguments: openArray[int32]): int32 =
    seen = program.literal(arguments[0])
  discard host.addFunction("record", 1, recordProc, 4)
  program = compile("""
record("hello mailbox")
""", host)
  doAssert program.literalCount == 1
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert seen == "hello mailbox"

echo "Testing string building and reading"
block:
  var (runtime, pool) = stringVm("""
s = strNew("attack ")
s = strCatInt(s, 12)
s = strCat(s, strNew(","))
s = strCatInt(s, 34)
length = strLen(s)
first = strByte(s, 0)
""")
  discard runtime.run
  doAssert pool.getString(runtime.getGlobal("s")) == "attack 12,34"
  doAssert runtime.getGlobal("length") == 12
  doAssert runtime.getGlobal("first") == int32(ord('a'))

echo "Testing message parsing with words, val, find, and eq"
block:
  ## The host injects an incoming message, mailbox style, and the script
  ## parses it without ever holding string data itself.
  var host = initHost()
  let pool = initStringPool()
  host.addStringFunctions(pool)
  let mailProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.putString("  attack   12 34 ")
  discard host.addFunction("mail", 0, mailProc, 8)
  let program = compile("""
message = mail()
verb = strWord(message, 0)
isAttack = strEq(verb, strNew("attack"))
x = strVal(strWord(message, 1))
y = strVal(strWord(message, 2))
words = strWordCount(message)
missing = strWord(message, 9)
missingLen = strLen(missing)
position = strFind(message, strNew("ck"), 0)
absent = strFind(message, strNew("retreat"), 0)
""", host)
  pool.bindProgram(program)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert runtime.getGlobal("isAttack") == -1
  doAssert runtime.getGlobal("x") == 12
  doAssert runtime.getGlobal("y") == 34
  doAssert runtime.getGlobal("words") == 3
  doAssert runtime.getGlobal("missingLen") == 0
  doAssert runtime.getGlobal("position") == 6
  doAssert runtime.getGlobal("absent") == -1

echo "Testing val leniency and saturation"
block:
  var (runtime, pool) = stringVm("""
plain = strVal(strNew("42"))
padded = strVal(strNew("  -42abc"))
junk = strVal(strNew("abc"))
big = strVal(strNew("99999999999999999999"))
small = strVal(strNew("-99999999999999999999"))
""")
  discard runtime.run
  doAssert runtime.getGlobal("plain") == 42
  doAssert runtime.getGlobal("padded") == -42
  doAssert runtime.getGlobal("junk") == 0
  doAssert runtime.getGlobal("big") == high(int32)
  doAssert runtime.getGlobal("small") == low(int32)
  discard pool

echo "Testing mid clamping, case mapping, trim, chr, and asc"
block:
  var (runtime, pool) = stringVm("""
s = strNew("  Hello World  ")
t = strTrim(s)
u = strUpper(t)
l = strLower(t)
clipped = strMid(t, 6, 99)
empty = strMid(t, 50, 5)
emptyLen = strLen(empty)
h = strChr(72)
code = strAsc(h)
emptyAsc = strAsc(empty)
same = strCmp(t, t)
before = strCmp(strNew("apple"), strNew("banana"))
""")
  discard runtime.run
  doAssert pool.getString(runtime.getGlobal("t")) == "Hello World"
  doAssert pool.getString(runtime.getGlobal("u")) == "HELLO WORLD"
  doAssert pool.getString(runtime.getGlobal("l")) == "hello world"
  doAssert pool.getString(runtime.getGlobal("clipped")) == "World"
  doAssert runtime.getGlobal("emptyLen") == 0
  doAssert pool.getString(runtime.getGlobal("h")) == "H"
  doAssert runtime.getGlobal("code") == 72
  doAssert runtime.getGlobal("emptyAsc") == -1
  doAssert runtime.getGlobal("same") == 0
  doAssert runtime.getGlobal("before") == -1

echo "Testing literal interning survives loops"
block:
  var (runtime, pool) = stringVm("""
i = 0
while i < 10000
  s = strNew("looped literal")
  i = i + 1
wend
""")
  discard runtime.run
  doAssert runtime.getGlobal("i") == 10000
  ## One pooled copy plus the shared empty string.
  doAssert pool.stringCount == 2

echo "Testing string count limit stops allocation loops"
block:
  var limits = defaultStringLimits()
  limits.maxStrings = 32
  var (runtime, pool) = stringVm("""
i = 0
while i < 100000
  s = strFromInt(i)
  i = i + 1
wend
""", limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "string count exceeds"
  )
  doAssert pool.stringCount <= 32

echo "Testing single string length limit stops concat growth"
block:
  var (runtime, pool) = stringVm("""
s = strNew("xxxxxxxxxxxxxxxx")
i = 0
while i < 100000
  s = strCat(s, s)
  i = i + 1
wend
""")
  doAssert errorContains(
    proc() = discard runtime.run,
    "length limit"
  )
  discard pool

echo "Testing arena byte limit stops fresh allocations"
block:
  var limits = defaultStringLimits()
  limits.maxStrings = 100_000
  limits.maxStringBytes = 512
  limits.maxStringLength = 64
  var (runtime, pool) = stringVm("""
i = 0
while i < 100000
  s = strCat(strNew("0123456789"), strFromInt(i))
  i = i + 1
wend
""", limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "byte limit"
  )
  doAssert pool.bytesUsed <= 512

echo "Testing forged and out-of-range handles fail"
block:
  var (runtime, pool) = stringVm("""
n = strLen(9999)
""")
  doAssert errorContains(
    proc() = discard runtime.run,
    "invalid BASIC string handle"
  )
  var (indexed, indexedPool) = stringVm("""
b = strByte(strNew("hi"), 2)
""")
  doAssert errorContains(
    proc() = discard indexed.run,
    "outside 0 .. 1"
  )
  discard pool
  discard indexedPool

echo "Testing stale handles fail after a pool reset"
block:
  var host = initHost()
  let pool = initStringPool()
  host.addStringFunctions(pool)
  discard host.addData("phase")
  let program = compile("""
if phase = 0 then
  kept = strNew("does not survive")
else
  n = strLen(kept)
end if
""", host)
  pool.bindProgram(program)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert pool.getString(runtime.getGlobal("kept")) == "does not survive"
  pool.reset
  runtime.restart
  runtime.setData("phase", 1)
  doAssert errorContains(
    proc() = discard runtime.run,
    "invalid BASIC string handle"
  )

echo "Testing pathological search hits its comparison cap"
block:
  var limits = defaultStringLimits()
  limits.maxStringLength = 512
  var (runtime, pool) = stringVm("""
hay = strNew("a")
i = 0
while i < 9
  hay = strCat(hay, hay)
  i = i + 1
wend
needle = strCat(strMid(hay, 0, 400), strNew("b"))
found = strFind(hay, needle, 0)
""", limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "comparison cap"
  )
  discard pool

echo "Testing the work budget also bounds string churn"
block:
  var host = initHost()
  let pool = initStringPool()
  host.addStringFunctions(pool)
  var limits = defaultLimits()
  limits.maxWorkUnits = 5_000
  let program = compile("""
i = 0
while i < 100000
  s = strNew("cheap")
  i = i + 1
wend
""", host, limits)
  pool.bindProgram(program)
  var runtime = initRuntime(program, host, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "work limit exceeded"
  )

echo "Testing host putString truncation and empty interning"
block:
  var limits = defaultStringLimits()
  limits.maxStringLength = 8
  let pool = initStringPool(limits)
  var host = initHost()
  host.addStringFunctions(pool)
  let program = compile("""
n = strLen(incoming)
""", host)
  ## putString truncates long host text instead of failing.
  pool.bindProgram(program)
  let handle = pool.putString("0123456789abcdef")
  doAssert pool.getString(handle) == "01234567"
  doAssert pool.putString("") == EmptyHandle
  var runtime = initRuntime(program, host)
  runtime.setGlobal("incoming", handle)
  discard runtime.run
  doAssert runtime.getGlobal("n") == 8

echo "Testing a string bomb fails the script, not the host"
block:
  ## One giant literal, far beyond the single-string cap, must raise a
  ## catchable BasicError before a byte lands in the arena, and the same
  ## runtime must recover with a reset and restart, the way a game keeps
  ## running after one bot's decision fails.
  var host = initHost()
  let pool = initStringPool()
  host.addStringFunctions(pool)
  discard host.addData("phase")
  var bomb = ""
  for i in 0 ..< 100_000:
    bomb.add 'x'
  let program = compile("""
if phase = 0 then
  s = strNew(""" & "\"" & bomb & "\"" & """)
else
  s = strNew("small and fine")
end if
""", host)
  pool.bindProgram(program)
  var runtime = initRuntime(program, host)
  doAssert errorContains(
    proc() = discard runtime.run,
    "length limit"
  )
  doAssert pool.bytesUsed == 0
  pool.reset
  runtime.restart
  runtime.setData("phase", 1)
  discard runtime.run
  doAssert pool.getString(runtime.getGlobal("s")) == "small and fine"

echo "BASIC tests passed"
