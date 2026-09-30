## Compiles a whole program from the register bytecode to machine code.
##
## Every bytecode offset becomes a native block, so jumps, calls and
## returns go straight from one block to the next and the interpreter
## loop never runs. Values stay exactly where the interpreter keeps them,
## in the globals, the register file, the arguments and the array cells,
## which is what lets the two agree on every result, every budget and
## every failure.
##
## The common cases run inline: whole-number and fixed-point arithmetic,
## comparisons, branches, moves, array cells, calls, returns and budget
## meters. Everything else, such as strings, printing and host functions,
## and every operation about to fail, calls the one routine the
## interpreter itself runs for that instruction. Nothing is written
## before such a call, so the instruction is simply run there instead.
##
## The walker below is written once. Each architecture supplies the same
## small set of emitters, so AArch64 and x86-64 stay in step.

import
  bytecode, machine, numbers, texts

export machine.jitSupported, machine.enterCompiledCode,
  machine.leaveCompiledCode, machine.runningCompiledCode

const
  NativeArm64* = NativeCode and defined(arm64)
  NativeAmd64* = NativeCode and defined(amd64)

when NativeArm64:
  import arm64
elif NativeAmd64:
  import amd64

type
  NativeStatus* = enum
    ## Why compiled code returned to its caller.
    NativeCompleted,
    NativeFailed,
    NativeRetired

  NativeContext* = object
    ## The interpreter state compiled code reads and writes. The frame and
    ## the budgets live here whenever the interpreter's own code may need
    ## them, and go back into the runtime once compiled code returns.
    globals*: pointer
    remainingInstructions*: int64
    remainingWork*: int64
    pc*: int32
    memory*: pointer
    hostData*: pointer
    frames*: pointer
    arguments*: pointer
    registerFile*: pointer
    table*: pointer
    base*: int32
    depth*: int32
    routine*: int32
    runtime*: pointer
    step*: pointer
    hostStep*: pointer
    stringOwner*: pointer
    stringSpans*: pointer
    stringArena*: pointer
    queryStep*: pointer
    arrayReady*: pointer

  NativeCall* = proc(context: ptr NativeContext): int32
    {.cdecl, gcsafe, raises: [].}

  RoutineExtent* = object
    ## Where one routine's code sits, how many slots a call to it needs,
    ## and how many of those the caller fills in.
    entry*: int32
    length*: int32
    registers*: int32
    parameters*: int32

  CallLimits* = object
    ## The two ceilings a call has to respect, read from the runtime.
    frames*: int32
    slots*: int32

  ArrayExtent* = object
    ## Where one array sits in the shared cell storage, and how long it is.
    base*: int32
    length*: int32
    lazy*: bool
    id*: int32

const
  ValueStride = 16
  ValuePayload = 8
  ContextInstructions = 8
  ContextWork = 16
  ContextOffset = 24
  ContextMemory = 32
  ContextHostData = 40
  ContextFrames = 48
  ContextArguments = 56
  ContextRegisterFile = 64
  ContextTable = 72
  ContextBase = 80
  ContextDepth = 84
  ContextRoutine = 88
  ContextRuntime = 96
  ContextStep = 104
  ContextHostStep = 112
  ContextStringOwner = 120
  ContextStringSpans = 128
  ContextStringArena = 136
  ContextQueryStep = 144
  ContextArrayReady = 152

  ## One frame as the interpreter lays it out: where the caller's slots
  ## start, which routine it was in, where to carry on, and whether it
  ## came from a call or from a GOSUB. The host checks these against the
  ## real thing before any of it is compiled.
  FrameStride* = 16
  FrameBase* = 0
  FrameRoutine* = 4
  FrameReturn* = 8
  FrameTag* = 12

  FixedTag = 1
  StringTag = 2
  FixedShift = 16
  FixedRounding = 1'i64 shl (FixedShift - 1)

  ## Fixed-point values are only modelled inline when overflow is allowed
  ## to wrap. Under fixedChecks the interpreter asserts instead, so that
  ## build hands every fixed-point operation to the interpreter's code.
  ModelsFixed* = not defined(fixedChecks)

  MaxProgramBytes = 64 * 1024 * 1024
  ## How many blocks one fast version carries on into, holding values.
  MaxChain = 4
  ## Leaving a routine without one of these would run on into the next
  ## routine's code, which no call set up.
  Terminators = {JumpOp, ReturnOp, ReturnLabelOp, ExitSubOp, HaltOp}

proc layoutMatches*(): bool {.raises: [].} =
  ## Confirms the memory layout the code generator writes by hand.
  ##
  ## Generated code reaches into values and into the context by fixed
  ## offsets worked out from this Nim version. Nothing guarantees those
  ## stay put, and a silent change would turn every compiled store into a
  ## write at the wrong address, so they are checked rather than trusted.
  if sizeof(Value) != ValueStride:
    return false
  # The values are built in a sequence and read through copyMem rather
  # than cast from locals. Nim 2.2.6 and 2.2.10 both fail to compile a
  # procedure that takes the address of a converter-initialised variant
  # local and also returns early, with an index error and no location.
  var probe = newSeq[Value](2)
  probe[0] = toValue(0x5A6B7C0D'i32)
  probe[1] = toValue(fixed(1'i32))
  var image: array[ValueStride * 2, byte]
  copyMem(image[0].addr, probe[0].addr, ValueStride * 2)
  # A whole number must be tagged zero and a fixed-point one tagged one,
  # because the generated code tests the tag byte for exactly those.
  if image[0] != byte(ord(IntegerValue)) or ord(IntegerValue) != 0:
    return false
  if image[ValueStride] != byte(FixedTag) or ord(FixedValue) != FixedTag or
      ord(StringValue) != StringTag:
    return false
  var payload = 0'i32
  copyMem(payload.addr, image[ValuePayload].addr, sizeof(int32))
  if payload != 0x5A6B7C0D'i32:
    return false
  copyMem(payload.addr, image[ValueStride + ValuePayload].addr,
    sizeof(int32))
  if payload != int32(fixed(1'i32)):
    return false
  var context: NativeContext
  let origin = cast[int](context.addr)
  template at(field: untyped): int =
    cast[int](context.field.addr) - origin
  at(remainingInstructions) == ContextInstructions and
    at(remainingWork) == ContextWork and
    at(pc) == ContextOffset and
    at(memory) == ContextMemory and
    at(hostData) == ContextHostData and
    at(frames) == ContextFrames and
    at(arguments) == ContextArguments and
    at(registerFile) == ContextRegisterFile and
    at(table) == ContextTable and
    at(base) == ContextBase and
    at(depth) == ContextDepth and
    at(routine) == ContextRoutine and
    at(runtime) == ContextRuntime and
    at(step) == ContextStep and
    at(hostStep) == ContextHostStep and
    at(stringOwner) == ContextStringOwner and
    at(stringSpans) == ContextStringSpans and
    at(stringArena) == ContextStringArena and
    at(queryStep) == ContextQueryStep and
    at(arrayReady) == ContextArrayReady

type
  Machine* = ref object
    ## One whole program compiled to machine code.
    size*: int
    listing*: seq[byte]
    table: seq[pointer]
    buffer: CodeBuffer
    call: NativeCall

  Home = enum
    ## Where a value lives.
    SlotHome,
    GlobalHome,
    ArgumentHome,
    HostHome,
    CellHome

  Place = object
    ## One value's address, as a home and an index into it.
    home: Home
    index: int32

  Branching = enum
    ## Where a slow path carries on once the interpreter's code has run.
    ToNext,
    ToOffset

  Check = enum
    ## An architecture-neutral comparison outcome.
    EqualCheck,
    NotEqualCheck,
    LessCheck,
    LessEqualCheck,
    GreaterCheck,
    GreaterEqualCheck

when NativeArm64 or NativeAmd64:
  type
    Stub = object
      ## A slow path, placed after the block its operation sits in.
      label: Label
      offset: int32
      carry: Branching

proc slot(index: int32): Place {.inline, raises: [].} =
  ## Names a register slot in the current frame.
  Place(home: SlotHome, index: index)

proc global(index: int32): Place {.inline, raises: [].} =
  ## Names a scalar global.
  Place(home: GlobalHome, index: index)

proc argument(index: int32): Place {.inline, raises: [].} =
  ## Names a staged call argument.
  Place(home: ArgumentHome, index: index)

proc host(index: int32): Place {.inline, raises: [].} =
  ## Names a host data value.
  Place(home: HostHome, index: index)

proc cell(): Place {.inline, raises: [].} =
  ## Names the array cell whose address was just worked out.
  Place(home: CellHome)

proc comparisonCheck(op: Op): Check {.raises: [].} =
  ## Returns the outcome a comparison answers true on.
  case op
  of EqualOp: EqualCheck
  of NotEqualOp: NotEqualCheck
  of LessOp: LessCheck
  of LessEqualOp: LessEqualCheck
  of GreaterOp: GreaterCheck
  else: GreaterEqualCheck

proc swapped(check: Check): Check {.raises: [].} =
  ## Returns the outcome that asks the same with the operands turned round.
  case check
  of LessCheck: GreaterCheck
  of LessEqualCheck: GreaterEqualCheck
  of GreaterCheck: LessCheck
  of GreaterEqualCheck: LessEqualCheck
  else: check

proc takenOn(op: Op): Check {.raises: [].} =
  ## Returns the outcome on which a fused test takes its branch.
  case op
  of JumpUnlessGlobalEqualImmediateOp: NotEqualCheck
  of JumpUnlessGlobalNotEqualImmediateOp: EqualCheck
  of JumpUnlessGlobalLessImmediateOp: GreaterEqualCheck
  of JumpUnlessGlobalLessEqualImmediateOp: GreaterCheck
  of JumpUnlessGlobalGreaterImmediateOp: LessEqualCheck
  else: LessCheck

proc lowBitCount(divisor: int32): int {.raises: [].} =
  ## Returns how many low bits decide divisibility when the divisor is a
  ## power of two, or of its negation, and zero otherwise. Truncating
  ## division leaves nothing over exactly when those bits are clear, for
  ## negative dividends as well, so a bit test can stand in for a divide.
  var magnitude = abs(int64(divisor))
  if magnitude < 2 or (magnitude and (magnitude - 1)) != 0:
    return 0
  while magnitude > 1:
    magnitude = magnitude shr 1
    inc result

when NativeArm64:
  include arm64jit
elif NativeAmd64:
  include amd64jit

proc invoke*(machine: Machine, context: var NativeContext): NativeStatus
    {.raises: [].} =
  ## Runs the compiled program from the offset the context names.
  NativeStatus(machine.call(context.addr))

type
  Kind = enum
    ## What the compiler knows of a held value's kind.
    UnknownKind,
    WholeKind,
    FixedKind

  Held = object
    ## A slot or global a block's fast version keeps in registers. Its
    ## kind is either known here or held in a register of its own, and it
    ## is always a number: anything else never gets into a register.
    place: Place
    payload: int
    tag: int
    kind: Kind
    dirty: bool
    constant: bool
    value: int32

  Loop = object
    ## A loop whose globals can live in registers while it runs.
    ##
    ## Its budget is looked at only at checkpoints: its head and every
    ## other backward-branch target in it. Between two checkpoints a path
    ## has no backward branch, so it meets each meter at most once, and so
    ## charges at most what every meter in the loop adds up to. Each look
    ## asks for that much, and a loop short of it goes on in general code,
    ## which looks at every block and so refuses at the very same one.
    start: int
    stop: int
    globals: seq[int32]
    checkpoints: seq[bool]
    passInstructions: int64
    passWork: int64

proc loopGlobals(item: Instruction, globals: var seq[int32])
    {.raises: [].} =
  ## Records every global one operation reads or writes.
  template note(index: int32) =
    if index notin globals:
      globals.add(index)
  case item.op
  of StoreGlobalImmediateOp, AddGlobalImmediateOp,
      JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp,
      JumpUnlessGlobalModuloEqualZeroOp,
      AddGlobalHostDataOp, AddGlobalRegisterOp, StoreGlobalOp:
    note(item.a)
  of SetArgumentGlobalOp:
    note(item.b)
  of MoveGlobalOp, AddGlobalOp, ModuloGlobalImmediateOp:
    note(item.a)
    note(item.b)
  of LoadGlobalOp:
    note(item.b)
  of AddGlobalArrayGlobalIndexOp:
    note(item.a)
    note(item.c)
  of ArrayAddGlobalsOp:
    note(item.b)
    note(item.c)
  else:
    discard

proc fitsLoop(item: Instruction, queries: seq[bool]): bool {.raises: [].} =
  ## Reports whether an operation can run with its globals in registers.
  ## Nothing that calls out may, since the interpreter's code would find
  ## the globals' memory stale, and nothing that leaves the loop's code by
  ## any way but a branch may either.
  case item.op
  of MeterOp, LoadImmediateOp, LoadFixedOp, MoveOp, LoadGlobalOp,
      LoadHostDataOp, StoreGlobalOp, StoreGlobalImmediateOp, MoveGlobalOp,
      AddGlobalImmediateOp, AddGlobalOp, AddGlobalHostDataOp,
      AddGlobalRegisterOp, AddGlobalArrayGlobalIndexOp, ArrayAddGlobalsOp,
      AddOp, SubtractOp, MultiplyOp, IntegerDivideOp, ModuloOp, NegateOp,
      EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp, GreaterEqualOp,
      AndOp, OrOp, XorOp, EqvOp, ImpOp, NotOp, JumpOp, JumpIfZeroOp,
      JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp,
      ArrayGetOp, ArraySetOp:
    true
  of DivideOp:
    ModelsFixed
  of SetArgumentOp, SetArgumentImmediateOp, SetArgumentGlobalOp:
    true
  of HostCallOp:
    # A query neither reads nor changes the VM, so a loop's registers can
    # stay as they are across one. Any other host call may look at them.
    item.b >= 0 and int(item.b) < queries.len and queries[int(item.b)]
  of ModuloGlobalImmediateOp:
    item.c != 0
  of JumpUnlessGlobalModuloEqualZeroOp:
    item.b != 0
  else:
    false

proc findLoops(code: seq[Instruction], capacity: int, queries: seq[bool]):
    seq[Loop]
    {.raises: [].} =
  ## Picks the loops worth specialising: each closed by a jump back to its
  ## head, made only of operations that fit, and touching no more globals
  ## than there are registers. Outer loops are tried first, and a loop
  ## inside one already taken runs inside that one's registers.
  var candidates: seq[(int, int)]
  for index, item in code:
    if item.op == JumpOp and int(item.a) <= index and item.a >= 0:
      candidates.add((int(item.a), index + 1))
  var covered = newSeq[bool](code.len)
  while candidates.len > 0:
    var widest = 0
    for position in 1 ..< candidates.len:
      let (start, stop) = candidates[position]
      if stop - start > candidates[widest][1] - candidates[widest][0]:
        widest = position
    let (start, stop) = candidates[widest]
    candidates.delete(widest)
    var fits = true
    var globals: seq[int32]
    for index in start ..< stop:
      if covered[index] or not code[index].fitsLoop(queries):
        fits = false
        break
      code[index].loopGlobals(globals)
    if not fits or globals.len == 0 or globals.len > capacity:
      continue
    var loop = Loop(start: start, stop: stop, globals: globals,
      checkpoints: newSeq[bool](stop - start))
    loop.checkpoints[0] = true
    for index in start ..< stop:
      let item = code[index]
      var target = -1
      case item.op
      of JumpOp: target = int(item.a)
      of JumpIfZeroOp: target = int(item.b)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp,
          JumpUnlessGlobalModuloEqualZeroOp: target = int(item.c)
      else: discard
      if target >= start and target <= index:
        loop.checkpoints[target - start] = true
      if item.op == MeterOp:
        loop.passInstructions += int64(item.b)
        loop.passWork += int64(item.a)
    for offset, wanted in loop.checkpoints:
      if wanted and code[start + offset].op != MeterOp:
        fits = false
    if not fits:
      continue
    for index in start ..< stop:
      covered[index] = true
    result.add(loop)

proc emitProgram(code: seq[Instruction], routines: seq[RoutineExtent],
    ownerOf: seq[int32], extents: seq[ArrayExtent], constants: seq[int32],
    limits: CallLimits, far, strings: bool, queries: seq[bool]):
    (seq[byte], seq[int])
    {.raises: [BasicError].} =
  ## Emits the whole program and returns its bytes along with where each
  ## offset's block starts.
  ##
  ## Every offset has general code, which keeps every value in memory and
  ## so can hand any instruction to the interpreter's code. A loop that
  ## fits also gets a second, specialised copy that keeps its globals in
  ## registers. Entering the loop's head checks they hold whole numbers
  ## and moves into the copy; anything the copy does not expect writes the
  ## registers back and carries on in the general code of that very
  ## instruction, which does it the ordinary way.
  when not (NativeArm64 or NativeAmd64):
    raise newException(BasicError, "BASIC has no whole-program backend here")
  else:
    var e = Emitter(far: far)
    var blocks = newSeq[Label](code.len + 1)
    var general = newSeq[Label](code.len + 1)
    for index in 0 .. code.len:
      blocks[index] = e.label()
      general[index] = blocks[index]
    e.limit = code.len
    e.outside = blocks[code.len]
    let dispatchLabel = e.label()
    let slowLabel = e.label()
    let hostLabel = e.label()
    let failedLabel = e.label()

    let loops = findLoops(code, Hoisting.len, queries)
    var loopAt = newSeq[int](code.len)
    for index in 0 ..< code.len:
      loopAt[index] = -1
    for number, loop in loops:
      loopAt[loop.start] = number
      general[loop.start] = e.label()
    # Every ordinary block starts at a meter, and its general version gets
    # a label of its own, since its entry is the fast version.
    var inLoop = newSeq[bool](code.len)
    for loop in loops:
      for index in loop.start ..< loop.stop:
        inLoop[index] = true
    for index in 0 ..< code.len:
      if code[index].op == MeterOp and not inLoop[index]:
        general[index] = e.label()

    e.prologue()
    e.jump(dispatchLabel)

    var stubs: seq[Stub]

    template emitInstruction(at: int, specialised: static bool,
        loop: Loop, inside: seq[Label], exits: var seq[(Label, int, bool)]) =
      ## Emits one instruction, in general code or inside a loop's copy.
      let item = code[at]
      let offset = int32(at)

      template slowFor(after: Branching): Label =
        ## Names where this instruction goes when it cannot run inline.
        when specialised:
          leaveFor(at, true)
        else:
          let stub = Stub(label: e.label(), offset: offset, carry: after)
          stubs.add(stub)
          stub.label

      template leaveFor(target: int, again: bool): Label =
        ## Names a stub that writes the loop's registers back and goes on
        ## in general code: the same instruction again, or a branch target.
        var found = -1
        for position, exit in exits:
          if exit[1] == target and exit[2] == again:
            found = position
        if found < 0:
          exits.add((e.label(), target, again))
          found = exits.len - 1
        exits[found][0]

      template toBlock(target: int32): Label =
        ## Names where a branch to an offset lands.
        when specialised:
          if int(target) >= loop.start and int(target) < loop.stop:
            inside[int(target) - loop.start]
          else:
            leaveFor(int(target), false)
        else:
          blocks[int(target)]

      template held(which: int32): int {.used.} =
        ## Returns which register holds a global inside this loop.
        loop.globals.find(which)

      template runSlow() =
        ## Runs this instruction through the interpreter's code in line.
        e.callSlow(offset, slowLabel)

      var fallsThrough {.used.} = true
      case item.op
      of MeterOp:
        when specialised:
          if loop.checkpoints[at - loop.start]:
            e.meter(item.b, item.a, slowFor(ToNext),
              loop.passInstructions, loop.passWork)
          else:
            e.charge(item.b, item.a)
        else:
          e.meter(item.b, item.a, slowFor(ToNext))
      of LoadImmediateOp:
        e.writeConstant(slot(item.a), 0, item.b)
      of LoadFixedOp:
        e.writeConstant(slot(item.a), FixedTag, constants[int(item.b)])
      of MoveOp:
        e.copyValue(slot(item.a), slot(item.b))
      of LoadGlobalOp:
        when specialised:
          e.hoistedToTemp(0, held(item.b))
          e.writeWhole(slot(item.a), 0)
        else:
          e.copyValue(slot(item.a), global(item.b))
      of LoadHostDataOp:
        e.copyValue(slot(item.a), host(item.b))
      of StoreGlobalOp:
        when specialised:
          let slow = slowFor(ToNext)
          e.readValue(0, 2, slot(item.b))
          e.unlessWhole(2, slow)
          e.tempToHoisted(held(item.a), 0)
        else:
          e.copyValue(global(item.a), slot(item.b))
      of StoreGlobalImmediateOp:
        when specialised:
          e.setHoisted(held(item.a), item.b)
        else:
          e.writeConstant(global(item.a), 0, item.b)
      of MoveGlobalOp:
        when specialised:
          e.copyHoisted(held(item.a), held(item.b))
        else:
          e.copyValue(global(item.a), global(item.b))
      of SetArgumentOp:
        e.copyValue(argument(item.a), slot(item.b))
      of SetArgumentImmediateOp:
        e.writeConstant(argument(item.a), 0, item.b)
      of SetArgumentGlobalOp:
        when specialised:
          e.writeFromHoisted(argument(item.a), held(item.b))
        else:
          e.copyValue(argument(item.a), global(item.b))
      of AddGlobalImmediateOp:
        when specialised:
          e.addHoistedConstant(held(item.a), item.b)
        else:
          let slow = slowFor(ToNext)
          e.readValue(0, 2, global(item.a))
          e.unlessWhole(2, slow)
          e.loadConstant(1, item.b)
          e.add(0, 1)
          e.writeWhole(global(item.a), 0)
      of AddGlobalOp, AddGlobalHostDataOp, AddGlobalRegisterOp:
        when specialised:
          if item.op == AddGlobalOp:
            e.addHoisted(held(item.a), held(item.b))
          else:
            let slow = slowFor(ToNext)
            let source =
              if item.op == AddGlobalHostDataOp: host(item.b)
              else: slot(item.b)
            e.readValue(1, 3, source)
            e.unlessWhole(3, slow)
            e.addTempToHoisted(held(item.a), 1)
        else:
          let slow = slowFor(ToNext)
          let source =
            case item.op
            of AddGlobalOp: global(item.b)
            of AddGlobalHostDataOp: host(item.b)
            else: slot(item.b)
          e.readValue(0, 2, global(item.a))
          e.unlessWhole(2, slow)
          e.readValue(1, 3, source)
          e.unlessWhole(3, slow)
          e.add(0, 1)
          e.writeWhole(global(item.a), 0)
      of ModuloGlobalImmediateOp:
        if item.c == 0:
          runSlow()
        else:
          when specialised:
            e.hoistedToTemp(0, held(item.b))
            e.loadConstant(1, item.c)
            e.remainder(0, 1)
            e.tempToHoisted(held(item.a), 0)
          else:
            let slow = slowFor(ToNext)
            e.readValue(0, 2, global(item.b))
            e.unlessWhole(2, slow)
            e.loadConstant(1, item.c)
            e.remainder(0, 1)
            e.writeWhole(global(item.a), 0)
      of AddGlobalArrayGlobalIndexOp:
        let slow = slowFor(ToNext)
        when specialised:
          e.hoistedToTemp(0, held(item.c))
          e.cellAddress(0, extents[int(item.b)], slow)
          e.readValue(1, 3, cell())
          e.unlessWhole(3, slow)
          e.addTempToHoisted(held(item.a), 1)
        else:
          e.readValue(0, 2, global(item.c))
          e.unlessWhole(2, slow)
          e.cellAddress(0, extents[int(item.b)], slow)
          e.readValue(1, 3, cell())
          e.unlessWhole(3, slow)
          e.readValue(0, 2, global(item.a))
          e.unlessWhole(2, slow)
          e.add(0, 1)
          e.writeWhole(global(item.a), 0)
      of ArrayAddGlobalsOp:
        let slow = slowFor(ToNext)
        when specialised:
          e.hoistedToTemp(0, held(item.b))
          e.cellAddress(0, extents[int(item.a)], slow)
          e.readValue(1, 3, cell())
          e.unlessWhole(3, slow)
          e.hoistedToTemp(0, held(item.c))
        else:
          e.readValue(0, 2, global(item.b))
          e.unlessWhole(2, slow)
          e.cellAddress(0, extents[int(item.a)], slow)
          e.readValue(1, 3, cell())
          e.unlessWhole(3, slow)
          e.readValue(0, 2, global(item.c))
          e.unlessWhole(2, slow)
        e.add(1, 0)
        e.writeWhole(cell(), 1)
      of AddOp, SubtractOp, MultiplyOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        e.readValue(1, 3, slot(item.c))
        when ModelsFixed:
          # A whole number beside a fixed-point one becomes fixed point
          # first, exactly as the interpreter promotes it, and the answer
          # is fixed point.
          let ready = e.label()
          let promoteRight = e.label()
          e.unlessNumeric(2, slow)
          e.unlessNumeric(3, slow)
          e.jumpIfSame(2, 3, ready)
          e.whenFixed(2, promoteRight)
          e.toFixed(0, slow)
          e.loadConstant(2, FixedTag)
          e.jump(ready)
          e.place(promoteRight)
          e.toFixed(1, slow)
          e.place(ready)
        else:
          e.unlessSame(2, 3, slow)
          e.unlessWhole(2, slow)
        case item.op
        of AddOp:
          e.add(0, 1)
        of SubtractOp:
          e.subtract(0, 1)
        else:
          when ModelsFixed:
            let fixedWay = e.label()
            let joined = e.label()
            e.whenFixed(2, fixedWay)
            e.multiply(0, 1)
            e.jump(joined)
            e.place(fixedWay)
            e.multiplyFixed(0, 1)
            e.place(joined)
          else:
            e.multiply(0, 1)
        e.writeKind(slot(item.a), 2, 0)
      of DivideOp:
        when ModelsFixed:
          let slow = slowFor(ToNext)
          e.readValue(0, 2, slot(item.b))
          e.unlessNumeric(2, slow)
          e.readValue(1, 3, slot(item.c))
          e.unlessNumeric(3, slow)
          e.widenToFixed(0, 2, slow)
          e.widenToFixed(1, 3, slow)
          e.divideFixed(0, 1, slow)
          e.writeFixed(slot(item.a), 0)
        else:
          runSlow()
      of IntegerDivideOp, ModuloOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        e.unlessWhole(2, slow)
        e.readValue(1, 3, slot(item.c))
        e.unlessWhole(3, slow)
        e.jumpIfZeroValue(1, slow)
        if item.op == IntegerDivideOp:
          e.quotient(0, 1)
        else:
          e.remainder(0, 1)
        e.writeWhole(slot(item.a), 0)
      of NegateOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        when ModelsFixed:
          e.unlessNumeric(2, slow)
        else:
          e.unlessWhole(2, slow)
        e.negate(0)
        e.writeKind(slot(item.a), 2, 0)
      of EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp,
          GreaterEqualOp:
        # The same kind on both sides orders the same on the stored bits,
        # and the answer is always a whole number.
        let slow = slowFor(ToNext)
        let answered = e.label()
        e.readValue(0, 2, slot(item.b))
        e.readValue(1, 3, slot(item.c))
        when not specialised:
          if strings and item.op in {EqualOp, NotEqualOp}:
            # Two strings compare byte by byte where they are kept. Inside
            # a specialised loop this would need registers its globals
            # hold, so there it leaves the loop instead.
            let numbers = e.label()
            e.jumpUnlessTag(2, StringTag, numbers)
            e.jumpUnlessTag(3, StringTag, numbers)
            e.stringEquality(slot(item.b), slot(item.c),
              item.op == EqualOp, slow)
            e.jump(answered)
            e.place(numbers)
        e.unlessNumeric(2, slow)
        e.unlessNumeric(3, slow)
        let sameKind = e.label()
        let decided = e.label()
        e.jumpIfSame(2, 3, sameKind)
        # Kinds that differ compare on the widened fixed-point scale,
        # where every value of either kind has an exact place.
        e.scaleWide(0, 2)
        e.scaleWide(1, 3)
        e.compareWide(0, 1)
        e.jump(decided)
        e.place(sameKind)
        e.compare(0, 1)
        e.place(decided)
        e.answer(0, comparisonCheck(item.op))
        e.place(answered)
        e.writeWhole(slot(item.a), 0)
      of AndOp, OrOp, XorOp, EqvOp, ImpOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        e.unlessWhole(2, slow)
        e.readValue(1, 3, slot(item.c))
        e.unlessWhole(3, slow)
        case item.op
        of AndOp:
          e.bitAnd(0, 1)
        of OrOp:
          e.bitOr(0, 1)
        of XorOp:
          e.bitXor(0, 1)
        of EqvOp:
          e.bitXor(0, 1)
          e.bitNot(0)
        else:
          e.bitNot(0)
          e.bitOr(0, 1)
        e.writeWhole(slot(item.a), 0)
      of NotOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        e.unlessWhole(2, slow)
        e.bitNot(0)
        e.writeWhole(slot(item.a), 0)
      of JumpOp:
        e.jump(toBlock(item.a))
        fallsThrough = false
      of JumpIfZeroOp:
        # A fixed-point zero is all zero bits too, so either kind tests
        # the same way.
        let slow = slowFor(ToOffset)
        e.readValue(0, 2, slot(item.a))
        e.unlessNumeric(2, slow)
        e.jumpIfZeroValue(0, toBlock(item.b))
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp:
        when specialised:
          e.compareHoisted(held(item.a), item.b)
        else:
          let slow = slowFor(ToOffset)
          let whole = e.label()
          let decided = e.label()
          e.readValue(0, 2, global(item.a))
          e.whenWhole(2, whole)
          # A fixed-point global meets the constant on the widened scale.
          e.unlessFixed(2, slow)
          e.scaleWide(0, 2)
          e.loadWide(1, int64(item.b) * 65536)
          e.compareWide(0, 1)
          e.jump(decided)
          e.place(whole)
          e.compareConstant(0, item.b)
          e.place(decided)
        e.jumpOn(takenOn(item.op), toBlock(item.c))
      of JumpUnlessGlobalModuloEqualZeroOp:
        if item.b == 0:
          runSlow()
          e.jump(dispatchLabel)
          fallsThrough = false
        else:
          when specialised:
            e.hoistedToTemp(0, held(item.a))
          else:
            let slow = slowFor(ToOffset)
            e.readValue(0, 2, global(item.a))
            e.unlessWhole(2, slow)
          let bits = lowBitCount(item.b)
          if bits > 0:
            e.jumpIfLowBits(0, bits, toBlock(item.c))
          elif item.b != 1 and item.b != -1:
            # Dividing by one or minus one leaves nothing over, ever.
            e.loadConstant(1, item.b)
            e.remainder(0, 1)
            e.jumpIfNotZeroValue(0, toBlock(item.c))
      of ArrayGetOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.c))
        e.unlessWhole(2, slow)
        e.cellAddress(0, extents[int(item.b)], slow)
        e.copyValue(slot(item.a), cell())
      of ArraySetOp:
        let slow = slowFor(ToNext)
        e.readValue(0, 2, slot(item.b))
        e.unlessWhole(2, slow)
        e.cellAddress(0, extents[int(item.a)], slow)
        e.copyValue(cell(), slot(item.c))
      of CallOp, GosubOp:
        let owner = routines[int(ownerOf[at])]
        let slow = slowFor(ToOffset)
        if item.op == CallOp:
          let callee = routines[int(item.a)]
          e.enterRoutine(false, item.a, callee.registers, callee.parameters,
            owner.registers, offset + 1, limits, slow)
          e.jump(blocks[int(callee.entry)])
        else:
          e.enterRoutine(true, ownerOf[at], owner.registers, 0,
            owner.registers, offset + 1, limits, slow)
          e.jump(blocks[int(item.a)])
        fallsThrough = false
      of ReturnOp:
        let owner = routines[int(ownerOf[at])]
        e.leaveRoutine(owner.parameters, false, slowFor(ToOffset))
        fallsThrough = false
      of ExitSubOp:
        # With the sub's own frame on top there are no GOSUB frames to
        # unwind first, so leaving is a plain return. Anything else is
        # left to the interpreter's code, which unwinds them.
        e.leaveRoutine(0, true, slowFor(ToOffset))
        fallsThrough = false
      of HaltOp:
        e.halt(offset)
        fallsThrough = false
      of ReturnLabelOp:
        runSlow()
        e.jump(dispatchLabel)
        fallsThrough = false
      of HostCallOp:
        if item.b >= 0 and int(item.b) < queries.len and
            queries[int(item.b)]:
          # A query is asked directly. Should it refuse, or take anything
          # but whole numbers, the ordinary path does it all again.
          when specialised:
            var keep: seq[Register]
            for position in 0 ..< loop.globals.len:
              keep.add(Hoisting[position])
            e.callQuery(offset, keep, slowFor(ToNext))
          else:
            let ordinary = e.label()
            let asked = e.label()
            e.callQuery(offset, @[], ordinary)
            e.jump(asked)
            e.place(ordinary)
            e.callSlow(offset, hostLabel)
            e.place(asked)
        else:
          # Host calls have a helper of their own, which goes straight to
          # the host call's code instead of through the general dispatch.
          e.callSlow(offset, hostLabel)
      of TextCallOp:
        let function = TextFunction(item.b)
        if strings and item.c == 1 and
            function in {LengthFunction, CodeFunction}:
          # LEN and ASC read the string where it is kept.
          let slow = slowFor(ToNext)
          e.stringFunction(function, slow)
          e.writeWhole(slot(item.a), 0)
        else:
          runSlow()
      of LoadStringOp, PrintTextOp, PrintValueOp, PrintNewlineOp,
          BufferGetOp, BufferSetOp:
        # Returned arrays live in host buffers, reached only through the
        # checked views the interpreter's own code uses.
        runSlow()

      when not specialised:
        # Slow paths go after the block, out of the way of the fast ones.
        let blockEnds = at + 1 == code.len or
          code[at + 1].op == MeterOp
        if blockEnds and stubs.len > 0:
          if fallsThrough:
            e.jump(blocks[at + 1])
          for stub in stubs:
            e.place(stub.label)
            e.callSlow(stub.offset, slowLabel)
            case stub.carry
            of ToNext:
              e.jump(blocks[int(stub.offset) + 1])
            of ToOffset:
              e.jump(dispatchLabel)
          stubs.setLen(0)

    var noExits: seq[(Label, int, bool)]
    var loopCopies: seq[seq[Label]]
    for loop in loops:
      var inside: seq[Label]
      for index in loop.start ..< loop.stop:
        inside.add(e.label())
      loopCopies.add(inside)

    ## Fast versions of ordinary blocks
    ##
    ## An ordinary block, one outside any specialised loop, also gets a
    ## fast version that keeps the slots and globals it touches in pool
    ## registers from one instruction to the next instead of in memory. A
    ## value is read from memory once, written back once before anything
    ## else could look, and between the two its kind is checked at most
    ## once. Anything the fast version does not expect writes back what
    ## was pending and goes on in the block's general version at that very
    ## instruction, which does it the ordinary way.
    ##
    ## Registers are counted rather than guessed at. Before an instruction
    ## emits anything that could leave, enough registers are freed for the
    ## most it could need; within it none is handed out twice, so a way out
    ## taken part way through still finds every pending value where it was.

    var
      held: seq[Held]
      uses = newSeq[int](Pool.len)
      pinned = newSeq[bool](Pool.len)
      fastExits: seq[(Label, seq[Held], int)]

    proc samePlace(a, b: Place): bool {.raises: [].} =
      ## Reports whether two places name the same value.
      a.home == b.home and a.index == b.index

    template kindTag(kind: Kind): int =
      ## Returns the tag byte for a known kind.
      (if kind == FixedKind: FixedTag else: 0)

    template writeBack(value: Held) =
      ## Stores a held value where the interpreter keeps it.
      e.fastStore(value.place, value.payload, value.tag, kindTag(value.kind))

    template forget(position: int) =
      ## Drops one held value, freeing its registers once nothing uses them.
      dec uses[held[position].payload]
      if held[position].tag >= 0:
        dec uses[held[position].tag]
      held.delete(position)

    template flushAll() =
      ## Writes every pending value back, keeping them held.
      for position in 0 ..< held.len:
        if held[position].dirty:
          writeBack(held[position])
          held[position].dirty = false

    template clearAll() =
      ## Writes every pending value back and holds nothing further.
      flushAll()
      held.setLen(0)
      for register in 0 ..< Pool.len:
        uses[register] = 0

    template acquire(): int =
      ## Hands out a free register for the rest of this instruction.
      var found = -1
      for register in 0 ..< Pool.len:
        if uses[register] == 0 and not pinned[register]:
          found = register
          break
      if found < 0:
        raise newException(BasicError,
          "BASIC native compiler ran out of registers")
      pinned[found] = true
      found

    template pin(register: int) =
      ## Keeps a register from being handed out for this instruction.
      if register >= 0:
        pinned[register] = true

    template findHeld(target: Place): int =
      ## Returns where a value is held, or -1.
      var found = -1
      for position in 0 ..< held.len:
        if samePlace(held[position].place, target):
          found = position
      found

    template makeRoom(operands: openArray[Place], extra: int) =
      ## Frees enough registers for an instruction before it emits anything
      ## that could leave: two for each operand not yet held, plus what it
      ## needs of its own. Values it reads stay; the oldest others go,
      ## clean ones before those that must be written back.
      var needed = extra
      var counted: seq[Place]
      for operand in operands:
        var seen = false
        for earlier in counted:
          if samePlace(earlier, operand):
            seen = true
        if not seen:
          counted.add(operand)
          if findHeld(operand) < 0:
            needed += 2
      for pass in 0 .. 1:
        var position = 0
        while position < held.len:
          var free = 0
          for register in 0 ..< Pool.len:
            if uses[register] == 0:
              inc free
          if free >= needed:
            break
          var keep = false
          for operand in operands:
            if samePlace(held[position].place, operand):
              keep = true
          if keep or (pass == 0 and held[position].dirty):
            inc position
            continue
          if held[position].dirty:
            writeBack(held[position])
          forget(position)

    template leaveHere(offset: int): Label =
      ## Names a way out of the fast version: write back what is pending
      ## now, then do this instruction in general code.
      var pending: seq[Held]
      for value in held:
        if value.dirty:
          pending.add(value)
      let exit = e.label()
      fastExits.add((exit, pending, offset))
      exit

    template fetch(target: Place, offset: int): Held =
      ## Returns a value in registers, reading it from memory if it is not
      ## held yet. Only a number is held; anything else leaves.
      var position = findHeld(target)
      if position < 0:
        let payload = acquire()
        let tag = acquire()
        e.fastLoad(payload, tag, target, leaveHere(offset))
        held.add(Held(place: target, payload: payload, tag: tag,
          kind: UnknownKind))
        inc uses[payload]
        inc uses[tag]
        position = held.len - 1
      pin(held[position].payload)
      pin(held[position].tag)
      held[position]

    template bindValue(target: Place, valueRegister, kindRegister: int,
        known: Kind, isConstant = false, bits = 0'i32) =
      ## Holds a new value for a place, pending until written back, along
      ## with what it is when that is known here.
      let position = findHeld(target)
      if position >= 0:
        forget(position)
      held.add(Held(place: target, payload: valueRegister,
        tag: kindRegister, kind: known, dirty: true, constant: isConstant,
        value: bits))
      inc uses[valueRegister]
      if kindRegister >= 0:
        inc uses[kindRegister]

    template tagOf(value: Held): int =
      ## Returns a register holding a value's kind, loading a known kind.
      var register = value.tag
      if register < 0:
        register = acquire()
        e.fastConstant(register, int32(kindTag(value.kind)))
      register

    template requireWhole(value: Held, target: Place, exit: Label) =
      ## Leaves unless a value is a whole number, and from here on knows
      ## that it is.
      case value.kind
      of WholeKind:
        discard
      of FixedKind:
        e.jump(exit)
      of UnknownKind:
        e.fastJumpIfNotZero(value.tag, exit)
        let position = findHeld(target)
        if position >= 0 and held[position].tag >= 0:
          dec uses[held[position].tag]
          held[position].tag = -1
          held[position].kind = WholeKind

    template fallsOnward(op: Op): bool =
      ## Reports whether an operation can carry on to the next offset.
      op notin {JumpOp, ReturnOp, ReturnLabelOp, ExitSubOp, HaltOp, CallOp,
        GosubOp}

    template emitFast(at: int): bool =
      ## Emits one instruction into a fast version, or reports that it
      ## has no fast form, so that it is done the general way instead.
      let item = code[at]
      let offset = at
      var done = true
      case item.op
      of MeterOp:
        # The budget is looked at exactly as the general code would, and a
        # block short of it writes back and goes there to be refused.
        e.meter(item.b, item.a, leaveHere(offset))
      of LoadImmediateOp, LoadFixedOp, StoreGlobalImmediateOp:
        makeRoom(newSeq[Place](), 1)
        let register = acquire()
        let kind =
          if item.op == LoadFixedOp: FixedKind
          else: WholeKind
        let bits =
          if item.op == LoadFixedOp: constants[int(item.b)]
          else: item.b
        e.fastConstant(register, bits)
        let target =
          if item.op == StoreGlobalImmediateOp: global(item.a)
          else: slot(item.a)
        bindValue(target, register, -1, kind, true, bits)
      of MoveOp, LoadGlobalOp, StoreGlobalOp, MoveGlobalOp, LoadHostDataOp:
        let (target, source) =
          case item.op
          of MoveOp: (slot(item.a), slot(item.b))
          of LoadGlobalOp: (slot(item.a), global(item.b))
          of StoreGlobalOp: (global(item.a), slot(item.b))
          of MoveGlobalOp: (global(item.a), global(item.b))
          else: (slot(item.a), host(item.b))
        makeRoom([source], 0)
        let value = fetch(source, offset)
        bindValue(target, value.payload, value.tag, value.kind,
          value.constant, value.value)
      of SetArgumentOp, SetArgumentGlobalOp:
        let source =
          if item.op == SetArgumentOp: slot(item.b)
          else: global(item.b)
        makeRoom([source], 0)
        let value = fetch(source, offset)
        e.fastStore(argument(item.a), value.payload, value.tag,
          kindTag(value.kind))
      of SetArgumentImmediateOp:
        e.writeConstant(argument(item.a), 0, item.b)
      of HostCallOp:
        if item.b >= 0 and int(item.b) < queries.len and
            queries[int(item.b)]:
          # Held values survive a query: the registers holding them are
          # kept on the stack across it, and memory is not looked at.
          # The answer lands in its slot in memory, so whatever was held
          # for that slot is simply dropped.
          let exit = leaveHere(offset)
          var keep: seq[Register]
          for register in 0 ..< Pool.len:
            if uses[register] > 0:
              keep.add(pooled(register))
          e.callQuery(int32(offset), keep, exit)
          if item.a >= 0:
            let position = findHeld(slot(item.a))
            if position >= 0:
              forget(position)
        else:
          done = false
      of AddGlobalImmediateOp, AddGlobalOp, AddGlobalRegisterOp,
          AddGlobalHostDataOp:
        let target = global(item.a)
        let source =
          case item.op
          of AddGlobalOp: global(item.b)
          of AddGlobalRegisterOp: slot(item.b)
          of AddGlobalHostDataOp: host(item.b)
          else: target
        makeRoom([target, source], 2)
        let total = fetch(target, offset)
        let exit = leaveHere(offset)
        requireWhole(total, target, exit)
        let register = acquire()
        e.fastMove(register, total.payload)
        if item.op == AddGlobalImmediateOp:
          let amount = acquire()
          e.fastConstant(amount, item.b)
          e.fastAdd(register, amount)
        else:
          let value = fetch(source, offset)
          requireWhole(value, source, exit)
          e.fastAdd(register, value.payload)
        bindValue(target, register, -1, WholeKind)
      of AddOp, SubtractOp, MultiplyOp:
        when ModelsFixed:
          let left = slot(item.b)
          let right = slot(item.c)
          var known = 0
          for operand in [left, right]:
            let position = findHeld(operand)
            if position >= 0 and held[position].kind != UnknownKind:
              inc known
          makeRoom([left, right], 3 + known)
          let b = fetch(left, offset)
          let c = fetch(right, offset)
          template operate(target, source: int, fixed: bool) =
            ## Applies this instruction's operation to two registers.
            case item.op
            of AddOp:
              e.fastAdd(target, source)
            of SubtractOp:
              e.fastSubtract(target, source)
            else:
              if fixed:
                e.fastMultiplyFixed(target, source)
              else:
                e.fastMultiply(target, source)
          template promote(widened: int, side: Held, exit: Label) =
            ## Turns a whole number into fixed point in a fresh register.
            ## A constant is turned here, and one out of range can only
            ## ever leave, as the interpreter would refuse it.
            if side.constant:
              if side.value >= -32768 and side.value <= 32767:
                e.fastConstant(widened, side.value shl FixedShift)
              else:
                e.jump(exit)
            else:
              e.fastMove(widened, side.payload)
              e.fastToFixed(widened, exit)
          if b.kind != UnknownKind and c.kind != UnknownKind:
            let result = acquire()
            if b.kind == c.kind:
              e.fastMove(result, b.payload)
              operate(result, c.payload, b.kind == FixedKind)
            else:
              # Kinds known to differ: the whole side becomes fixed point.
              let exit = leaveHere(offset)
              let widened = acquire()
              if b.kind == WholeKind:
                promote(widened, b, exit)
                e.fastMove(result, widened)
                operate(result, c.payload, true)
              else:
                promote(widened, c, exit)
                e.fastMove(result, b.payload)
                operate(result, widened, true)
            let kind =
              if b.kind == WholeKind and c.kind == WholeKind: WholeKind
              else: FixedKind
            bindValue(slot(item.a), result, -1, kind)
          elif b.kind != UnknownKind or c.kind != UnknownKind:
            # One kind is known, so one test of the other decides: the
            # same kind goes straight through, the other promotes.
            let knownLeft = b.kind != UnknownKind
            let known = if knownLeft: b else: c
            let unknown = if knownLeft: c else: b
            let exit = leaveHere(offset)
            let result = acquire()
            let widened = acquire()
            let otherWay = e.label()
            let finished = e.label()
            if known.kind == WholeKind:
              let resultTag = acquire()
              e.fastJumpIfNotZero(unknown.tag, otherWay)
              e.fastMove(result, b.payload)
              operate(result, c.payload, false)
              e.fastConstant(resultTag, 0)
              e.jump(finished)
              e.place(otherWay)
              promote(widened, known, exit)
              if knownLeft:
                e.fastMove(result, widened)
                operate(result, c.payload, true)
              else:
                e.fastMove(result, b.payload)
                operate(result, widened, true)
              e.fastConstant(resultTag, FixedTag)
              e.place(finished)
              bindValue(slot(item.a), result, resultTag, UnknownKind)
            else:
              e.fastJumpIfZero(unknown.tag, otherWay)
              e.fastMove(result, b.payload)
              operate(result, c.payload, true)
              e.jump(finished)
              e.place(otherWay)
              e.fastMove(widened, unknown.payload)
              e.fastToFixed(widened, exit)
              if knownLeft:
                e.fastMove(result, b.payload)
                operate(result, widened, true)
              else:
                e.fastMove(result, widened)
                operate(result, c.payload, true)
              e.place(finished)
              bindValue(slot(item.a), result, -1, FixedKind)
          else:
            let exit = leaveHere(offset)
            let leftTag = tagOf(b)
            let rightTag = tagOf(c)
            let result = acquire()
            let resultTag = acquire()
            let widened = acquire()
            let mixed = e.label()
            let promoteRight = e.label()
            let joined = e.label()
            let finished = e.label()
            e.fastJumpIfDiffer(leftTag, rightTag, mixed)
            e.fastMove(result, b.payload)
            e.fastMove(resultTag, leftTag)
            if item.op == MultiplyOp:
              let fixedWay = e.label()
              e.fastJumpIfNotZero(leftTag, fixedWay)
              operate(result, c.payload, false)
              e.jump(finished)
              e.place(fixedWay)
              operate(result, c.payload, true)
            else:
              operate(result, c.payload, false)
            e.jump(finished)
            e.place(mixed)
            e.fastJumpIfNotZero(leftTag, promoteRight)
            e.fastMove(widened, b.payload)
            e.fastToFixed(widened, exit)
            e.fastMove(result, widened)
            operate(result, c.payload, true)
            e.jump(joined)
            e.place(promoteRight)
            e.fastMove(widened, c.payload)
            e.fastToFixed(widened, exit)
            e.fastMove(result, b.payload)
            operate(result, widened, true)
            e.place(joined)
            e.fastConstant(resultTag, FixedTag)
            e.place(finished)
            bindValue(slot(item.a), result, resultTag, UnknownKind)
        else:
          done = false
      of NegateOp:
        when ModelsFixed:
          makeRoom([slot(item.b)], 1)
          let value = fetch(slot(item.b), offset)
          let result = acquire()
          e.fastMove(result, value.payload)
          e.fastNegate(result)
          bindValue(slot(item.a), result, value.tag, value.kind)
        else:
          done = false
      of EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp,
          GreaterEqualOp:
        let left = slot(item.b)
        let right = slot(item.c)
        var known = 0
        for operand in [left, right]:
          let position = findHeld(operand)
          if position >= 0 and held[position].kind != UnknownKind:
            inc known
        makeRoom([left, right], 3 + known)
        let b = fetch(left, offset)
        let c = fetch(right, offset)
        var check = comparisonCheck(item.op)
        if (c.constant or b.constant) and not (b.constant and c.constant):
          # One side is a constant: compare the other against it directly,
          # turning the question round when the constant came first.
          let constantRight = c.constant
          let fixed = if constantRight: c else: b
          let other = if constantRight: b else: c
          if not constantRight:
            check = swapped(check)
          let bits = fixed.value
          let wideBits =
            if fixed.kind == FixedKind: int64(bits)
            else: int64(bits) * 65536
          let sameKind = e.label()
          let decided = e.label()
          if other.kind == fixed.kind:
            e.fastCompareConstant(other.payload, bits)
          else:
            let otherTag = tagOf(other)
            let wide = acquire()
            let bound = acquire()
            if fixed.kind == WholeKind:
              e.fastJumpIfZero(otherTag, sameKind)
            else:
              e.fastJumpIfNotZero(otherTag, sameKind)
            e.fastMove(wide, other.payload)
            e.fastScaleWide(wide, otherTag)
            e.fastLoadWide(bound, wideBits)
            e.fastCompareWide(wide, bound)
            e.jump(decided)
            e.place(sameKind)
            e.fastCompareConstant(other.payload, bits)
            e.place(decided)
        elif b.kind != UnknownKind and b.kind == c.kind:
          e.fastCompare(b.payload, c.payload)
        else:
          # Kinds that differ compare on the widened fixed-point scale.
          let leftTag = tagOf(b)
          let rightTag = tagOf(c)
          let wideLeft = acquire()
          let wideRight = acquire()
          let mixed = e.label()
          let decided = e.label()
          e.fastJumpIfDiffer(leftTag, rightTag, mixed)
          e.fastCompare(b.payload, c.payload)
          e.jump(decided)
          e.place(mixed)
          e.fastMove(wideLeft, b.payload)
          e.fastScaleWide(wideLeft, leftTag)
          e.fastMove(wideRight, c.payload)
          e.fastScaleWide(wideRight, rightTag)
          e.fastCompareWide(wideLeft, wideRight)
          e.place(decided)
        let result = acquire()
        e.fastAnswer(result, check)
        bindValue(slot(item.a), result, -1, WholeKind)
      of JumpOp:
        flushAll()
        e.jump(blocks[int(item.a)])
      of JumpIfZeroOp:
        makeRoom([slot(item.a)], 0)
        let value = fetch(slot(item.a), offset)
        flushAll()
        e.fastJumpIfZero(value.payload, blocks[int(item.b)])
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp:
        makeRoom([global(item.a)], 3)
        let value = fetch(global(item.a), offset)
        flushAll()
        if value.kind == WholeKind:
          e.fastCompareConstant(value.payload, item.b)
        else:
          # A fixed-point global meets the constant on the widened scale.
          let tag = tagOf(value)
          let wide = acquire()
          let bound = acquire()
          let whole = e.label()
          let decided = e.label()
          e.fastJumpIfZero(tag, whole)
          e.fastMove(wide, value.payload)
          e.fastScaleWide(wide, tag)
          e.fastLoadWide(bound, int64(item.b) * 65536)
          e.fastCompareWide(wide, bound)
          e.jump(decided)
          e.place(whole)
          e.fastCompareConstant(value.payload, item.b)
          e.place(decided)
        e.jumpOn(takenOn(item.op), blocks[int(item.c)])
      of ArrayGetOp:
        makeRoom([slot(item.c)], 2)
        let index = fetch(slot(item.c), offset)
        let exit = leaveHere(offset)
        requireWhole(index, slot(item.c), exit)
        e.fastCellAddress(index.payload, extents[int(item.b)], exit)
        let payload = acquire()
        let tag = acquire()
        e.fastLoad(payload, tag, cell(), exit)
        bindValue(slot(item.a), payload, tag, UnknownKind)
      of ArraySetOp:
        makeRoom([slot(item.b), slot(item.c)], 0)
        let index = fetch(slot(item.b), offset)
        let value = fetch(slot(item.c), offset)
        let exit = leaveHere(offset)
        requireWhole(index, slot(item.b), exit)
        e.fastCellAddress(index.payload, extents[int(item.a)], exit)
        e.fastStore(cell(), value.payload, value.tag, kindTag(value.kind))
      else:
        done = false
      for register in 0 ..< Pool.len:
        pinned[register] = false
      done

    template blockEnd(start: int): int =
      ## Returns the offset just past the block starting here.
      var stop = start + 1
      while stop < code.len and code[stop].op != MeterOp:
        inc stop
      stop

    template chainable(target: int): bool =
      ## Reports whether a block can be carried on into with values still
      ## held: an ordinary block, starting at its meter.
      target >= 0 and target < code.len and code[target].op == MeterOp and
        not inLoop[target]

    template emitFastBlock(start: int) =
      ## Emits one block's fast version, then its ways out.
      ##
      ## Where the block carries on into another, by falling through or by
      ## an unconditional jump, a copy of that one follows with every value
      ## still held, so nothing is written back or read again at the seam.
      ## Only this way in reaches the copy; the block's own fast version
      ## serves every other. A chain stops after a few blocks, at a block
      ## it has already taken in, and wherever general code took over.
      held.setLen(0)
      for register in 0 ..< Pool.len:
        uses[register] = 0
        pinned[register] = false
      var current = start
      var chained = @[start]
      while true:
        let stop = blockEnd(current)
        var handled = true
        var next = -1
        for at in current ..< stop:
          let item = code[at]
          if at == stop - 1 and item.op == JumpOp and
              chainable(int(item.a)) and int(item.a) notin chained and
              chained.len < MaxChain:
            next = int(item.a)
            break
          if emitFast(at):
            handled = true
          else:
            handled = false
            clearAll()
            emitInstruction(at, false, Loop(), @[], noExits)
        let last = code[stop - 1]
        if next < 0 and handled and fallsOnward(last.op) and
            chainable(stop) and stop notin chained and
            chained.len < MaxChain:
          next = stop
        if next < 0:
          if fallsOnward(last.op):
            flushAll()
            e.jump(blocks[stop])
          break
        chained.add(next)
        current = next
      for (exit, pending, offset) in fastExits:
        e.place(exit)
        for value in pending:
          writeBack(value)
        e.jump(general[offset])
      fastExits.setLen(0)
      if stubs.len > 0:
        for stub in stubs:
          e.place(stub.label)
          e.callSlow(stub.offset, slowLabel)
          case stub.carry
          of ToNext:
            e.jump(blocks[int(stub.offset) + 1])
          of ToOffset:
            e.jump(dispatchLabel)
        stubs.setLen(0)

    var index = 0
    while index < code.len:
      var stop = index + 1
      while stop < code.len and code[stop].op != MeterOp:
        inc stop
      if code[index].op == MeterOp and not inLoop[index]:
        e.place(blocks[index])
        emitFastBlock(index)
        e.place(general[index])
        for at in index ..< stop:
          if at > index:
            e.place(blocks[at])
          emitInstruction(at, false, Loop(), @[], noExits)
      else:
        for at in index ..< stop:
          e.place(blocks[at])
          let number = loopAt[at]
          if number >= 0:
            # Entering a loop's head: prove its globals whole numbers and
            # move them into registers, or run it in general code if any
            # is not. Every tag is looked at before any register is
            # filled, because one of those registers may be what general
            # code reads through.
            let loop = loops[number]
            e.beginHoisting()
            for which in loop.globals:
              e.guardHoisted(which, general[loop.start])
            for position, which in loop.globals:
              e.loadHoisted(position, which)
            e.jump(loopCopies[number][0])
            e.place(general[at])
          emitInstruction(at, false, Loop(), @[], noExits)
      index = stop

    # Each loop's own copy, after all the general code.
    for number, loop in loops:
      var exits: seq[(Label, int, bool)]
      let inside = loopCopies[number]
      for index in loop.start ..< loop.stop:
        e.place(inside[index - loop.start])
        emitInstruction(index, true, loop, inside, exits)
      # Leaving writes every register back, then carries on in general
      # code: at a branch target, or at the instruction that could not be
      # done here, which general code then does the ordinary way.
      for (stub, target, again) in exits:
        e.place(stub)
        e.beginHoisting()
        for position, which in loop.globals:
          e.storeHoisted(position, which)
        e.endHoisting()
        if again:
          e.jump(general[target])
        else:
          e.jump(blocks[target])

    # One past the end holds nothing to run. The interpreter's code is
    # left to refuse it the way it would.
    e.place(blocks[code.len])
    e.callSlow(int32(code.len), slowLabel)
    e.jump(dispatchLabel)

    e.place(dispatchLabel)
    e.dispatch()
    e.place(slowLabel)
    e.slowRoutine(failedLabel, ContextStep)
    e.place(hostLabel)
    e.slowRoutine(failedLabel, ContextHostStep)
    # The interpreter's code answers with the status to leave with: a
    # failure it raised, or the compiled program retired part way.
    e.place(failedLabel)
    e.leaveWithAnswer()

    let bytes = e.finish()
    var starts = newSeq[int](code.len + 1)
    for index in 0 .. code.len:
      starts[index] = e.offsetBytes(blocks[index])
    (bytes, starts)

proc compileProgram*(code: seq[Instruction], routines: seq[RoutineExtent],
    extents: seq[ArrayExtent], constants: seq[int32], globals, hostData,
    arguments: int, limits: CallLimits, strings = false,
    queries: seq[bool] = @[]): Machine
    {.raises: [BasicError].} =
  ## Compiles every offset of a program to machine code, or returns nil
  ## when this target has no backend or the program is outside what the
  ## generator is sure of. Generated code indexes storage without
  ## checking, so every index it will use is proved in range here first.
  when not (NativeArm64 or NativeAmd64):
    return nil
  else:
    if not layoutMatches() or code.len == 0 or routines.len == 0:
      return nil
    # Writing code pages from a thread that is running compiled code would
    # open the write gate beneath live frames, so such a compile is
    # refused and the program runs on the interpreter instead.
    if runningCompiledCode():
      return nil
    if limits.frames <= 0 or limits.slots < 0:
      return nil
    # Every value is reached through a displacement worked out here, so
    # each store of values must end where one of thirty-two bits still
    # reaches, whichever architecture this is.
    const Reachable = (int(high(int32)) - ValueStride) div ValueStride
    if globals > Reachable or hostData > Reachable or
        arguments > Reachable or int(limits.slots) > Reachable:
      return nil

    # Every offset belongs to exactly one routine, and none runs on into
    # the next, so the routine an instruction runs in is known here.
    var ownerOf = newSeq[int32](code.len)
    for index in 0 ..< ownerOf.len:
      ownerOf[index] = -1
    for id, routine in routines:
      if routine.entry < 0 or routine.length <= 0 or
          int(routine.entry) + int(routine.length) > code.len:
        return nil
      if routine.registers < 0 or int(routine.registers) > Reachable or
          routine.parameters < 0 or
          routine.parameters > routine.registers or
          routine.parameters > int32(arguments):
        return nil
      for step in 0 ..< int(routine.length):
        let offset = int(routine.entry) + step
        if ownerOf[offset] >= 0:
          return nil
        ownerOf[offset] = int32(id)
      let last = code[int(routine.entry) + int(routine.length) - 1]
      if last.op notin Terminators:
        return nil
    for index in 0 ..< code.len:
      if ownerOf[index] < 0:
        return nil

    for index, item in code:
      let owner = routines[int(ownerOf[index])]
      template requireSlot(value: int32) =
        if value < 0 or value >= owner.registers:
          return nil
      template requireGlobal(value: int32) =
        if value < 0 or int(value) >= globals:
          return nil
      template requireArray(value: int32) =
        if value < 0 or int(value) >= extents.len:
          return nil
        let extent = extents[int(value)]
        if extent.base < 0 or extent.length < 0 or
            int(extent.base) + int(extent.length) > Reachable:
          return nil
      template requireHost(value: int32) =
        if value < 0 or int(value) >= hostData:
          return nil
      template requireArgument(value: int32) =
        if value < 0 or int(value) >= arguments:
          return nil
      template requireTarget(value: int32) =
        if value < 0 or int(value) >= code.len or
            ownerOf[int(value)] != ownerOf[index]:
          return nil
      case item.op
      of MeterOp:
        if item.a < 0 or item.b < 0:
          return nil
      of HostCallOp:
        if item.a >= 0:
          requireSlot(item.a)
        if item.b < 0 or (queries.len > 0 and int(item.b) >= queries.len):
          return nil
      of TextCallOp:
        requireSlot(item.a)
        if item.c < 1 or int(item.c) > arguments:
          return nil
      of LoadImmediateOp:
        requireSlot(item.a)
      of LoadFixedOp:
        requireSlot(item.a)
        if item.b < 0 or int(item.b) >= constants.len:
          return nil
      of MoveOp, NegateOp, NotOp:
        requireSlot(item.a)
        requireSlot(item.b)
      of LoadGlobalOp:
        requireSlot(item.a)
        requireGlobal(item.b)
      of LoadHostDataOp:
        requireSlot(item.a)
        requireHost(item.b)
      of StoreGlobalOp:
        requireGlobal(item.a)
        requireSlot(item.b)
      of StoreGlobalImmediateOp, AddGlobalImmediateOp:
        requireGlobal(item.a)
      of MoveGlobalOp, AddGlobalOp, ModuloGlobalImmediateOp:
        requireGlobal(item.a)
        requireGlobal(item.b)
      of AddGlobalHostDataOp:
        requireGlobal(item.a)
        requireHost(item.b)
      of AddGlobalRegisterOp:
        requireGlobal(item.a)
        requireSlot(item.b)
      of AddGlobalArrayGlobalIndexOp:
        requireGlobal(item.a)
        requireArray(item.b)
        requireGlobal(item.c)
      of ArrayAddGlobalsOp:
        requireArray(item.a)
        requireGlobal(item.b)
        requireGlobal(item.c)
      of AddOp, SubtractOp, MultiplyOp, DivideOp, IntegerDivideOp,
          ModuloOp, EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp,
          GreaterEqualOp, AndOp, OrOp, XorOp, EqvOp, ImpOp:
        requireSlot(item.a)
        requireSlot(item.b)
        requireSlot(item.c)
      of JumpOp, GosubOp, ReturnLabelOp:
        requireTarget(item.a)
      of JumpIfZeroOp:
        requireSlot(item.a)
        requireTarget(item.b)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp,
          JumpUnlessGlobalModuloEqualZeroOp:
        requireGlobal(item.a)
        requireTarget(item.c)
      of ArrayGetOp:
        requireSlot(item.a)
        requireArray(item.b)
        requireSlot(item.c)
      of ArraySetOp:
        requireArray(item.a)
        requireSlot(item.b)
        requireSlot(item.c)
      of SetArgumentOp:
        requireArgument(item.a)
        requireSlot(item.b)
      of SetArgumentImmediateOp:
        requireArgument(item.a)
      of SetArgumentGlobalOp:
        requireArgument(item.a)
        requireGlobal(item.b)
      of CallOp:
        if item.a <= 0 or int(item.a) >= routines.len:
          return nil
      else:
        discard
      if item.op in {CallOp, GosubOp} and index + 1 >= code.len:
        return nil

    var emitted: (seq[byte], seq[int])
    try:
      emitted = emitProgram(code, routines, ownerOf, extents, constants,
        limits, false, strings, queries)
    except BasicError:
      # Some branch could not reach; every branch then goes the long way.
      # Should that fail too, the program is left to the interpreter.
      try:
        emitted = emitProgram(code, routines, ownerOf, extents, constants,
          limits, true, strings, queries)
      except BasicError:
        return nil
    let (bytes, starts) = emitted
    if bytes.len > MaxProgramBytes:
      return nil

    result = Machine(size: bytes.len, listing: bytes)
    result.buffer = initCodeBuffer(bytes.len)
    result.buffer.write(bytes)
    result.buffer.seal()
    result.call = cast[NativeCall](result.buffer.entry)
    let origin = cast[int](result.buffer.entry)
    result.table = newSeq[pointer](code.len + 1)
    for index in 0 .. code.len:
      result.table[index] = cast[pointer](origin + starts[index])

proc tableAddress*(machine: Machine): pointer {.raises: [].} =
  ## Returns the table of native addresses indexed by bytecode offset.
  machine.table[0].addr
