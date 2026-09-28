import
  std/strutils,
  bassy

proc execute(source: string, limits = defaultLimits()): Runtime =
  ## Runs a native string example with bounded storage.
  result = initRuntime(compile(source, limits), limits)
  discard result.run

proc errorContains(action: proc() {.closure.}, expected: string): bool =
  ## Checks that invalid string operations raise controlled BASIC errors.
  try:
    action()
  except BasicError as error:
    result = expected in error.msg

echo "Testing native string expressions, comparisons, arrays, and SUBs"
block:
  for disabled in [false, true]:
    var limits = defaultLimits()
    limits.disableFixed = disabled
    let runtime = execute("""
name = 42
name$ = "Ada"
greeting$ = "Hello, " + name$ + "!"
quoted$ = "Say ""hello""!"
copy$ = greeting$
emptyCopy$ = empty$
dim names$(2)
names$(0) = name$
names$(1) = names$(0) + " Lovelace"
names$(2) = names$(2) + "Grace"
sub greet(person$, times)
  gosub decorate
  if times > 0 then greet(person$ + "!", times - 1)
  answer$ = answer$ + person$
  exit sub
decorate:
  person$ = "[" + person$ + "]"
  return
end sub
greet("A", 1)
select case name$
case "Aaron" to "Az", "Grace"
  matched = true
case else
  matched = false
end select
if not name$ = "Grace" then different = true
""", limits)
    doAssert runtime.getGlobal("name") == 42
    doAssert runtime.getStringGlobal("name$") == "Ada"
    doAssert runtime.getStringGlobal("greeting$") == "Hello, Ada!"
    doAssert runtime.getStringGlobal("copy$") == "Hello, Ada!"
    doAssert runtime.getStringGlobal("quoted$") == "Say \"hello\"!"
    doAssert runtime.getStringGlobal("emptyCopy$") == ""
    doAssert runtime.getStringGlobal("answer$") == "[[A]!][A]"
    doAssert runtime.getStringArray("names$", 1) == "Ada Lovelace"
    doAssert runtime.getStringArray("names$", 2) == "Grace"
    doAssert runtime.getGlobal("matched") == -1
    doAssert runtime.getGlobal("different") == -1
    for (op, expected) in [
      ("=", 0), ("<>", -1), ("<", -1), ("<=", -1),
      (">", 0), (">=", 0)
    ]:
      let comparison = execute(
        "a$ = \"A\"\nb$ = \"a\"\nanswer = a$ " & op & " b$",
        limits
      )
      doAssert comparison.getGlobal("answer") == expected
    doAssert execute("answer = \"same\" = (\"sa\" + \"me\")",
      limits).getGlobal("answer") == -1

echo "Testing BASIC string functions and byte indexing"
block:
  var host = initHost()
  discard host.addData("mail$", "c")
  let program = compile("""
dim parts$(1)
a$ = "a"
b$ = "b"
a$ = a$ + b$
a$ = a$ + mail$
index = 1
parts$(index) = "d"
a$ = a$ + parts$(index)
parts$(index) = parts$(index) + b$
sub append(part$)
  a$ = a$ + part$
end sub
append("e")
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert runtime.getStringGlobal("a$") == "abcde"
  doAssert runtime.getStringArray("parts$", 1) == "db"

block:
  for (expression, expected) in [
    ("left$(\"abc\", 2)", "ab"), ("left$(\"abc\", 9)", "abc"),
    ("right$(\"abc\", 2)", "bc"), ("right$(\"abc\", 0)", ""),
    ("mid$(\"abc\", 2)", "bc"), ("mid$(\"abc\", 2, 1)", "b"),
    ("mid$(\"abc\", 99, 9)", ""), ("mid$(\"abc\", 1, 0)", ""),
    ("ucase$(\"aZé\")", "AZé"), ("lcase$(\"AzÉ\")", "azÉ"),
    ("trim$(\"  abc  \")", "abc"), ("trim$(\"   \")", ""),
    ("ltrim$(\"  abc  \")", "abc  "),
    ("rtrim$(\"  abc  \")", "  abc"), ("chr$(0)", "\0"),
    ("chr$(255)", "\xff"), ("space$(3)", "   "), ("space$(0)", ""),
    ("string$(3, \"abc\")", "aaa"), ("string$(2, 65)", "AA"),
    ("str$(12)", " 12"), ("str$(-12)", "-12"),
    ("str$(1.25)", " 1.25000"),
    ("left$(ucase$(\"abc\"), len(right$(\"xyz\", 2)))", "AB")
  ]:
    doAssert execute("answer$ = " & expression).
      getStringGlobal("answer$") == expected, expression
  for (expression, expected) in [
    ("len(\"é\")", 2), ("len(\"\")", 0), ("asc(\"ABC\")", 65),
    ("asc(chr$(0))", 0), ("asc(chr$(255))", 255),
    ("instr(\"abcabc\", \"bc\")", 2),
    ("instr(3, \"abcabc\", \"bc\")", 5),
    ("instr(\"abc\", \"abcd\")", 0),
    ("instr(\"abc\", \"z\")", 0), ("instr(\"abc\", \"\")", 1),
    ("instr(9, \"abc\", \"\")", 0), ("instr(\"\", \"\")", 0)
  ]:
    doAssert execute("answer = " & expression).
      getGlobal("answer") == expected, expression

echo "Testing string type errors and invalid function inputs"
block:
  doAssert errorContains(proc() = discard compile(
    "a$ = " & "ucase$(".repeat(MaximumSyntaxDepth + 1) & "\"a\"" &
    ")".repeat(MaximumSyntaxDepth + 1)
  ), "syntax nesting")
  for source in [
    "a = \"text\"", "a$ = 42", "a$ = \"x\" + 1",
    "a = \"1\" = 1", "a = not \"x\"", "a = +\"x\"",
    "a = -\"x\"", "a = \"x\" and \"y\"", "a = \"x\" / \"y\"",
    "if \"x\" then a = 1", "while \"x\"\nwend",
    "do\nloop until \"x\"", "for a$ = 1 to 3\nnext",
    "dim a$(2)\na$(0) = 1", "dim a(2)\na(0) = \"x\"",
    "dim a$(2)\na$(\"0\") = \"x\"",
    "sub f(a$)\nend sub\nf(1)", "sub f(a)\nend sub\nf(\"x\")",
    "a = len(1)", "a = len()", "a$ = left$(\"x\")",
    "a = len(\"x\",)", "a$ = mid$(\"x\", 1,)",
    "a$ = mid$(\"x\", 1, 2, 3)", "a$ = str$(\"1\")"
  ]:
    doAssert errorContains(proc() = discard compile(source), ""), source
  for source in [
    "a$ = left$(\"x\", -1)", "a$ = mid$(\"x\", 0)",
    "a$ = right$(\"x\", -1)", "a$ = mid$(\"x\", 1, -1)",
    "a$ = mid$(\"x\", 1.5)", "a$ = chr$(256)", "a$ = chr$(-1)",
    "a$ = space$(-1)", "a$ = string$(1, 256)", "a = asc(\"\")",
    "a$ = string$(1, \"\")", "a = instr(0, \"x\", \"x\")"
  ]:
    doAssert errorContains(proc() = discard execute(source), ""), source

echo "Testing native string host data, callbacks, and lifetime checks"
block:
  var
    host = initHost()
    runtime: Runtime
    received: seq[string]
  discard host.addData("mail$", "attack")
  discard host.addData("delta", 7)
  let reply: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Reads string arguments and creates a runtime-owned reply.
    received.add runtime.getString(args[0])
    doAssert args[1].asInt == 7
    runtime.putString("ok")
  discard host.addFunction("reply$", 2, reply)
  let program = compile("""
message$ = mail$
answer$ = reply$("hello " + message$, delta)
dim saved$(1)
saved$(1) = answer$
""", host)
  host.setData("mail$", "defend")
  doAssert host.getStringData("mail$") == "defend"
  runtime = initRuntime(program, host)
  discard runtime.run
  doAssert received == @["hello defend"]
  doAssert runtime.getStringGlobal("answer$") == "ok"
  let value = runtime.getGlobalValue("answer$")
  runtime.setArray("saved$", 0, "host")
  doAssert runtime.getStringArray("saved$", 0) == "host"
  runtime.setGlobal("message$", "host global")
  doAssert runtime.getStringGlobal("message$") == "host global"
  runtime.setData("mail$", "new mail")
  runtime.restart
  doAssert runtime.getStringGlobal("answer$") == "ok"
  doAssert errorContains(proc() = discard runtime.getString(value), "stale")
  var other = initRuntime(program, host)
  doAssert errorContains(proc() = other.setGlobal("answer$", value), "stale")
  doAssert errorContains(proc() = runtime.setGlobal("answer$", 1), "type")
  doAssert errorContains(proc() = discard value.asInt, "numeric")
  runtime.reset
  doAssert runtime.getStringGlobal("answer$") == ""
  doAssert runtime.getStringArray("saved$", 0) == ""
  doAssert runtime.getStringData("mail$") == "new mail"
  doAssert runtime.stringBytes == "new mail".len
  doAssert errorContains(proc() = discard runtime.getString(value), "stale")
  discard runtime.run
  doAssert received == @["hello defend", "hello new mail"]
  for stringResult in [false, true]:
    var
      wrong = initHost()
      invalid: Runtime
    let callback: NumericHostProc = proc(args: openArray[Value]): Value =
      ## Deliberately returns a value inconsistent with its declared suffix.
      if stringResult:
        invalid.putString("wrong type")
      else:
        toValue(1)
    let name =
      if stringResult:
        "wrong"
      else:
        "wrong$"
    discard wrong.addFunction(name, 0, callback)
    invalid = initRuntime(compile("s$ = \"\"\n" & name & "()", wrong), wrong)
    doAssert errorContains(proc() = discard invalid.run, "type mismatch")

echo "Testing bounded string allocation, reset compaction, and output"
block:
  var limits = defaultLimits()
  limits.maxStrings = 8
  limits.maxStringBytes = 32
  limits.maxStringLength = 16
  let program = compile("a$ = \"abc\"\nb$ = mid$(a$, 2)", limits)
  var runtime = initRuntime(program, limits)
  discard runtime.run
  doAssert runtime.stringBytes == 3
  doAssert runtime.stringCount == 3
  runtime.restart
  discard runtime.run
  doAssert runtime.stringBytes == 3
  doAssert runtime.stringCount == 4
  runtime.reset
  doAssert runtime.stringCount == 1
  doAssert runtime.stringBytes == 0
  limits.maxMemoryBytes = runtime.memoryBytes
  discard initRuntime(program, limits)
  dec limits.maxMemoryBytes
  doAssert errorContains(proc() = discard initRuntime(program, limits),
    "memory")
  limits = defaultLimits()
  limits.maxStringLength = 4
  doAssert errorContains(proc() = discard execute("a$ = \"12345\"", limits),
    "string length")
  doAssert errorContains(proc() = discard execute(
    "a$ = \"123\" + \"45\"", limits), "string length")
  limits.maxStrings = 3
  doAssert errorContains(proc() = discard execute(
    "a$ = \"a\"\nb$ = \"b\"\nc$ = a$ + b$", limits), "string count")
  limits.maxStrings = 20
  limits.maxStringBytes = 4
  doAssert errorContains(proc() = discard execute(
    "a$ = \"abc\"\nb$ = \"de\"", limits), "string byte")
  limits = defaultLimits()
  limits.maxWorkUnits = 100
  doAssert errorContains(proc() = discard execute(
    "a$ = space$(101)", limits), "work limit")
  limits = defaultLimits()
  limits.maxStrings = 8
  var bomb = initRuntime(compile(
    "do\na$ = ucase$(\"a\")\nloop", limits
  ), limits)
  for attempt in 0 ..< 2:
    doAssert errorContains(proc() = discard bomb.run, "string count")
    bomb.reset
    doAssert bomb.stringCount == 1
    doAssert bomb.stringBytes == 0
  let output = compile("name$ = \"Ada\"\nprint \"Hello, \" + name$;")
  var
    printed = initRuntime(output)
    text = ""
  let logger: PrintProc = proc(event: PrintEvent) =
    ## Captures native string print events after budget validation.
    doAssert event.kind == TextPrint
    text.add event.text
  doAssert printed.run(logger).printBytes == 10
  doAssert text == "Hello, Ada"
  limits = defaultLimits()
  limits.maxPrintBytes = 9
  var short = initRuntime(output, limits)
  text = ""
  doAssert errorContains(proc() = discard short.run(logger), "print byte")
  doAssert text == ""

block:
  var
    limits = defaultLimits()
    host = initHost()
  limits.maxStrings = 8
  limits.maxStringBytes = 6
  limits.maxStringLength = 6
  discard host.addData("first$", "")
  discard host.addData("second$", "")
  let program = compile("""
a$ = "abcdef"
b$ = left$(a$, 4)
c$ = right$(a$, 4)
""", host, limits)
  var runtime = initRuntime(program, host, limits)
  discard runtime.run
  runtime.setData("first$", runtime.getGlobalValue("b$"))
  runtime.setData("second$", runtime.getGlobalValue("c$"))
  runtime.reset
  doAssert runtime.stringBytes == 6
  doAssert runtime.getStringData("first$") == "abcd"
  doAssert runtime.getStringData("second$") == "cdef"
  runtime.reset
  doAssert runtime.stringBytes == 6
  doAssert runtime.getStringData("second$") == "cdef"

echo "Testing repeated string restarts and borrowed host access"
block:
  var host = initHost()
  discard host.addData("incoming$", "host value")
  var runtime: Runtime
  let inspect: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Borrows a substring without constructing a Nim string.
    runtime.withString(args[0], text):
      doAssert text.len == 4 and text[0] == 'e' and text[3] == 'i'
    toValue(1)
  discard host.addFunction("inspect", 1, inspect)
  let program = compile("""
dim saved$(2)
if turns = 0 then
  saved$(0) = "persistent text"
  saved$(1) = mid$(saved$(0), 2, 4)
end if
turns = turns + 1
message$ = "turn " + str$(turns) + incoming$
saved$(2) = message$
ok = inspect(saved$(1))
""", host)
  runtime = initRuntime(program, host)
  for i in 1 .. 1000:
    runtime.restart()
    discard runtime.run()
    doAssert runtime.getGlobal("turns") == i
    doAssert runtime.getStringArray("saved$", 0) == "persistent text"
    doAssert runtime.getStringArray("saved$", 1) == "ersi"
    doAssert runtime.getStringArray("saved$", 2) ==
      "turn  " & $i & "host value"
    doAssert runtime.getStringData("incoming$") == "host value"
    doAssert runtime.stringCount < 32
    doAssert runtime.stringBytes < 256
  let empty = runtime.putString("")
  runtime.withString(empty, text):
    doAssert text.len == 0
  runtime.reset()
  doAssert errorContains(proc() =
    runtime.withString(empty, text):
      discard text.len
  , "stale")

echo "Native string tests passed"
