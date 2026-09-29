## Runs a bot's decisions the way a game hosts them, on both paths.
##
## Each decision restarts the VM and runs a script that scans the objects
## the host can see through one small host query per field, then scores
## them. That is where game scripts spend their time: in host calls and in
## restarting between decisions, not in arithmetic. The two are timed
## apart, so each can be improved and measured on its own.

import
  std/[monotimes, strformat, times],
  bassy

const
  Source = staticRead("decisions.bas")
  Objects = 60
  Decisions = 4000
  Runs = 3

type Arena = object
  ## The world the queries read, laid out flat.
  ids, kinds, teams, hps, xs, ys: array[Objects, int32]
  hidden: array[Objects, bool]
  tick: int32

var arena: Arena

proc stepArena(arena: var Arena) =
  ## Moves every object a little, deterministically, between decisions.
  inc arena.tick
  for index in 0 ..< Objects:
    let seed = int32(index) * 7919 + arena.tick * 104729
    arena.xs[index] = (arena.xs[index] + (seed mod 5) - 2 + 64) mod 64
    arena.ys[index] = (arena.ys[index] + ((seed div 5) mod 5) - 2 + 64) mod 64
    arena.hps[index] = (arena.hps[index] + 997 - (seed mod 13)) mod 400
    arena.hidden[index] = (seed mod 11) == 0

proc resetArena(arena: var Arena) =
  ## Lays the objects out the same way for every run.
  arena.tick = 0
  for index in 0 ..< Objects:
    arena.ids[index] = int32(index + 1)
    arena.kinds[index] = int32(1 + index mod 5)
    arena.teams[index] = int32(index mod 2)
    arena.hps[index] = int32(50 + (index * 37) mod 300)
    arena.xs[index] = int32((index * 13) mod 64)
    arena.ys[index] = int32((index * 29) mod 64)

template query(field: untyped): HostProc =
  ## One field of one visible object, or zero for anything out of view.
  proc(arguments: openArray[int32]): int32 =
    let index = int(arguments[0])
    if index < 0 or index >= Objects or arena.hidden[index]:
      0'i32
    else:
      arena.field[index]

proc buildHost(): Host =
  ## Binds the queries a bot script observes the world through.
  result = initHost()
  discard result.addFunction("objectCount", 0,
    proc(arguments: openArray[int32]): int32 = Objects, 2)
  discard result.addFunction("objectId", 1, query(ids), 4)
  discard result.addFunction("objectKind", 1, query(kinds), 4)
  discard result.addFunction("objectTeam", 1, query(teams), 4)
  discard result.addFunction("objectHp", 1, query(hps), 4)
  discard result.addFunction("objectX", 1, query(xs), 4)
  discard result.addFunction("objectY", 1, query(ys), 4)
  discard result.addFunction("selfInfo", 1,
    proc(arguments: openArray[int32]): int32 =
      case arguments[0]
      of 0: arena.xs[0]
      of 1: arena.ys[0]
      of 2: arena.teams[0]
      of 3: arena.ids[0]
      of 4: 30'i32
      else: arena.tick,
    4)

proc botLimits(): Limits =
  ## The per-decision limits a game gives each bot.
  result = defaultLimits()
  result.maxStrings = 1024
  result.maxStringLength = 64 * 1024
  result.maxStringBytes = 256 * 1024
  result.maxRegisters = 256
  result.maxCallDepth = 16
  result.maxMemoryBytes = 2 * 1024 * 1024
  result.maxInstructions = 100_000
  result.maxWorkUnits = 250_000

type Timing = object
  running, restarting: float
  tally: int32
  instructions: int64
  handed: int64

proc play(runtime: var Runtime): Timing =
  ## Plays every decision once, timing runs and restarts apart.
  arena.resetArena()
  runtime.reset()
  let handedBefore = runtime.handedBack
  for decision in 0 ..< Decisions:
    arena.stepArena()
    var started = getMonoTime()
    runtime.restart()
    result.restarting += (getMonoTime() - started).inNanoseconds.float
    started = getMonoTime()
    discard runtime.run()
    result.running += (getMonoTime() - started).inNanoseconds.float
    result.instructions += runtime.instructionsUsed
  result.tally = runtime.getGlobal("tally")
  result.handed = runtime.handedBack - handedBefore

proc fastest(runtime: var Runtime): Timing =
  ## Keeps the fastest of several plays, which all compute the same.
  result.running = Inf
  for attempt in 1 .. Runs:
    let timing = runtime.play()
    if timing.running + timing.restarting <
        result.running + result.restarting:
      result = timing

let host = buildHost()
let limits = botLimits()
let program = compile(Source, host, limits)

echo &"native compilation available: {jitSupported()}"
echo &"host: {hostCPU} {hostOS}"
echo &"decisions: {Decisions}, objects: {Objects}, " &
  &"bytecode {program.instructions} instructions"

var plain = initRuntime(program, host, limits)
var fast = initRuntime(program, host, limits)
let compiled = fast.compileNative()

let plainTiming = plain.fastest()
let fastTiming = fast.fastest()

proc report(name: string, timing: Timing) =
  ## Prints one path's time per decision, split into its two parts.
  let perRun = timing.running / Decisions / 1000.0
  let perRestart = timing.restarting / Decisions / 1000.0
  echo &"  {name:<12} run {perRun:7.2f} us   restart {perRestart:6.2f} us" &
    &"   per decision   tally {timing.tally}"

report("interpreted", plainTiming)
report("native", fastTiming)
if compiled > 0 and fastTiming.running > 0.0:
  echo &"  run ratio    {plainTiming.running / fastTiming.running:7.2f}x"
  let whole = (plainTiming.running + plainTiming.restarting) /
    (fastTiming.running + fastTiming.restarting)
  echo &"  whole ratio  {whole:7.2f}x"
echo &"  instructions per decision " &
  &"{plainTiming.instructions div Decisions}, handed back per decision " &
  &"{fastTiming.handed div Decisions}"

# Pinned, so every architecture must make the very same decisions.
const ExpectedTally = 723160'i32
if plainTiming.tally != ExpectedTally:
  quit(&"expected tally {ExpectedTally} but decided {plainTiming.tally}")
if plainTiming.tally != fastTiming.tally:
  quit("the two paths decided differently")
if plainTiming.instructions != fastTiming.instructions:
  quit("the two paths disagreed on the budget")

echo "the decisions agree on both paths"
