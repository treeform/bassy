import
  std/strutils,
  bassy

const Records = """
TYPE Position
  x AS FIXED
  y AS FIXED32
END TYPE
TYPE PlayerState
  hp AS INTEGER
  score AS LONG
  position AS Position
  name AS STRING
  flexible AS NUMBER
END TYPE
DIM player AS PlayerState
DIM players(2) AS PlayerState
"""

proc errorContains(action: proc() {.closure.}, expected: string): bool =
  ## Checks that invalid record operations raise controlled BASIC errors.
  try:
    action()
  except BasicError as error:
    result = expected in error.msg

echo "Testing record defaults, typed fields, and nested dot access"
block:
  let program = compile(Records & """
LET Player.HP = 100
player.score = 12.0
player.position.x = 1.25
player.position.y = player.position.x + 2
player.name = "Ada"
player.flexible = .5
sub damage(amount, label$)
  player.hp = player.hp - amount
  player.name = player.name + label$
end sub
damage(7, "!")
if player.hp = 93 then players(2).hp = player.hp
players(2).position.x = player.position.x
players(2).name = ucase$(player.name)
answer = players(2).hp + len(players(2).name)
""")
  var runtime = initRuntime(program)
  doAssert runtime.getGlobal("player.hp") == 0
  doAssert runtime.getGlobalValue("player.position.x").kind == FixedValue
  doAssert runtime.getArrayValue("players.position.x", 0).kind == FixedValue
  doAssert runtime.getStringGlobal("player.name") == ""
  doAssert runtime.getStringArray("players.name", 0) == ""
  discard runtime.run
  doAssert runtime.getGlobal("PLAYER.HP") == 93
  doAssert runtime.getGlobal("player.score") == 12
  doAssert runtime.getGlobalValue("player.position.y").asFixed == 3.25'fx
  doAssert runtime.getGlobalValue("player.flexible").asFixed == 0.5'fx
  doAssert runtime.getStringGlobal("player.name") == "Ada!"
  doAssert runtime.getArray("players.hp", 2) == 93
  doAssert runtime.getStringArray("players.name", 2) == "ADA!"
  doAssert runtime.getGlobal("answer") == 97
  doAssert runtime.arrayLength("players.hp") == 3
  runtime.setGlobal("player.hp", 14)
  runtime.setGlobal("player.position.x", 3)
  runtime.setGlobal("player.name", "Grace")
  runtime.setArray("players.hp", 1, 17)
  runtime.setArray("players.position.x", 1, 4)
  runtime.setArray("players.name", 1, "Linus")
  doAssert runtime.getGlobalValue("player.position.x").kind == FixedValue
  doAssert runtime.getArrayValue("players.position.x", 1).kind == FixedValue
  runtime.restart
  doAssert runtime.getGlobal("player.hp") == 14
  doAssert runtime.getStringGlobal("player.name") == "Grace"
  doAssert runtime.getStringArray("players.name", 1) == "Linus"
  runtime.reset
  doAssert runtime.getGlobal("player.hp") == 0
  doAssert runtime.getGlobalValue("player.position.x").kind == FixedValue
  doAssert runtime.getArrayValue("players.position.x", 1).asFixed == 0'fx
  doAssert runtime.getStringGlobal("player.name") == ""
  doAssert runtime.getStringArray("players.name", 1) == ""
  var isolated = initRuntime(program)
  isolated.setGlobal("player.hp", 55)
  doAssert runtime.getGlobal("player.hp") == 0
  doAssert isolated.getGlobal("player.hp") == 55

echo "Testing record array indices and evaluation order"
block:
  var
    host = initHost()
    calls = 0
  proc nextIndex(arguments: openArray[int32]): int32 =
    ## Returns consecutive indices to detect duplicated evaluation.
    result = int32(calls)
    inc calls
  discard host.addFunction("nextIndex", 0, nextIndex)
  let program = compile(Records & """
players(nextIndex()).hp = 9
players(nextIndex()).hp = players(0).hp + 2
players(2).hp = players(1).hp + players(0).hp
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert calls == 2
  doAssert runtime.getArray("players.hp", 0) == 9
  doAssert runtime.getArray("players.hp", 1) == 11
  doAssert runtime.getArray("players.hp", 2) == 20
  for index in ["-1", "3", "2147483647", "0.5"]:
    doAssert errorContains(proc() =
      var invalid = initRuntime(compile(Records &
        "players(" & index & ").hp = 1"))
      discard invalid.run, "BASIC")
    doAssert errorContains(proc() =
      var invalid = initRuntime(compile(Records &
        "answer = players(" & index & ").hp"))
      discard invalid.run, "BASIC")

echo "Testing record numeric coercion and host boundary checks"
block:
  for source in [
    "player.hp = 1.5", "value = 1.5: player.hp = value",
    "players(0).hp = 1.5", "value = 40000: player.position.x = value",
    "player.position.x = 40000"
  ]:
    doAssert errorContains(proc() =
      var runtime = initRuntime(compile(Records & source))
      discard runtime.run, "BASIC")
  var runtime = initRuntime(compile(Records))
  doAssert errorContains(proc() =
    runtime.setGlobal("player.hp", 0.5'fx), "BASIC")
  doAssert errorContains(proc() =
    runtime.setArray("players.hp", 0, 0.5'fx), "BASIC")
  doAssert errorContains(proc() =
    runtime.setGlobal("player.position.x", 40000), "BASIC")
  doAssert errorContains(proc() =
    runtime.setGlobal("player.name", 7), "type mismatch")
  doAssert errorContains(proc() =
    runtime.setArray("players.name", 0, 7), "type mismatch")

echo "Testing record syntax errors and namespace conflicts"
block:
  for source in [
    "TYPE Empty\nEND TYPE",
    "TYPE T\nx AS INTEGER",
    "TYPE T\nx INTEGER\nEND TYPE",
    "TYPE T\nx AS \"integer\"\nEND TYPE",
    "TYPE T\nx AS FLOAT\nEND TYPE",
    "TYPE T\nx AS T\nEND TYPE",
    "TYPE T\nx AS Missing\nEND TYPE",
    "TYPE T\nx AS INTEGER\nX AS LONG\nEND TYPE",
    "TYPE T\nx AS STRING\nx$ AS STRING\nEND TYPE",
    "TYPE T\nx$ AS INTEGER\nEND TYPE",
    Records & "TYPE Position\nx AS INTEGER\nEND TYPE",
    Records & "DIM p AS Missing",
    Records & "DIM player AS PlayerState",
    Records & "DIM player(1)",
    Records & "SUB player()\nEND SUB",
    Records & "SUB bad(player)\nEND SUB",
    Records & "player.missing = 1",
    Records & "player.position = 1",
    Records & "player.position.x.extra = 1",
    Records & "players.hp = 1",
    Records & "players(0) = 1",
    Records & "answer = player",
    Records & "player = 1",
    Records & "player.hp = \"wrong\"",
    Records & "player.name = 1",
    Records & "undeclared.hp = 1",
    Records & "IF TRUE THEN\nDIM other AS PlayerState\nEND IF",
    "IF TRUE THEN\nTYPE T\nx AS INTEGER\nEND TYPE\nEND IF",
    "SUB bad()\nTYPE T\nx AS INTEGER\nEND TYPE\nEND SUB",
    Records & "SUB bad()\nDIM p AS PlayerState\nEND SUB"
  ]:
    doAssert errorContains(proc() = discard compile(source), ""), source

echo "Testing truncated record declarations remain controlled errors"
block:
  for i in 0 ..< Records.len:
    try:
      discard compile(Records[0 ..< i])
    except BasicError:
      discard

echo "Testing integer-only records and bounded layouts"
block:
  const Integers = """
TYPE Stats
  hp AS INT32
  title AS STRING
END TYPE
DIM player AS Stats
DIM players(1) AS Stats
player.hp = 2147483647
players(1).hp = player.hp + 1
player.title = "Knight"
"""
  var limits = defaultLimits()
  limits.disableFixed = true
  var runtime = initRuntime(compile(Integers, limits), limits)
  discard runtime.run
  doAssert runtime.getArray("players.hp", 1) == low(int32)
  doAssert runtime.getStringGlobal("player.title") == "Knight"
  doAssert errorContains(proc() = discard compile(Records, limits), "disabled")
  limits = defaultLimits()
  limits.maxArrays = 5
  doAssert errorContains(
    proc() = discard compile(Records, limits),
    "array count"
  )
  limits = defaultLimits()
  limits.maxArrayElements = 17
  doAssert errorContains(
    proc() = discard compile(Records, limits),
    "element limit"
  )
  limits = defaultLimits()
  limits.maxGlobals = 6
  doAssert errorContains(
    proc() = discard compile(Records & "extra = 1", limits),
    "global count"
  )
  limits = defaultLimits()
  limits.maxSyntaxDepth = 1
  doAssert errorContains(
    proc() = discard compile(Records, limits),
    "record nesting"
  )
  var source = "TYPE Base\n" & repeat("x", 100) & " AS INTEGER\nEND TYPE\n"
  for i in 1 .. 10:
    let child = if i == 1: "Base" else: "T" & $(i - 1)
    source.add "TYPE T" & $i & "\na AS " & child & "\nEND TYPE\n"
  limits = defaultLimits()
  limits.maxSourceBytes = source.len
  doAssert errorContains(
    proc() = discard compile(source, limits),
    "record layouts"
  )

echo "Testing QBasic numeric spellings and string field suffixes"
block:
  var runtime = initRuntime(compile("""
TYPE PlayerState
  hp AS INTEGER
  x AS SINGLE
  y AS DOUBLE
  tag$ AS STRING
END TYPE
DIM player AS PlayerState
player.hp = 100
player.x = 12.5
player.y = 8
player.tag$ = "QBasic"
answer$ = player.tag$
"""))
  discard runtime.run
  doAssert runtime.getGlobalValue("player.x").asFixed == 12.5'fx
  doAssert runtime.getGlobalValue("player.y").kind == FixedValue
  doAssert runtime.getStringGlobal("player.tag$") == "QBasic"
  doAssert runtime.getStringGlobal("answer$") == "QBasic"

echo "Testing bound numeric views retain typed storage and runtime ownership"
block:
  var
    runtime = initRuntime(compile(Records & "player.hp = player.hp - 1"))
    other = initRuntime(compile("unrelated = 9"))
  let
    hp = runtime.globalView("PLAYER.HP")
    position = runtime.globalView("player.position.x")
    health = runtime.arrayView("PLAYERS.HP", writable = true)
    positions = runtime.arrayView("players.position.x", writable = true)
    readOnly = runtime.arrayView("players.hp")
  hp.value = toValue(20)
  position.value = toValue(3)
  health[2] = toValue(17)
  positions[1] = toValue(5)
  doAssert hp.value.asInt == 20
  doAssert position.value.kind == FixedValue
  doAssert position.value.asFixed == 3'fx
  doAssert readOnly[2].asInt == 17
  doAssert positions[1].kind == FixedValue
  doAssert positions[1].asFixed == 5'fx
  discard runtime.run
  doAssert hp.value.asInt == 19
  runtime.restart()
  discard runtime.run
  doAssert hp.value.asInt == 18
  discard other.run
  doAssert hp.value.asInt == 18
  doAssert other.getGlobal("unrelated") == 9
  doAssert errorContains(proc() = hp.value = toValue(1.5'fx), "exact int32")
  doAssert errorContains(proc() = health[0] = toValue(1.5'fx), "exact int32")
  doAssert errorContains(proc() = readOnly[0] = toValue(1), "read-only")
  doAssert errorContains(proc() = health[-1] = toValue(1), "outside")
  doAssert errorContains(proc() = health[3] = toValue(1), "outside")
  doAssert errorContains(proc() = discard runtime.globalView("missing"),
    "unknown BASIC global")
  doAssert errorContains(proc() = discard runtime.arrayView("missing"),
    "unknown BASIC array")
  doAssert errorContains(proc() = discard runtime.globalView("player.name"),
    "strings")
  doAssert errorContains(proc() = discard runtime.arrayView("players.name"),
    "numeric")
  let text = runtime.putString("no")
  doAssert errorContains(proc() = hp.value = text, "numeric")
  var missing: GlobalView
  doAssert errorContains(proc() = discard missing.value, "unbound")
  doAssert errorContains(proc() = missing.value = toValue(1), "unbound")

echo "Testing scalar reference discovery includes subroutines and fused ops"
block:
  let program = compile(Records & """
dim samples(1)
sub inspect()
  answer = player.position.y
end sub
player.hp = player.hp + 1
player.score = player.score + player.hp
samples(player.hp) = player.score
if player.hp < 10 then answer = player.hp
""")
  for name in ["player.hp", "PLAYER.SCORE", "player.position.y", "answer"]:
    doAssert program.referencesGlobal(name), name
  for name in ["player.position.x", "player.flexible", "missing"]:
    doAssert not program.referencesGlobal(name), name
