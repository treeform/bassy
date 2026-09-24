## Tries to get the native compiler to do something the interpreter would
## not. Compiled code indexes global storage without checking and writes
## through offsets worked out at compile time, so the checks that make
## that safe are the ones worth attacking.
##
## Two halves. The first hands compileProgram bytecode the language's own
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
  Limits = CallLimits(frames: 8, slots: 64)

proc countingLoop(globalIndex: int32, target: int32): seq[Instruction] =
  ## A minimal program, parameterised so it can be made malformed.
  @[
    Instruction(op: MeterOp, a: 4, b: 2),
    Instruction(
      op: JumpUnlessGlobalLessImmediateOp, a: globalIndex, b: 10, c: target
    ),
    Instruction(op: AddGlobalImmediateOp, a: globalIndex, b: 1),
    Instruction(op: JumpOp, a: 0),
    Instruction(op: MeterOp, a: 1, b: 1),
    Instruction(op: HaltOp)
  ]

proc main(code: seq[Instruction]): seq[RoutineExtent] =
  ## One routine covering the whole program.
  @[RoutineExtent(entry: 0, length: int32(code.len), registers: Slots)]

proc compiles(code: seq[Instruction], globals = Globals,
    routines: seq[RoutineExtent] = @[], extents: seq[ArrayExtent] = @[],
    constants: seq[int32] = @[], hostData = 0, arguments = 4): bool =
  ## Reports whether the whole program was accepted.
  let table = if routines.len > 0: routines else: main(code)
  compileProgram(code, table, extents, constants, globals, hostData,
    arguments, Limits) != nil

block:
  # The same shape must compile when it is well formed, or the refusals
  # below would prove nothing.
  report(
    "a well formed program still compiles",
    (not jitSupported()) or countingLoop(1, 4).compiles
  )

report(
  "a global one past the end is refused",
  not countingLoop(Globals, 4).compiles,
  "an out of range index would become a fixed offset store"
)

report(
  "a global far past the end is refused",
  not countingLoop(1_000_000, 4).compiles
)

report("a negative global is refused", not countingLoop(-1, 4).compiles)

report(
  "a branch past the end of the code is refused",
  not countingLoop(1, 99).compiles
)

report(
  "a negative branch target is refused",
  not countingLoop(1, -5).compiles
)

report(
  "a program with no storage behind it is refused",
  not countingLoop(1, 4).compiles(globals = 0)
)

block:
  # Nothing may hand the generator a global so far out that its offset
  # would not fit the displacement it is reached through.
  report(
    "a global whose offset would not fit is refused",
    not countingLoop(high(int32) div 8, 4).compiles(globals = high(int32))
  )

block:
  var code = countingLoop(1, 4)
  code[2] = Instruction(op: LoadGlobalOp, a: int32(Slots), b: 1)
  report("a register slot past the frame is refused", not code.compiles)
  code[2] = Instruction(op: LoadGlobalOp, a: -1, b: 1)
  report("a negative register slot is refused", not code.compiles)
  code[2] = Instruction(op: JumpIfZeroOp, a: int32(Slots), b: 4)
  report("a jump-if-zero slot past the frame is refused", not code.compiles)

block:
  var code = countingLoop(1, 4)
  code[2] = Instruction(op: ArrayGetOp, a: 0, b: 7, c: 1)
  report("an array that does not exist is refused", not code.compiles)
  report(
    "an array with a negative length is refused",
    not code.compiles(extents = @[
      ArrayExtent(base: 0, length: 1), ArrayExtent(base: 0, length: 1),
      ArrayExtent(base: 0, length: 1), ArrayExtent(base: 0, length: 1),
      ArrayExtent(base: 0, length: 1), ArrayExtent(base: 0, length: 1),
      ArrayExtent(base: 0, length: 1), ArrayExtent(base: 0, length: -4)
    ])
  )

block:
  var code = countingLoop(1, 4)
  code[2] = Instruction(op: LoadFixedOp, a: 0, b: 3)
  report("a fixed-point constant that does not exist is refused",
    not code.compiles(constants = @[1'i32]))
  code[2] = Instruction(op: LoadHostDataOp, a: 0, b: 2)
  report("host data that does not exist is refused",
    not code.compiles(hostData = 2))
  code[2] = Instruction(op: SetArgumentImmediateOp, a: 4, b: 1)
  report("an argument past the staging area is refused",
    not code.compiles(arguments = 4))

block:
  let code = countingLoop(1, 4)
  report(
    "a routine table that leaves code uncovered is refused",
    not code.compiles(routines = @[
      RoutineExtent(entry: 0, length: 4, registers: Slots)
    ])
  )
  report(
    "routines that overlap are refused",
    not code.compiles(routines = @[
      RoutineExtent(entry: 0, length: 6, registers: Slots),
      RoutineExtent(entry: 4, length: 2, registers: Slots)
    ])
  )
  report(
    "a routine reaching past the code is refused",
    not code.compiles(routines = @[
      RoutineExtent(entry: 0, length: 9, registers: Slots)
    ])
  )
  report(
    "a routine that runs on into the next one is refused",
    not code.compiles(routines = @[
      RoutineExtent(entry: 0, length: 2, registers: Slots),
      RoutineExtent(entry: 2, length: 4, registers: Slots)
    ])
  )
  report(
    "a branch into another routine is refused",
    not countingLoop(1, 4).compiles(routines = @[
      RoutineExtent(entry: 0, length: 4, registers: Slots),
      RoutineExtent(entry: 4, length: 2, registers: Slots)
    ])
  )

block:
  var code = countingLoop(1, 4)
  code[2] = Instruction(op: CallOp, a: 0)
  report("a call to the main program is refused", not code.compiles)
  code[2] = Instruction(op: CallOp, a: 5)
  report("a call to a routine that does not exist is refused",
    not code.compiles)

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

agrees("a loop that calls a subroutine", """
sub bump(v)
  total = total + v
end sub
i = 0
total = 0
while i < 200
  bump(i)
  bump(i)
  i = i + 1
wend
""")

agrees("a subroutine calling another", """
sub inner(v)
  total = total + v
end sub
sub outer(v)
  inner(v)
  inner(v)
end sub
i = 0
total = 0
while i < 200
  outer(i)
  i = i + 1
wend
""")

agrees("recursion", """
sub down(n)
  if n > 0 then
    hits = hits + 1
    down(n - 1)
  end if
end sub
i = 0
hits = 0
while i < 100
  down(8)
  i = i + 1
wend
""")

agrees("recursion past the depth limit", """
sub down(n)
  hits = hits + 1
  down(n + 1)
end sub
i = 0
hits = 0
while i < 3
  down(1)
  i = i + 1
wend
""")

agrees("leaving a subroutine early", """
sub maybe(v)
  if v > 50 then
    exit sub
  end if
  total = total + v
end sub
i = 0
total = 0
while i < 200
  maybe(i)
  i = i + 1
wend
""")

agrees("a callee that reaches an array", """
dim cells(63)
sub store(n)
  cells(n) = n * 2
end sub
i = 0
while i < 64
  store(i)
  i = i + 1
wend
""")

agrees("a callee doing something unmodelled", """
sub shout(v)
  print v
end sub
i = 0
while i < 20
  shout(i)
  i = i + 1
wend
""")

agrees("the budget running out inside a call", """
sub bump(v)
  total = total + v
end sub
i = 0
total = 0
while i < 100000
  bump(i)
  i = i + 1
wend
""", maximum = 977)

agrees("dividing between array cells", """
dim cells(63)
i = 0
while i < 64
  cells(i) = 100.0
  i = i + 1
wend
i = 1
while i < 64
  cells(i) = cells(i) / cells(i - 1)
  cells(i) = cells(i) + 99.5
  i = i + 1
wend
""")

agrees("dividing negatives between cells", """
dim cells(63)
i = 0
while i < 64
  cells(i) = 0.0 - 7.25
  i = i + 1
wend
i = 1
while i < 64
  cells(i) = cells(i) / cells(i - 1)
  cells(i) = cells(i) - 8.25
  i = i + 1
wend
""")

agrees("dividing by zero part way", """
d = 3
total = 0.0
i = 0
while i < 10
  total = total + 100 / d
  d = d - 1
  i = i + 1
wend
""")

agrees("dividing a whole too large to widen", """
n = 40000
total = 0.0
i = 0
while i < 10
  total = total + n / 2
  i = i + 1
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
