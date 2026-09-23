## Tries to get the native compiler to do something the interpreter would
## not. Compiled code indexes global storage without checking and writes
## through offsets worked out at compile time, so the checks that make
## that safe are the ones worth attacking.
##
## Two halves. The first hands compileRegion bytecode the language's own
## compiler would never produce, and requires it to refuse rather than
## emit. The second runs generated scripts down both paths and requires
## the results and both budgets to match, because a script that could tell
## the difference could be written to exploit it.

import
  std/[random, strformat],
  bassy,
  bassy/jit

var failures = 0

proc report(name: string, ok: bool, detail = "") =
  ## Records one check.
  if ok:
    echo &"  ok  {name}"
  else:
    inc failures
    echo &"FAIL  {name}"
    if detail.len > 0:
      echo &"      {detail}"

## The layout the code generator assumes

report(
  "value and context layout is the one the generator writes",
  layoutMatches(),
  "compiled stores would land at the wrong offsets"
)

## Bytecode the language could not produce

const
  Globals = 4
  Slots = 8

proc countingLoop(globalIndex: int32, target: int32): seq[Instruction] =
  ## A minimal loop, parameterised so it can be made malformed.
  @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(
      op: JumpUnlessGlobalLessImmediateOp, a: globalIndex, b: 10, c: target
    ),
    Instruction(op: AddGlobalImmediateOp, a: globalIndex, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]

block:
  # The same shape must compile when it is well formed, or the refusals
  # below would prove nothing.
  let code = countingLoop(1, 4)
  report(
    "a well formed loop still compiles",
    (not jitSupported()) or compileRegion(code, 0, 4, Globals, Slots, @[]) != nil
  )

block:
  let code = countingLoop(Globals, 4)
  report(
    "a global one past the end is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil,
    "an out of range index would become a fixed offset store"
  )

block:
  let code = countingLoop(1_000_000, 4)
  report(
    "a far out of range global is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  let code = countingLoop(-1, 4)
  report(
    "a negative global is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil,
    "a negative index would address below the globals"
  )

block:
  let code = countingLoop(1, 99)
  report(
    "a branch past the end of the code is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  let code = countingLoop(1, -5)
  report(
    "a negative branch target is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  let code = countingLoop(1, 4)
  report(
    "a region reaching past the code is refused",
    compileRegion(code, 0, 99, Globals, Slots, @[]) == nil
  )

block:
  let code = countingLoop(1, 4)
  report(
    "a region with no storage behind it is refused",
    compileRegion(code, 0, 4, 0, Slots, @[]) == nil
  )

block:
  # Dividing by zero raises in the interpreter, so it must never reach a
  # divide instruction.
  let code = @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: JumpUnlessGlobalModuloEqualZeroOp, a: 1, b: 0, c: 4),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  report(
    "a zero divisor is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  # A block whose charge will not fit the instruction that adds it must
  # leave that loop interpreted, not abandon the whole compilation.
  let code = @[
    Instruction(op: MeterOp, a: 9_000_000, b: 9_000_000),
    Instruction(
      op: JumpUnlessGlobalLessImmediateOp, a: 1, b: 10, c: 5
    ),
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  var raised = false
  try:
    discard compileRegion(code, 0, 5, Globals, Slots, @[])
  except BasicError:
    raised = true
  # Falling back to the per-block check is a fine outcome here. Refusing
  # the whole compilation is not.
  report("a charge too wide to add does not abandon compilation", not raised)

block:
  # compileLoops must survive a region it cannot finish, because the
  # interpreter can run anything the generator declines.
  let code = @[
    Instruction(op: MeterOp, a: 9_000_000, b: 9_000_000),
    Instruction(
      op: JumpUnlessGlobalLessImmediateOp, a: 1, b: 10, c: 5
    ),
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0),
    Instruction(op: HaltOp)
  ]
  var survived = false
  try:
    discard compileLoops(code, Globals, Slots, @[])
    survived = true
  except BasicError:
    survived = false
  report("compiling many loops survives one it cannot finish", survived)

block:
  # Nothing may hand the generator a global so far out that its offset
  # would not fit the displacement it is reached through.
  let code = countingLoop(high(int32) div 8, 4)
  report(
    "a global whose offset would not fit is refused",
    compileRegion(code, 0, 4, high(int32), Slots, @[]) == nil
  )

block:
  let code = @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: LoadGlobalOp, a: int32(Slots), b: 1),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  report(
    "a register slot past the frame is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  let code = @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: LoadGlobalOp, a: -1, b: 1),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  report(
    "a negative register slot is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  # An operation naming an array that does not exist must be refused.
  let code = @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: ArrayGetOp, a: 0, b: 7, c: 1),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  report(
    "an array that does not exist is refused",
    compileRegion(code, 0, 4, Globals, Slots, @[]) == nil
  )

block:
  # Cells reaching past what a displacement covers must be refused.
  let code = @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(op: ArrayGetOp, a: 0, b: 0, c: 1),
    Instruction(op: AddGlobalImmediateOp, a: 1, b: 1),
    Instruction(op: JumpOp, a: 0)
  ]
  let far = @[ArrayExtent(base: high(int32) div 4, length: 16)]
  report(
    "an array placed out of reach is refused",
    compileRegion(code, 0, 4, Globals, Slots, far) == nil
  )

## Scripts, down both paths

type Outcome = object
  globals: seq[int64]
  instructions: int64
  work: int64
  failure: string

proc execute(source: string, native: bool, maximum: int64): Outcome =
  ## Runs one script and records everything a script could observe.
  var limits = defaultLimits()
  limits.maxInstructions = maximum
  limits.maxWorkUnits = maximum
  let program = compile(source, limits)
  var runtime = initRuntime(program, limits)
  if native:
    discard runtime.compileNative()
  try:
    discard runtime.run()
  except BasicError as error:
    result.failure = error.msg
  for index in 0 ..< program.globals:
    let value = runtime.globalValue(int32(index))
    result.globals.add(
      case value.kind
      of IntegerValue: int64(value.asInt)
      of FixedValue: int64(int32(value.asFixed))
      of StringValue: -1'i64
    )
  let (instructions, work) = runtime.remainingBudget
  result.instructions = instructions
  result.work = work

proc agrees(name, source: string, maximum = 2_000_000'i64) =
  ## Requires the two paths to be indistinguishable from inside a script.
  let plain = execute(source, false, maximum)
  let fast = execute(source, true, maximum)
  var detail = ""
  if plain.globals != fast.globals:
    detail = &"globals {plain.globals} then {fast.globals}"
  elif plain.instructions != fast.instructions:
    detail = &"instructions {plain.instructions} then {fast.instructions}"
  elif plain.work != fast.work:
    detail = &"work {plain.work} then {fast.work}"
  elif plain.failure != fast.failure:
    detail = &"failure '{plain.failure}' then '{fast.failure}'"
  report(name, detail.len == 0, detail)

agrees("a loop wider than any budget still stops", """
i = 0
total = 0
while i < 2000000000
  total = total + 1
  i = i + 1
wend
""")

agrees("a loop that never advances still stops", """
i = 0
seen = 0
while i < 10
  seen = seen + 1
wend
""")

agrees("nesting cannot outrun the budget", """
a = 0
b = 0
hits = 0
while a < 100000
  b = 0
  while b < 100000
    hits = hits + 1
    b = b + 1
  wend
  a = a + 1
wend
""")

agrees("wrapping at the top of the range", """
i = 0
total = 2147483647
while i < 100
  total = total + 1
  i = i + 1
wend
""")

agrees("wrapping at the bottom of the range", """
i = 0
total = -2147483648
while i < 100
  total = total + -1
  i = i + 1
wend
""")

agrees("the most negative value against minus one", """
i = -2147483648
hits = 0
while i < -2147483638
  if i mod -1 = 0 then
    hits = hits + 1
  end if
  i = i + 1
wend
""")

agrees("a remainder against the most negative divisor", """
i = 0
hits = 0
while i < 50
  if i mod -2147483648 = 0 then
    hits = hits + 1
  end if
  i = i + 1
wend
""")

agrees("a counter that turns fractional mid-run", """
i = 0
total = 0
while i < 200
  total = total + 1
  i = i + 1
  if i = 100 then
    i = i + 0.5
  end if
wend
""")

agrees("a budget that runs out inside a loop", """
i = 0
total = 0
while i < 1000000
  total = total + i
  i = i + 1
wend
""", maximum = 733)

agrees("a budget that runs out on the first pass", """
i = 0
total = 0
while i < 1000000
  total = total + i
  i = i + 1
wend
""", maximum = 3)

agrees("arrays beside a compiled loop", """
dim cells(15)
i = 0
total = 0
while i < 16
  cells(i) = i
  i = i + 1
wend
j = 0
while j < 16
  total = total + cells(j)
  j = j + 1
wend
""")

agrees("reading past the end of an array", """
dim cells(15)
i = 0
total = 0
while i < 40
  total = total + cells(i)
  i = i + 1
wend
""")

agrees("writing past the end of an array", """
dim cells(15)
i = 0
while i < 40
  cells(i) = i
  i = i + 1
wend
""")

agrees("a negative array index", """
dim cells(15)
i = 5
total = 0
while i > -5
  total = total + cells(i)
  i = i + -1
wend
""")

agrees("an array holding fixed point", """
dim cells(15)
i = 0
total = 0
while i < 16
  cells(i) = i + 0.5
  i = i + 1
wend
j = 0
while j < 16
  total = total + cells(j)
  j = j + 1
wend
""")

agrees("fixed point arithmetic", """
x = 0.5
delta = 0.25
total = 0.0
i = 0
while i < 200
  total = total + x * delta
  x = x - delta
  i = i + 1
wend
""")

agrees("fixed point comparison", """
x = 0.0
hits = 0
i = 0
while i < 300
  x = x + 0.125
  if x > 10.0 then
    hits = hits + 1
  end if
  i = i + 1
wend
""")

agrees("mixing whole and fixed operands", """
x = 0.5
n = 3
total = 0
i = 0
while i < 100
  total = total + n
  x = x + 0.25
  i = i + 1
wend
""")

agrees("fixed point that wraps", """
x = 32767.0
i = 0
while i < 50
  x = x + 100.0
  i = i + 1
wend
""")

agrees("modulo and integer divide", """
i = 0
sum = 0
while i < 400
  sum = sum + (i mod 7)
  sum = sum + (i \ 5)
  i = i + 1
wend
""")

agrees("a divisor that reaches zero", """
d = 3
i = 0
total = 0
while i < 10
  total = total + (100 mod d)
  d = d - 1
  i = i + 1
wend
""")

agrees("dividing the most negative by minus one", """
a = -2147483648
d = -1
i = 0
total = 0
while i < 5
  total = total + (a \ d)
  i = i + 1
wend
""")

agrees("fixed point held in array cells", """
dim cells(63)
i = 0
while i < 64
  cells(i) = 0.5
  i = i + 1
wend
i = 0
while i < 63
  cells(i) = cells(i) + cells(i + 1)
  i = i + 1
wend
j = 0
while j < 63
  cells(j) = cells(j) * cells(j + 1)
  j = j + 1
wend
""")

## Generated scripts

proc generated(seed: int64): string =
  ## Builds a small integer program out of the shapes the compiler models.
  var random = initRand(seed)
  let names = ["a", "b", "c", "d"]
  result = ""
  for name in names:
    result.add(&"{name} = {random.rand(-40 .. 40)}\n")
  let counter = names[random.rand(0 .. 3)]
  result.add(&"{counter} = 0\n")
  result.add(&"while {counter} < {random.rand(1 .. 60)}\n")
  for statement in 0 ..< random.rand(1 .. 4):
    let target = names[random.rand(0 .. 3)]
    case random.rand(0 .. 3)
    of 0:
      result.add(&"  {target} = {target} + {random.rand(-9 .. 9)}\n")
    of 1:
      result.add(&"  {target} = {target} + {names[random.rand(0 .. 3)]}\n")
    of 2:
      let divisor = [2, 4, 8, 3, -2][random.rand(0 .. 4)]
      result.add(&"  if {target} mod {divisor} = 0 then\n")
      result.add(&"    {target} = {target} + 1\n")
      result.add("  end if\n")
    else:
      result.add(&"  {target} = {random.rand(-30 .. 30)}\n")
  result.add(&"  {counter} = {counter} + 1\n")
  result.add("wend\n")

var generatedFailures = 0
for seed in 1'i64 .. 400'i64:
  let source = generated(seed)
  let plain = execute(source, false, 2_000_000)
  let fast = execute(source, true, 2_000_000)
  if plain.globals != fast.globals or
      plain.instructions != fast.instructions or
      plain.work != fast.work or plain.failure != fast.failure:
    inc generatedFailures
    if generatedFailures == 1:
      echo "first disagreement, seed ", seed, ":"
      echo source
      echo &"  interpreted {plain.globals} {plain.instructions} " &
        &"{plain.work} '{plain.failure}'"
      echo &"  native      {fast.globals} {fast.instructions} " &
        &"{fast.work} '{fast.failure}'"
report(
  "400 generated scripts agree on both paths",
  generatedFailures == 0,
  &"{generatedFailures} disagreed"
)

if failures > 0:
  quit($failures & " safety checks failed")
echo "native compilation is indistinguishable from interpretation"
