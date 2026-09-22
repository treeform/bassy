## Checks that compiled loops agree with the interpreter.
## Every script runs twice, once interpreted and once with its hot loops
## executed as machine code. The globals and both budgets must match
## exactly, because a script must not be able to tell which path ran.

import
  std/[strformat, strutils],
  bassy

type Outcome = object
  globals: seq[Value]
  instructions: int64
  work: int64
  failure: string
  regions: int

proc describe(value: Value): string =
  ## Renders a global for comparison output.
  case value.kind
  of IntegerValue: $value.asInt
  of FixedValue: $value.asFixed
  of StringValue: "<string>"

proc execute(source: string, native: bool): Outcome =
  ## Runs one script with or without native compilation.
  let program = compile(source)
  var runtime = initRuntime(program)
  if native:
    result.regions = runtime.compileNative()
  try:
    discard runtime.run()
  except BasicError as error:
    result.failure = error.msg
  for index in 0 ..< program.globals:
    result.globals.add(runtime.globalValue(int32(index)))
  let (instructions, work) = runtime.remainingBudget
  result.instructions = instructions
  result.work = work

proc check(name, source: string, expectRegions = true) =
  ## Compares the two execution paths and reports any disagreement.
  let plain = execute(source, false)
  let fast = execute(source, true)
  var problems: seq[string]
  if jitSupported() and expectRegions and fast.regions == 0:
    problems.add("no loop was compiled")
  if plain.globals.len != fast.globals.len:
    problems.add("global count differs")
  else:
    for index in 0 ..< plain.globals.len:
      if plain.globals[index].describe != fast.globals[index].describe:
        problems.add(
          &"global {index}: interpreted {plain.globals[index].describe} " &
          &"but native {fast.globals[index].describe}"
        )
  if plain.instructions != fast.instructions:
    problems.add(
      &"instruction budget: interpreted {plain.instructions} " &
      &"but native {fast.instructions}"
    )
  if plain.work != fast.work:
    problems.add(
      &"work budget: interpreted {plain.work} but native {fast.work}"
    )
  if plain.failure != fast.failure:
    problems.add(
      &"failure: interpreted '{plain.failure}' but native '{fast.failure}'"
    )
  if problems.len > 0:
    echo "FAIL ", name
    for problem in problems:
      echo "     ", problem
    quit(1)
  let note =
    if fast.regions > 0: &"{fast.regions} compiled"
    else: "interpreted only"
  echo &"  ok  {name:<34} {note}"

echo "native compilation available: ", jitSupported()

check "counting loop", """
i = 0
total = 0
while i < 1000
  total = total + i
  i = i + 1
wend
"""

check "integer wraparound", """
i = 0
total = 0
while i < 100000
  total = total + 987654321
  i = i + 1
wend
"""

check "modulo branch", """
i = 0
even = 0
while i < 1000
  if i mod 2 = 0 then
    even = even + 1
  end if
  i = i + 1
wend
"""

check "negative step", """
i = 100
total = 0
while i > 0
  total = total + i
  i = i + -1
wend
"""

check "nested loops", """
outer = 0
inner = 0
hits = 0
while outer < 50
  inner = 0
  while inner < 20
    hits = hits + 1
    inner = inner + 1
  wend
  outer = outer + 1
wend
"""

check "loop that never runs", """
i = 500
total = 0
while i < 100
  total = total + 1
  i = i + 1
wend
"""

# A loop whose counter becomes fixed point must fall back to the
# interpreter without changing the answer.
check "fixed point defeats the guard", """
i = 0.5
total = 0
while i < 10
  total = total + 1
  i = i + 1
wend
""", expectRegions = false

# The instruction budget has to be refused at exactly the same point.
proc checkBudget(name: string, source: string, maximum: int64) =
  ## Compares budget exhaustion between the two paths.
  var limits = defaultLimits()
  limits.maxInstructions = maximum
  let program = compile(source, limits)
  var plainRuntime = initRuntime(program, limits)
  var plainFailure = ""
  try:
    discard plainRuntime.run()
  except BasicError as error:
    plainFailure = error.msg
  var fastRuntime = initRuntime(program, limits)
  discard fastRuntime.compileNative()
  var fastFailure = ""
  try:
    discard fastRuntime.run()
  except BasicError as error:
    fastFailure = error.msg
  let (plainLeft, _) = plainRuntime.remainingBudget
  let (fastLeft, _) = fastRuntime.remainingBudget
  if plainFailure != fastFailure or plainLeft != fastLeft:
    echo "FAIL ", name
    echo &"     interpreted '{plainFailure}' left {plainLeft}"
    echo &"     native      '{fastFailure}' left {fastLeft}"
    quit(1)
  echo &"  ok  {name:<34} stopped with {plainLeft} left"

checkBudget("instruction budget runs out", """
i = 0
total = 0
while i < 1000000
  total = total + i
  i = i + 1
wend
""", 5000)

echo "native compilation matches the interpreter"
