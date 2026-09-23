## Compiles hot integer loops from the register bytecode to machine code.
##
## A region is one backward-branching loop whose every operation is an
## integer operation on global variables. On entry the compiled code proves
## each participating global still holds an integer, hoists it into a
## machine register, and from then on runs without tags, without memory
## traffic, and without dispatch. Any operation the compiler does not
## model, and any value that is not an integer, leaves the loop to the
## interpreter, so the two always agree on results and on budgets.
##
## The region walker below is written once. Each architecture supplies the
## same small set of emitters, so AArch64 and x86-64 stay in step.

import
  bytecode, machine, numbers

export machine.jitSupported

const
  NativeArm64* = NativeCode and defined(arm64)
  NativeAmd64* = NativeCode and defined(amd64)

when NativeArm64:
  import arm64
elif NativeAmd64:
  import amd64

type
  NativeStatus* = enum
    ## Why compiled code returned control to the interpreter.
    NativeCompleted,
    NativeGuardFailed,
    NativeExhausted

  NativeContext* = object
    ## The mutable interpreter state compiled code is allowed to touch.
    ## The register field points at the current frame's first slot, which
    ## cannot move while a region runs because a region contains no call.
    globals*: pointer
    remainingInstructions*: int64
    remainingWork*: int64
    pc*: int32
    registers*: pointer
    memory*: pointer
    hostData*: pointer

  NativeCall = proc(context: ptr NativeContext): int32
    {.cdecl, gcsafe, raises: [].}

  ArrayExtent* = object
    ## Where one array sits in the shared cell storage, and how long it is.
    base*: int32
    length*: int32

  Region* = ref object
    ## One compiled loop, addressed by the bytecode offset that enters it.
    start*: int32
    stop*: int32
    hoisted*: seq[int32]
    size*: int
    listing*: seq[byte]
    buffer: CodeBuffer
    call: NativeCall

  Test = enum
    ## An architecture-neutral branch condition.
    EqualTest,
    NotEqualTest,
    LessTest,
    LessEqualTest,
    GreaterTest,
    GreaterEqualTest

const
  ValueStride = 16
  ValuePayload = 8
  ContextInstructions = 8
  ContextWork = 16
  ContextOffset = 24
  ContextRegisters = 32
  ContextMemory = 40
  ContextHostData = 48
  MaxHoistedGlobals* = 7
  MaxRegionBytes = 32 * 1024
  MaxChargeImmediate = 4095
  FixedTag = 1
  FixedShift = 16
  FixedRounding = 1'i64 shl (FixedShift - 1)

  ## Fixed-point values are only modelled when overflow is allowed to
  ## wrap. Under fixedChecks the interpreter asserts instead, and nothing
  ## here would assert with it.
  ModelsFixed* = not defined(fixedChecks)
  MaxDisplacementBytes = int(high(int32))

proc fail(message: string) {.noreturn, raises: [BasicError].} =
  ## Reports a controlled native compilation failure.
  raise newException(BasicError, "BASIC " & message)

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
  # An integer must be tagged zero, because the guard tests for zero, and
  # a fixed-point number must not be, or the guard would let one through.
  if image[0] != byte(ord(IntegerValue)):
    return false
  if image[ValueStride] == byte(ord(IntegerValue)):
    return false
  var payload = 0'i32
  copyMem(payload.addr, image[ValuePayload].addr, sizeof(int32))
  if payload != 0x5A6B7C0D'i32:
    return false
  var context: NativeContext
  let origin = cast[int](context.addr)
  if cast[int](context.remainingInstructions.addr) - origin !=
      ContextInstructions:
    return false
  if cast[int](context.remainingWork.addr) - origin != ContextWork:
    return false
  if cast[int](context.pc.addr) - origin != ContextOffset:
    return false
  if cast[int](context.registers.addr) - origin != ContextRegisters:
    return false
  if cast[int](context.memory.addr) - origin != ContextMemory:
    return false
  if cast[int](context.hostData.addr) - origin != ContextHostData:
    return false
  true

## Region discovery

proc isCompilable(item: Instruction): bool {.raises: [].} =
  ## Reports whether one operation has a modelled integer translation.
  case item.op
  of MeterOp, JumpOp, StoreGlobalImmediateOp, MoveGlobalOp,
      AddGlobalImmediateOp, AddGlobalOp,
      LoadImmediateOp, MoveOp, LoadGlobalOp, StoreGlobalOp,
      AddOp, SubtractOp, MultiplyOp, NegateOp,
      EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp, GreaterEqualOp,
      JumpIfZeroOp,
      IntegerDivideOp,
      LoadFixedOp, LoadHostDataOp, AddGlobalHostDataOp,
      AddGlobalRegisterOp, ModuloGlobalImmediateOp,
      ArrayGetOp, ArraySetOp, ArrayAddGlobalsOp,
      AddGlobalArrayGlobalIndexOp,
      JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp:
    true
  of ModuloOp:
    true
  of JumpUnlessGlobalModuloEqualZeroOp:
    # The interpreter raises on a zero divisor; refuse rather than model it.
    item.b != 0
  else:
    false

proc touchedGlobals(item: Instruction, globals: var seq[int32])
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
      JumpUnlessGlobalModuloEqualZeroOp:
    note(item.a)
  of MoveGlobalOp, AddGlobalOp:
    note(item.a)
    note(item.b)
  of LoadGlobalOp:
    note(item.b)
  of StoreGlobalOp:
    note(item.a)
  of AddGlobalHostDataOp, AddGlobalRegisterOp:
    note(item.a)
  of ModuloGlobalImmediateOp:
    note(item.a)
    note(item.b)
  of ArrayAddGlobalsOp:
    note(item.b)
    note(item.c)
  of AddGlobalArrayGlobalIndexOp:
    note(item.a)
    note(item.c)
  else:
    discard

proc branchTarget(item: Instruction, target: var int32): bool
    {.raises: [].} =
  ## Reports whether an operation branches, and to where.
  case item.op
  of JumpOp:
    target = item.a
    true
  of JumpIfZeroOp:
    target = item.b
    true
  of JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp,
      JumpUnlessGlobalModuloEqualZeroOp:
    target = item.c
    true
  else:
    false

proc touchedSlots(item: Instruction, slots: var seq[int32])
    {.raises: [].} =
  ## Records every register slot one operation reads or writes.
  template note(index: int32) =
    slots.add(index)
  case item.op
  of LoadImmediateOp, LoadGlobalOp:
    note(item.a)
  of StoreGlobalOp, NegateOp, JumpIfZeroOp:
    note(item.b)
  of MoveOp:
    note(item.a)
    note(item.b)
  of AddOp, SubtractOp, MultiplyOp, ModuloOp, IntegerDivideOp,
      EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp, GreaterEqualOp:
    note(item.a)
    note(item.b)
    note(item.c)
  of LoadFixedOp, LoadHostDataOp:
    note(item.a)
  of AddGlobalRegisterOp:
    note(item.b)
  of ArrayGetOp:
    note(item.a)
    note(item.c)
  of ArraySetOp:
    note(item.b)
    note(item.c)
  else:
    discard
  if item.op == NegateOp:
    note(item.a)

proc namedArray(item: Instruction, id: var int32): bool {.raises: [].} =
  ## Reports whether an operation reaches into an array, and which one.
  case item.op
  of ArrayGetOp, AddGlobalArrayGlobalIndexOp:
    id = item.b
    true
  of ArraySetOp, ArrayAddGlobalsOp:
    id = item.a
    true
  else:
    false

proc usesRegisterFile(item: Instruction): bool {.raises: [].} =
  ## Reports whether an operation reaches into the frame's slots.
  var slots: seq[int32]
  item.touchedSlots(slots)
  slots.len > 0

proc comparisonTest(op: Op): Test {.raises: [].} =
  ## Returns the condition a comparison answers true on.
  case op
  of EqualOp: EqualTest
  of NotEqualOp: NotEqualTest
  of LessOp: LessTest
  of LessEqualOp: LessEqualTest
  of GreaterOp: GreaterTest
  else: GreaterEqualTest

proc takenOn(op: Op): Test {.raises: [].} =
  ## Returns the condition on which a fused test takes its branch.
  case op
  of JumpUnlessGlobalEqualImmediateOp: NotEqualTest
  of JumpUnlessGlobalNotEqualImmediateOp: EqualTest
  of JumpUnlessGlobalLessImmediateOp: GreaterEqualTest
  of JumpUnlessGlobalLessEqualImmediateOp: GreaterTest
  of JumpUnlessGlobalGreaterImmediateOp: LessEqualTest
  of JumpUnlessGlobalGreaterEqualImmediateOp: LessTest
  else: NotEqualTest

type
  LoopPlan = object
    ## What one pass through a loop costs, when that is knowable.
    ##
    ## A loop whose body has no internal branch runs the same operations
    ## every time around, so its budget can be settled once on entry
    ## instead of at every block. The counter below then replaces both
    ## budget checks, and the interpreter is handed back a count to charge.
    counted: bool
    spending: bool
    instructions: int64
    work: int64
    passInstructions: int64
    passWork: int64
    partialInstructions: seq[int64]
    partialWork: seq[int64]
    checkpoints: seq[bool]

proc planLoop(code: seq[Instruction], start, stop: int): LoopPlan
    {.raises: [].} =
  ## Measures one pass through a loop and reports whether it is countable.
  result.partialInstructions = newSeq[int64](stop - start)
  result.partialWork = newSeq[int64](stop - start)
  result.checkpoints = newSeq[bool](stop - start)
  if stop - start < 2:
    return
  let last = code[stop - 1]
  if last.op != JumpOp or int(last.a) != start:
    return
  if code[start].op != MeterOp:
    return
  # Every meter in the region bounds what a single pass can cost, however
  # the branches inside it fall.
  for index in start ..< stop:
    if code[index].op == MeterOp:
      result.passInstructions += int64(code[index].b)
      result.passWork += int64(code[index].a)

  # Every backward branch is a place the spending must be looked at. An
  # inner loop turning under an outer one would otherwise run as long as
  # it liked between two looks, because the outer header is only reached
  # once for however many times the inner one goes round. What runs
  # between two checks then contains no backward branch, so it can charge
  # no more than one pass, which is what the limit is set against.
  result.checkpoints[0] = true
  for index in start ..< stop:
    var target = 0'i32
    if code[index].branchTarget(target):
      if int(target) >= start and int(target) <= index:
        result.checkpoints[int(target) - start] = true
  for offset, wanted in result.checkpoints:
    if wanted and code[start + offset].op != MeterOp:
      # Nowhere to put the look, so this loop keeps the per-block check.
      return
  # Every pass runs the meter at the loop head, so charging at least one
  # instruction there is what stops a pass from spending nothing and
  # looping for ever against an unmoving total.
  result.spending = result.passInstructions > 0 and result.passWork > 0 and
    code[start].b > 0
  for index in start ..< stop:
    if code[index].op == MeterOp:
      if code[index].b < 0 or code[index].b > MaxChargeImmediate or
          code[index].a < 0 or code[index].a > MaxChargeImmediate:
        result.spending = false
  var
    instructions = 0'i64
    work = 0'i64
  for index in start ..< stop:
    let item = code[index]
    result.partialInstructions[index - start] = instructions
    result.partialWork[index - start] = work
    if item.op == MeterOp:
      instructions += int64(item.b)
      work += int64(item.a)
    var target = 0'i32
    if item.branchTarget(target):
      if index == stop - 1:
        continue
      # Any branch back into the loop means the cost of a pass depends on
      # which way it went, so the count would not be a count.
      if int(target) >= start and int(target) < stop:
        return
  if instructions <= 0 or work <= 0:
    return
  result.instructions = instructions
  result.work = work
  result.counted = true

proc pooledConstants(code: seq[Instruction], start, stop, room: int):
    seq[int64] {.raises: [].} =
  ## Collects the compare constants worth holding in a register, which are
  ## the ones too wide for an immediate and so rebuilt on every pass.
  for index in start ..< stop:
    let item = code[index]
    case item.op
    of JumpUnlessGlobalEqualImmediateOp,
        JumpUnlessGlobalNotEqualImmediateOp,
        JumpUnlessGlobalLessImmediateOp,
        JumpUnlessGlobalLessEqualImmediateOp,
        JumpUnlessGlobalGreaterImmediateOp,
        JumpUnlessGlobalGreaterEqualImmediateOp:
      if item.b >= 0 and item.b <= 4095:
        continue
      let value = int64(item.b)
      if value notin result and result.len < room:
        result.add(value)
    else:
      discard

proc anyTarget(item: Instruction, target: var int32): bool {.raises: [].} =
  ## Reports where an operation can send control, for every operation that
  ## can send it anywhere. This is wider than the set the code generator
  ## models: a subroutine call or a register test the generator refuses to
  ## compile can still name an offset inside a loop it did compile.
  case item.op
  of JumpOp, GosubOp, ReturnLabelOp:
    target = item.a
    true
  of JumpIfZeroOp:
    target = item.b
    true
  else:
    item.branchTarget(target)

proc reachesOutside(code: seq[Instruction], start, stop: int): bool
    {.raises: [].} =
  ## Reports whether the loop can be entered anywhere but its first offset.
  ## Compiled code proves its globals are integers and loads them into
  ## registers on the way in, so arriving anywhere else would skip the
  ## proof and read registers that were never filled.
  for index in 0 ..< code.len:
    if index >= start and index < stop:
      continue
    var target = 0'i32
    if code[index].anyTarget(target):
      if int(target) > start and int(target) < stop:
        return true
  false

when NativeArm64:
  ## AArch64 code generation
  ##
  ## x0   context pointer, live for the whole region
  ## x19  base of the globals array
  ## x20  remaining instruction budget
  ## x21  remaining work budget
  ## x22+ hoisted globals, one per entry in the region's list
  ## x9, x10  scratch;  x11, x12  resume offset and status

  const
    Context = x0
    GlobalsBase = x19
    Instructions = x20
    Work = x21
    FirstHoisted = 22
    Scratch = x9
    OtherScratch = x10
    ResumeOffset = x11
    ResumeStatus = x12
    Counter = x13
    Allowance = x14
    RegistersBase = x15
    ValueScratch = [x16, x17]
    SpentInstructions = x5
    SpentWork = x6
    LimitInstructions = x7
    LimitWork = x8
    FirstPooled = 1
    FrameBytes = 96
    MaxDisplacement = 4095

  const MaxPooled* = 4

  proc pooledRegister(slot: int): Register {.raises: [].} =
    ## Returns the caller-saved register holding one hoisted constant.
    Register(uint32(FirstPooled + slot))

  proc loadPooled(emitter: var Assembler, slot: int, value: int64)
      {.raises: [BasicError].} =
    ## Materializes a loop-invariant constant once, before the loop.
    emitter.loadImmediate(Word32, pooledRegister(slot), value)

  proc slotRegister(slot: int): Register {.raises: [].} =
    ## Returns the callee-saved register holding one hoisted global.
    Register(uint32(FirstHoisted + slot))

  proc nativeCondition(test: Test): Condition {.raises: [].} =
    ## Maps a neutral condition onto the architecture's encoding.
    case test
    of EqualTest: EqualCondition
    of NotEqualTest: NotEqualCondition
    of LessTest: LessCondition
    of LessEqualTest: LessEqualCondition
    of GreaterTest: GreaterCondition
    of GreaterEqualTest: GreaterEqualCondition

  proc branchWhen(emitter: var Assembler, test: Test, target: Label)
      {.raises: [].} =
    ## Branches when the neutral condition holds.
    emitter.branchIf(nativeCondition(test), target)

  proc startRegion(emitter: var Assembler) {.raises: [BasicError].} =
    ## Saves callee-saved registers and loads the interpreter state.
    emitter.storePair(
      framePointer, linkRegister, stackPointer, -FrameBytes, true
    )
    emitter.storePair(x19, x20, stackPointer, 16)
    emitter.storePair(x21, x22, stackPointer, 32)
    emitter.storePair(x23, x24, stackPointer, 48)
    emitter.storePair(x25, x26, stackPointer, 64)
    emitter.storePair(x27, x28, stackPointer, 80)
    emitter.loadDouble(GlobalsBase, Context, 0)
    emitter.loadDouble(Instructions, Context, ContextInstructions)
    emitter.loadDouble(Work, Context, ContextWork)

  proc endRegion(emitter: var Assembler) {.raises: [BasicError].} =
    ## Restores callee-saved registers and returns to the interpreter.
    emitter.loadPair(x19, x20, stackPointer, 16)
    emitter.loadPair(x21, x22, stackPointer, 32)
    emitter.loadPair(x23, x24, stackPointer, 48)
    emitter.loadPair(x25, x26, stackPointer, 64)
    emitter.loadPair(x27, x28, stackPointer, 80)
    emitter.loadPair(
      framePointer, linkRegister, stackPointer, FrameBytes, true
    )
    emitter.returnToCaller()

  proc guardInteger(emitter: var Assembler, base: int, failed: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless the global at this offset holds an integer.
    emitter.loadByte(Scratch, GlobalsBase, base)
    emitter.branchIfNotZero(Word32, Scratch, failed)

  proc loadHoisted(emitter: var Assembler, slot: int, base: int)
      {.raises: [BasicError].} =
    ## Reads one global into its register.
    emitter.loadWord(slotRegister(slot), GlobalsBase, base + ValuePayload)

  proc storeHoisted(emitter: var Assembler, slot: int, base: int)
      {.raises: [BasicError].} =
    ## Publishes one register back as an integer value.
    emitter.storeByte(zeroRegister, GlobalsBase, base)
    emitter.storeWord(slotRegister(slot), GlobalsBase, base + ValuePayload)

  proc setSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
    ## Loads a constant into a hoisted register.
    emitter.loadImmediate(Word32, slotRegister(slot), int64(value))

  proc copySlot(emitter: var Assembler, destination, source: int)
      {.raises: [BasicError].} =
    ## Copies one hoisted register into another.
    emitter.moveRegister(
      Word32, slotRegister(destination), slotRegister(source)
    )

  proc addSlots(emitter: var Assembler, destination, source: int)
      {.raises: [BasicError].} =
    ## Adds one hoisted register into another, wrapping on overflow.
    let target = slotRegister(destination)
    emitter.addRegister(Word32, target, target, slotRegister(source))

  proc addToSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
    ## Adds a constant to a hoisted register, wrapping on overflow.
    let target = slotRegister(slot)
    if value >= 0 and value <= MaxDisplacement:
      emitter.addImmediate(Word32, target, target, int(value))
    elif value < 0 and value >= -MaxDisplacement:
      emitter.subtractImmediate(Word32, target, target, int(-value))
    else:
      emitter.loadImmediate(Word32, Scratch, int64(value))
      emitter.addRegister(Word32, target, target, Scratch)

  proc compareSlot(emitter: var Assembler, slot: int, value: int32,
      pooled = -1) {.raises: [BasicError].} =
    ## Sets flags from a hoisted register against a constant, using the
    ## register that already holds it when the loop has one.
    let target = slotRegister(slot)
    if pooled >= 0:
      emitter.compareRegister(Word32, target, pooledRegister(pooled))
    elif value >= 0 and value <= MaxDisplacement:
      emitter.compareImmediate(Word32, target, int(value))
    else:
      emitter.loadImmediate(Word32, Scratch, int64(value))
      emitter.compareRegister(Word32, target, Scratch)

  proc loadRegistersBase(emitter: var Assembler) {.raises: [BasicError].} =
    ## Points at the first slot of the frame the region runs in.
    emitter.loadDouble(RegistersBase, Context, ContextRegisters)

  proc readSlot(emitter: var Assembler, scratch: int, slot: int32,
      leave: Label) {.raises: [BasicError].} =
    ## Reads one register slot as an integer, leaving the region if it
    ## holds anything else. The tag is read into the same register the
    ## value will land in, so no third register is needed.
    let target = ValueScratch[scratch]
    let base = int(slot) * ValueStride
    emitter.loadByte(target, RegistersBase, base)
    emitter.branchIfNotZero(Word32, target, leave)
    emitter.loadWord(target, RegistersBase, base + ValuePayload)

  proc writeSlot(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Writes one register slot as an integer.
    let base = int(slot) * ValueStride
    emitter.storeByte(zeroRegister, RegistersBase, base)
    emitter.storeWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc setScratch(emitter: var Assembler, scratch: int, value: int32)
      {.raises: [BasicError].} =
    ## Loads a constant into a working register.
    emitter.loadImmediate(Word32, ValueScratch[scratch], int64(value))

  proc addScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Adds the second working register into the first, wrapping.
    emitter.addRegister(Word32, ValueScratch[left], ValueScratch[left],
      ValueScratch[right])

  proc subtractScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Subtracts the second working register from the first, wrapping.
    emitter.subtractRegister(Word32, ValueScratch[left], ValueScratch[left],
      ValueScratch[right])

  proc multiplyScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Multiplies the first working register by the second, wrapping.
    emitter.multiply(Word32, ValueScratch[left], ValueScratch[left],
      ValueScratch[right])

  proc negateScratch(emitter: var Assembler, scratch: int)
      {.raises: [BasicError].} =
    ## Replaces a working register with its negation, wrapping.
    emitter.negate(Word32, ValueScratch[scratch], ValueScratch[scratch])

  proc compareScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Sets flags from two working registers.
    emitter.compareRegister(Word32, ValueScratch[left], ValueScratch[right])

  proc answerCondition(emitter: var Assembler, scratch: int, test: Test)
      {.raises: [BasicError].} =
    ## Writes BASIC's -1 for true and zero for false.
    emitter.setOnCondition(Word32, ValueScratch[scratch],
      nativeCondition(test))

  proc scratchFromHoisted(emitter: var Assembler, scratch, slot: int)
      {.raises: [BasicError].} =
    ## Copies a hoisted global into a working register.
    emitter.moveRegister(Word32, ValueScratch[scratch], slotRegister(slot))

  proc hoistedFromScratch(emitter: var Assembler, slot, scratch: int)
      {.raises: [BasicError].} =
    ## Copies a working register into a hoisted global.
    emitter.moveRegister(Word32, slotRegister(slot), ValueScratch[scratch])

  proc branchIfScratchZero(emitter: var Assembler, scratch: int,
      target: Label) {.raises: [BasicError].} =
    ## Branches when a working register holds zero.
    emitter.branchIfZero(Word32, ValueScratch[scratch], target)

  proc readNumeric(emitter: var Assembler, scratch: int, slot: int32,
      leave: Label) {.raises: [BasicError].} =
    ## Reads a slot's tag into Scratch and its payload into a working
    ## register, leaving the region for anything that is not a number.
    let base = int(slot) * ValueStride
    emitter.loadByte(Scratch, RegistersBase, base)
    emitter.compareImmediate(Word32, Scratch, FixedTag)
    emitter.branchIf(UnsignedGreaterCondition, leave)
    emitter.loadWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc requireSameKind(emitter: var Assembler, slot: int32, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless a second slot carries the same tag as the
    ## one already held. Whole numbers and fixed-point ones add, subtract
    ## and compare through the very same instructions, so a pair that
    ## agrees needs no further telling apart; a mixed pair would have to
    ## be promoted, which can fail, so it goes back to the interpreter.
    emitter.loadByte(OtherScratch, RegistersBase, int(slot) * ValueStride)
    emitter.compareRegister(Word32, Scratch, OtherScratch)
    emitter.branchIf(NotEqualCondition, leave)

  proc writeNumeric(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Writes a payload back under the tag the operands carried.
    let base = int(slot) * ValueStride
    emitter.storeByte(Scratch, RegistersBase, base)
    emitter.storeWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc branchIfFixed(emitter: var Assembler, target: Label)
      {.raises: [BasicError].} =
    ## Branches when the held tag says fixed point.
    emitter.compareImmediate(Word32, Scratch, FixedTag)
    emitter.branchIf(EqualCondition, target)

  proc requireWholeKind(emitter: var Assembler, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless the held tag says whole number.
    emitter.compareImmediate(Word32, Scratch, 0)
    emitter.branchIf(NotEqualCondition, leave)

  proc readSlotValue(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Reads a slot's payload, its tag having already been established.
    emitter.loadWord(ValueScratch[scratch], RegistersBase,
      int(slot) * ValueStride + ValuePayload)

  proc guardDivisor(emitter: var Assembler, scratch: int, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region for the two divisors that are not plain division:
    ## zero, which the interpreter refuses, and minus one, which the other
    ## architecture traps on.
    emitter.compareImmediate(Word32, ValueScratch[scratch], 0)
    emitter.branchIf(EqualCondition, leave)
    emitter.loadImmediate(Word32, OtherScratch, -1)
    emitter.compareRegister(Word32, ValueScratch[scratch], OtherScratch)
    emitter.branchIf(EqualCondition, leave)

  proc quotientScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Divides the first working register by the second, toward zero.
    emitter.signedDivide(Word32, ValueScratch[left], ValueScratch[left],
      ValueScratch[right])

  proc remainderScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Leaves what the division of the two working registers left over.
    emitter.signedDivide(Word32, OtherScratch, ValueScratch[left],
      ValueScratch[right])
    emitter.multiplySubtract(Word32, ValueScratch[left], OtherScratch,
      ValueScratch[right], ValueScratch[left])

  proc multiplyFixed(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Multiplies two Q16.16 numbers through a widened intermediate,
    ## rounding to nearest exactly as the fixed-point library does.
    emitter.signedMultiplyLong(OtherScratch, ValueScratch[left],
      ValueScratch[right])
    emitter.loadImmediate(Word64, ValueScratch[right], FixedRounding)
    emitter.addRegister(Word64, OtherScratch, OtherScratch,
      ValueScratch[right])
    emitter.arithmeticShiftRight(Word64, OtherScratch, OtherScratch,
      FixedShift)
    emitter.moveRegister(Word32, ValueScratch[left], OtherScratch)

  proc elementAddress(emitter: var Assembler, scratch: int,
      extent: ArrayExtent, leave: Label) {.raises: [BasicError].} =
    ## Bounds checks an index and leaves the cell's address in Scratch.
    ## One unsigned comparison covers both ends, exactly as the
    ## interpreter's does, and a refusal hands the offset back so the
    ## interpreter can raise with the array's own name.
    let index = ValueScratch[scratch]
    emitter.loadImmediate(Word32, OtherScratch, int64(extent.length))
    emitter.compareRegister(Word32, index, OtherScratch)
    emitter.branchIf(CarrySetCondition, leave)
    emitter.loadImmediate(Word32, OtherScratch, int64(extent.base))
    emitter.addRegister(Word32, OtherScratch, OtherScratch, index)
    emitter.loadDouble(Scratch, Context, ContextMemory)
    emitter.addRegister(Word64, Scratch, Scratch, OtherScratch, 4)

  proc copyElementToSlot(emitter: var Assembler, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a whole cell into a register slot, whatever it holds. The
    ## interpreter copies the value entire, so this does too, and neither
    ## needs to know what kind it is.
    let base = int(slot) * ValueStride
    emitter.loadDouble(ValueScratch[0], Scratch, 0)
    emitter.loadDouble(ValueScratch[1], Scratch, ValuePayload)
    emitter.storeDouble(ValueScratch[0], RegistersBase, base)
    emitter.storeDouble(ValueScratch[1], RegistersBase, base + ValuePayload)

  proc copySlotToElement(emitter: var Assembler, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a whole register slot into a cell, whatever it holds.
    let base = int(slot) * ValueStride
    emitter.loadDouble(ValueScratch[0], RegistersBase, base)
    emitter.loadDouble(ValueScratch[1], RegistersBase, base + ValuePayload)
    emitter.storeDouble(ValueScratch[0], Scratch, 0)
    emitter.storeDouble(ValueScratch[1], Scratch, ValuePayload)

  proc readElement(emitter: var Assembler, scratch: int, leave: Label)
      {.raises: [BasicError].} =
    ## Reads a cell as an integer, leaving the region if it holds else.
    let target = ValueScratch[scratch]
    emitter.loadByte(target, Scratch, 0)
    emitter.branchIfNotZero(Word32, target, leave)
    emitter.loadWord(target, Scratch, ValuePayload)

  proc writeElement(emitter: var Assembler, scratch: int)
      {.raises: [BasicError].} =
    ## Writes a cell as an integer.
    emitter.storeByte(zeroRegister, Scratch, 0)
    emitter.storeWord(ValueScratch[scratch], Scratch, ValuePayload)

  proc beginCountedLoop(emitter: var Assembler, instructions, work: int64,
      refused: Label) {.raises: [BasicError].} =
    ## Settles the whole loop's budget once: how many passes both budgets
    ## can certainly afford. One pass is held back so that the pass which
    ## finally leaves the loop, charging up to a full pass on the way out,
    ## still cannot overrun.
    emitter.loadImmediate(Word64, Scratch, instructions)
    emitter.signedDivide(Word64, Allowance, Instructions, Scratch)
    emitter.loadImmediate(Word64, Scratch, work)
    emitter.signedDivide(Word64, OtherScratch, Work, Scratch)
    let smaller = emitter.label()
    emitter.compareRegister(Word64, Allowance, OtherScratch)
    emitter.branchIf(LessEqualCondition, smaller)
    emitter.moveRegister(Word64, Allowance, OtherScratch)
    emitter.place(smaller)
    emitter.subtractImmediate(Word64, Allowance, Allowance, 1)
    # Fewer than one affordable pass means the loop must go back to the
    # interpreter, which alone can refuse the budget at the right place.
    # Accepting zero here would hand the same offset back for ever.
    emitter.compareImmediate(Word64, Allowance, 1)
    emitter.branchIf(LessCondition, refused)
    emitter.loadImmediate(Word64, Counter, 0)

  proc checkCounter(emitter: var Assembler, handBack: Label)
      {.raises: [BasicError].} =
    ## Leaves the loop once the settled number of passes is used up.
    emitter.compareRegister(Word64, Counter, Allowance)
    emitter.branchIf(GreaterEqualCondition, handBack)

  proc advanceCounter(emitter: var Assembler) {.raises: [BasicError].} =
    ## Records that one more pass finished.
    emitter.addImmediate(Word64, Counter, Counter, 1)

  proc beginSpendingLoop(emitter: var Assembler,
      passInstructions, passWork: int64, refused: Label)
      {.raises: [BasicError].} =
    ## Prepares a loop whose passes differ in cost. Rather than refusing
    ## the budget block by block, the loop adds up what it spends and asks
    ## once a pass whether another pass could still be afforded outright.
    emitter.loadImmediate(Word64, SpentInstructions, 0)
    emitter.loadImmediate(Word64, SpentWork, 0)
    emitter.loadImmediate(Word64, Scratch, passInstructions)
    emitter.subtractRegister(
      Word64, LimitInstructions, Instructions, Scratch
    )
    emitter.loadImmediate(Word64, Scratch, passWork)
    emitter.subtractRegister(Word64, LimitWork, Work, Scratch)
    emitter.compareImmediate(Word64, LimitInstructions, 0)
    emitter.branchIf(LessCondition, refused)
    emitter.compareImmediate(Word64, LimitWork, 0)
    emitter.branchIf(LessCondition, refused)

  proc checkSpending(emitter: var Assembler, handBack: Label)
      {.raises: [BasicError].} =
    ## Leaves the loop while another whole pass is still certainly afforded.
    emitter.compareRegister(Word64, SpentInstructions, LimitInstructions)
    emitter.branchIf(GreaterCondition, handBack)
    emitter.compareRegister(Word64, SpentWork, LimitWork)
    emitter.branchIf(GreaterCondition, handBack)

  proc recordSpending(emitter: var Assembler, instructions, work: int64)
      {.raises: [BasicError].} =
    ## Adds one block's charge, with nothing to test and nowhere to branch.
    emitter.addImmediate(
      Word64, SpentInstructions, SpentInstructions, int(instructions)
    )
    emitter.addImmediate(Word64, SpentWork, SpentWork, int(work))

  proc chargeSpending(emitter: var Assembler) {.raises: [BasicError].} =
    ## Hands back exactly what the passes added up to.
    emitter.subtractRegister(
      Word64, Instructions, Instructions, SpentInstructions
    )
    emitter.subtractRegister(Word64, Work, Work, SpentWork)

  proc chargeCounted(emitter: var Assembler, instructions, work: int64,
      partialInstructions, partialWork: int64) {.raises: [BasicError].} =
    ## Charges whole passes plus however far the last one got.
    emitter.loadImmediate(Word64, Scratch, instructions)
    emitter.loadImmediate(Word64, OtherScratch, partialInstructions)
    emitter.multiplyAdd(Word64, Scratch, Counter, Scratch, OtherScratch)
    emitter.subtractRegister(Word64, Instructions, Instructions, Scratch)
    emitter.loadImmediate(Word64, Scratch, work)
    emitter.loadImmediate(Word64, OtherScratch, partialWork)
    emitter.multiplyAdd(Word64, Scratch, Counter, Scratch, OtherScratch)
    emitter.subtractRegister(Word64, Work, Work, Scratch)

  proc lowBitCount(divisor: int32): int {.raises: [].} =
    ## Returns how many low bits decide divisibility, when the divisor is
    ## a power of two and so only those bits matter.
    var magnitude = int64(divisor)
    if magnitude < 0:
      magnitude = -magnitude
    if magnitude < 2 or (magnitude and (magnitude - 1)) != 0:
      return 0
    while magnitude > 1:
      magnitude = magnitude shr 1
      inc result

  proc remainderTest(emitter: var Assembler, slot: int, divisor: int32)
      {.raises: [BasicError].} =
    ## Sets flags so NotEqualTest means the remainder is not zero.
    let source = slotRegister(slot)
    # Truncating division leaves no remainder against a power of two
    # exactly when the low bits are clear, for negative values as well, so
    # a bit test stands in for a divide and a multiply.
    let bits = lowBitCount(divisor)
    if bits > 0:
      emitter.testLowBits(Word32, source, bits)
      return
    emitter.loadImmediate(Word32, Scratch, int64(divisor))
    emitter.signedDivide(Word32, OtherScratch, source, Scratch)
    emitter.multiplySubtract(
      Word32, OtherScratch, OtherScratch, Scratch, source
    )
    emitter.compareImmediate(Word32, OtherScratch, 0)

  proc budgetGate(emitter: var Assembler, instructionCount, workCost: int64,
      short: Label) {.raises: [BasicError].} =
    ## Checks both budgets before charging either, as the interpreter does.
    emitter.loadImmediate(Word64, Scratch, instructionCount)
    emitter.compareRegister(Word64, Instructions, Scratch)
    emitter.branchIf(LessCondition, short)
    emitter.loadImmediate(Word64, OtherScratch, workCost)
    emitter.compareRegister(Word64, Work, OtherScratch)
    emitter.branchIf(LessCondition, short)
    emitter.subtractRegister(Word64, Instructions, Instructions, Scratch)
    emitter.subtractRegister(Word64, Work, Work, OtherScratch)

  proc exitStub(emitter: var Assembler, offset: int32, status: int32,
      writeback: Label) {.raises: [BasicError].} =
    ## Names the resume offset and status, then joins the shared exit.
    emitter.loadImmediate(Word32, ResumeOffset, int64(offset))
    emitter.loadImmediate(Word32, ResumeStatus, int64(status))
    emitter.branch(writeback)

  proc publishState(emitter: var Assembler) {.raises: [BasicError].} =
    ## Writes the budgets, the resume offset, and the status.
    emitter.storeDouble(Instructions, Context, ContextInstructions)
    emitter.storeDouble(Work, Context, ContextWork)
    emitter.storeWord(ResumeOffset, Context, ContextOffset)
    emitter.moveRegister(Word32, Context, ResumeStatus)

  proc guardExit(emitter: var Assembler, start: int32)
      {.raises: [BasicError].} =
    ## Hands the loop back untouched after a failed guard.
    emitter.loadImmediate(Word32, ResumeOffset, int64(start))
    emitter.storeWord(ResumeOffset, Context, ContextOffset)
    emitter.loadImmediate(Word32, Context, int64(ord(NativeGuardFailed)))
    emitter.endRegion()
  proc setSlotConstant(emitter: var Assembler, slot: int32, tag: int,
      bits: int32) {.raises: [BasicError].} =
    ## Writes a constant of a known kind straight into a slot.
    let base = int(slot) * ValueStride
    emitter.loadImmediate(Word32, Scratch, int64(tag))
    emitter.storeByte(Scratch, RegistersBase, base)
    emitter.loadImmediate(Word32, ValueScratch[0], int64(bits))
    emitter.storeWord(ValueScratch[0], RegistersBase, base + ValuePayload)

  proc hostDataAddress(emitter: var Assembler, index: int32)
      {.raises: [BasicError].} =
    ## Leaves one host data value's address in Scratch.
    emitter.loadDouble(Scratch, Context, ContextHostData)
    emitter.loadImmediate(Word32, OtherScratch, int64(index) * ValueStride)
    emitter.addRegister(Word64, Scratch, Scratch, OtherScratch)

  proc copyHostDataToSlot(emitter: var Assembler, index, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a host value entire into a slot, as the interpreter does.
    emitter.hostDataAddress(index)
    emitter.copyElementToSlot(slot)

  proc readHostDataInteger(emitter: var Assembler, scratch: int,
      index: int32, leave: Label) {.raises: [BasicError].} =
    ## Reads a host value as an integer, leaving the region if it is not.
    emitter.hostDataAddress(index)
    emitter.readElement(scratch, leave)


elif NativeAmd64:
  ## x86-64 code generation
  ##
  ## rbx  base of the globals array
  ## r12  remaining instruction budget
  ## r13  remaining work budget
  ## rax and rdx are reserved for the divide;  r11 is scratch
  ##
  ## The two conventions differ only in which register carries the argument
  ## and which ones a callee must preserve. System V takes its argument in
  ## rdi and may use rsi and rdi freely; Windows takes its argument in rcx
  ## and must preserve both rsi and rdi.

  const
    GlobalsBase = rbx
    RegistersBase = rbp
    Instructions = r12
    Work = r13
    Scratch = r11
    ValueScratch = [rax, rdx]

  when defined(windows):
    const
      Context = rcx
      Hoisted = [r14, r15, rsi, rdi, r8, r9, r10]
      Saved = [rbx, rbp, r12, r13, r14, r15, rsi, rdi]
  else:
    const
      Context = rdi
      Hoisted = [r14, r15, rsi, rcx, r8, r9, r10]
      Saved = [rbx, rbp, r12, r13, r14, r15]

  proc slotRegister(slot: int): Register {.raises: [].} =
    ## Returns the register holding one hoisted global.
    Hoisted[slot]

  proc nativeCondition(test: Test): Condition {.raises: [].} =
    ## Maps a neutral condition onto the architecture's encoding.
    case test
    of EqualTest: EqualCondition
    of NotEqualTest: NotEqualCondition
    of LessTest: LessCondition
    of LessEqualTest: LessEqualCondition
    of GreaterTest: GreaterCondition
    of GreaterEqualTest: GreaterEqualCondition

  proc branchWhen(emitter: var Assembler, test: Test, target: Label)
      {.raises: [].} =
    ## Branches when the neutral condition holds.
    emitter.branchIf(nativeCondition(test), target)

  proc startRegion(emitter: var Assembler) {.raises: [BasicError].} =
    ## Saves callee-saved registers and loads the interpreter state.
    for register in Saved:
      emitter.push(register)
    emitter.loadDouble(GlobalsBase, Context, 0)
    emitter.loadDouble(Instructions, Context, ContextInstructions)
    emitter.loadDouble(Work, Context, ContextWork)

  proc endRegion(emitter: var Assembler) {.raises: [BasicError].} =
    ## Restores callee-saved registers and returns to the interpreter.
    for index in countdown(Saved.len - 1, 0):
      emitter.pop(Saved[index])
    emitter.returnToCaller()

  proc readNumeric(emitter: var Assembler, scratch: int, slot: int32,
      leave: Label) {.raises: [BasicError].} =
    ## Reads a slot's tag into Scratch and its payload into a working
    ## register, leaving the region for anything that is not a number.
    let base = int(slot) * ValueStride
    emitter.loadByteZeroed(Scratch, RegistersBase, base)
    emitter.compareImmediate(Word32, Scratch, FixedTag)
    emitter.branchIf(AboveCondition, leave)
    emitter.loadWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc requireSameKind(emitter: var Assembler, slot: int32, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless a second slot carries the same tag as the
    ## one already held. Whole numbers and fixed-point ones add, subtract
    ## and compare through the very same instructions, so a pair that
    ## agrees needs no further telling apart; a mixed pair would have to
    ## be promoted, which can fail, so it goes back to the interpreter.
    emitter.loadByteZeroed(ValueScratch[1], RegistersBase,
      int(slot) * ValueStride)
    emitter.compareRegister(Word32, Scratch, ValueScratch[1])
    emitter.branchIf(NotEqualCondition, leave)

  proc writeNumeric(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Writes a payload back under the tag the operands carried.
    let base = int(slot) * ValueStride
    emitter.storeByteLow(RegistersBase, base, Scratch)
    emitter.storeWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc branchIfFixed(emitter: var Assembler, target: Label)
      {.raises: [BasicError].} =
    ## Branches when the held tag says fixed point.
    emitter.compareImmediate(Word32, Scratch, FixedTag)
    emitter.branchIf(EqualCondition, target)

  proc requireWholeKind(emitter: var Assembler, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless the held tag says whole number.
    emitter.compareImmediate(Word32, Scratch, 0)
    emitter.branchIf(NotEqualCondition, leave)

  proc readSlotValue(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Reads a slot's payload, its tag having already been established.
    emitter.loadWord(ValueScratch[scratch], RegistersBase,
      int(slot) * ValueStride + ValuePayload)

  proc guardDivisor(emitter: var Assembler, scratch: int, leave: Label)
      {.raises: [BasicError].} =
    ## Leaves the region for the two divisors that are not plain division:
    ## zero, which the interpreter refuses, and minus one, which would
    ## trap here on the most negative dividend.
    emitter.compareImmediate(Word32, ValueScratch[scratch], 0)
    emitter.branchIf(EqualCondition, leave)
    emitter.compareImmediate(Word32, ValueScratch[scratch], -1)
    emitter.branchIf(EqualCondition, leave)

  proc quotientScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Divides the first working register by the second, toward zero.
    ## The divide reads and writes the accumulator pair, so the divisor is
    ## moved aside first and the answer moved back afterwards.
    emitter.moveRegister(Word32, Scratch, ValueScratch[right])
    emitter.moveRegister(Word32, rax, ValueScratch[left])
    emitter.signExtendToPair(Word32)
    emitter.signedDivide(Word32, Scratch)
    emitter.moveRegister(Word32, ValueScratch[left], rax)

  proc remainderScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Leaves what the division of the two working registers left over.
    emitter.moveRegister(Word32, Scratch, ValueScratch[right])
    emitter.moveRegister(Word32, rax, ValueScratch[left])
    emitter.signExtendToPair(Word32)
    emitter.signedDivide(Word32, Scratch)
    emitter.moveRegister(Word32, ValueScratch[left], rdx)

  proc multiplyFixed(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Multiplies two Q16.16 numbers through a widened intermediate,
    ## rounding to nearest exactly as the fixed-point library does.
    emitter.signExtendDouble(ValueScratch[left], ValueScratch[left])
    emitter.signExtendDouble(ValueScratch[right], ValueScratch[right])
    emitter.multiplyRegister(Word64, ValueScratch[left], ValueScratch[right])
    emitter.addImmediate(Word64, ValueScratch[left], int32(FixedRounding))
    emitter.shiftRightImmediate(Word64, ValueScratch[left], FixedShift)

  proc elementAddress(emitter: var Assembler, scratch: int,
      extent: ArrayExtent, leave: Label) {.raises: [BasicError].} =
    ## Bounds checks an index and leaves the cell's address in Scratch.
    ## One unsigned comparison covers both ends, exactly as the
    ## interpreter's does, and a refusal hands the offset back so the
    ## interpreter can raise with the array's own name.
    let index = ValueScratch[scratch]
    emitter.compareImmediate(Word32, index, extent.length)
    emitter.branchIf(AboveEqualCondition, leave)
    emitter.addImmediate(Word32, index, extent.base)
    emitter.shiftLeftImmediate(Word64, index, 4)
    emitter.loadDouble(Scratch, Context, ContextMemory)
    emitter.addRegister(Word64, Scratch, index)

  proc copyElementToSlot(emitter: var Assembler, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a whole cell into a register slot, whatever it holds. The
    ## interpreter copies the value entire, so this does too, and neither
    ## needs to know what kind it is.
    let base = int(slot) * ValueStride
    emitter.loadDouble(ValueScratch[0], Scratch, 0)
    emitter.loadDouble(ValueScratch[1], Scratch, ValuePayload)
    emitter.storeDouble(ValueScratch[0], RegistersBase, base)
    emitter.storeDouble(ValueScratch[1], RegistersBase, base + ValuePayload)

  proc copySlotToElement(emitter: var Assembler, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a whole register slot into a cell, whatever it holds.
    let base = int(slot) * ValueStride
    emitter.loadDouble(ValueScratch[0], RegistersBase, base)
    emitter.loadDouble(ValueScratch[1], RegistersBase, base + ValuePayload)
    emitter.storeDouble(ValueScratch[0], Scratch, 0)
    emitter.storeDouble(ValueScratch[1], Scratch, ValuePayload)

  proc readElement(emitter: var Assembler, scratch: int, leave: Label)
      {.raises: [BasicError].} =
    ## Reads a cell as an integer, leaving the region if it holds else.
    let target = ValueScratch[scratch]
    emitter.loadByteZeroed(target, Scratch, 0)
    emitter.testRegister(Word32, target, target)
    emitter.branchIf(NotEqualCondition, leave)
    emitter.loadWord(target, Scratch, ValuePayload)

  proc writeElement(emitter: var Assembler, scratch: int)
      {.raises: [BasicError].} =
    ## Writes a cell as an integer.
    emitter.storeByteImmediate(Scratch, 0, 0)
    emitter.storeWord(ValueScratch[scratch], Scratch, ValuePayload)

  proc guardInteger(emitter: var Assembler, base: int, failed: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless the global at this offset holds an integer.
    emitter.loadByteZeroed(Scratch, GlobalsBase, base)
    emitter.testRegister(Word32, Scratch, Scratch)
    emitter.branchIf(NotEqualCondition, failed)

  proc loadRegistersBase(emitter: var Assembler) {.raises: [BasicError].} =
    ## Points at the first slot of the frame the region runs in.
    emitter.loadDouble(RegistersBase, Context, ContextRegisters)

  proc readSlot(emitter: var Assembler, scratch: int, slot: int32,
      leave: Label) {.raises: [BasicError].} =
    ## Reads one register slot as an integer, leaving the region if it
    ## holds anything else. The tag is read into the same register the
    ## value will land in, so no third register is needed.
    let target = ValueScratch[scratch]
    let base = int(slot) * ValueStride
    emitter.loadByteZeroed(target, RegistersBase, base)
    emitter.testRegister(Word32, target, target)
    emitter.branchIf(NotEqualCondition, leave)
    emitter.loadWord(target, RegistersBase, base + ValuePayload)

  proc writeSlot(emitter: var Assembler, scratch: int, slot: int32)
      {.raises: [BasicError].} =
    ## Writes one register slot as an integer.
    let base = int(slot) * ValueStride
    emitter.storeByteImmediate(RegistersBase, base, 0)
    emitter.storeWord(ValueScratch[scratch], RegistersBase,
      base + ValuePayload)

  proc setScratch(emitter: var Assembler, scratch: int, value: int32)
      {.raises: [BasicError].} =
    ## Loads a constant into a working register.
    emitter.loadImmediate(Word32, ValueScratch[scratch], int64(value))

  proc addScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Adds the second working register into the first, wrapping.
    emitter.addRegister(Word32, ValueScratch[left], ValueScratch[right])

  proc subtractScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Subtracts the second working register from the first, wrapping.
    emitter.subtractRegister(Word32, ValueScratch[left], ValueScratch[right])

  proc multiplyScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Multiplies the first working register by the second, wrapping.
    emitter.multiplyRegister(Word32, ValueScratch[left], ValueScratch[right])

  proc negateScratch(emitter: var Assembler, scratch: int)
      {.raises: [BasicError].} =
    ## Replaces a working register with its negation, wrapping.
    emitter.negateRegister(Word32, ValueScratch[scratch])

  proc compareScratch(emitter: var Assembler, left, right: int)
      {.raises: [BasicError].} =
    ## Sets flags from two working registers.
    emitter.compareRegister(Word32, ValueScratch[left], ValueScratch[right])

  proc answerCondition(emitter: var Assembler, scratch: int, test: Test)
      {.raises: [BasicError].} =
    ## Writes BASIC's -1 for true and zero for false.
    emitter.setIfCondition(ValueScratch[scratch], nativeCondition(test))
    emitter.negateRegister(Word32, ValueScratch[scratch])

  proc scratchFromHoisted(emitter: var Assembler, scratch, slot: int)
      {.raises: [BasicError].} =
    ## Copies a hoisted global into a working register.
    emitter.moveRegister(Word32, ValueScratch[scratch], slotRegister(slot))

  proc hoistedFromScratch(emitter: var Assembler, slot, scratch: int)
      {.raises: [BasicError].} =
    ## Copies a working register into a hoisted global.
    emitter.moveRegister(Word32, slotRegister(slot), ValueScratch[scratch])

  proc branchIfScratchZero(emitter: var Assembler, scratch: int,
      target: Label) {.raises: [BasicError].} =
    ## Branches when a working register holds zero.
    emitter.testRegister(Word32, ValueScratch[scratch], ValueScratch[scratch])
    emitter.branchIf(EqualCondition, target)

  proc loadHoisted(emitter: var Assembler, slot: int, base: int)
      {.raises: [BasicError].} =
    ## Reads one global into its register.
    emitter.loadWord(slotRegister(slot), GlobalsBase, base + ValuePayload)

  proc storeHoisted(emitter: var Assembler, slot: int, base: int)
      {.raises: [BasicError].} =
    ## Publishes one register back as an integer value.
    emitter.storeByteImmediate(GlobalsBase, base, 0)
    emitter.storeWord(slotRegister(slot), GlobalsBase, base + ValuePayload)

  proc setSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
    ## Loads a constant into a hoisted register.
    emitter.loadImmediate(Word32, slotRegister(slot), int64(value))

  proc copySlot(emitter: var Assembler, destination, source: int)
      {.raises: [BasicError].} =
    ## Copies one hoisted register into another.
    emitter.moveRegister(
      Word32, slotRegister(destination), slotRegister(source)
    )

  proc addSlots(emitter: var Assembler, destination, source: int)
      {.raises: [BasicError].} =
    ## Adds one hoisted register into another, wrapping on overflow.
    emitter.addRegister(
      Word32, slotRegister(destination), slotRegister(source)
    )

  proc addToSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
    ## Adds a constant to a hoisted register, wrapping on overflow.
    emitter.addImmediate(Word32, slotRegister(slot), value)

  const MaxPooled* = 0

  proc compareSlot(emitter: var Assembler, slot: int, value: int32,
      pooled = -1) {.raises: [BasicError].} =
    ## Sets flags from a hoisted register against a constant.
    emitter.compareImmediate(Word32, slotRegister(slot), value)

  proc remainderTest(emitter: var Assembler, slot: int, divisor: int32)
      {.raises: [BasicError].} =
    ## Sets flags so NotEqualTest means the remainder is not zero.
    emitter.moveRegister(Word32, rax, slotRegister(slot))
    emitter.signExtendToPair(Word32)
    emitter.loadImmediate(Word32, Scratch, int64(divisor))
    emitter.signedDivide(Word32, Scratch)
    emitter.testRegister(Word32, rdx, rdx)

  proc budgetGate(emitter: var Assembler, instructionCount, workCost: int64,
      short: Label) {.raises: [BasicError].} =
    ## Checks both budgets before charging either, as the interpreter does.
    ## Both counts come from int32 operands, so they fit the immediate form.
    emitter.compareImmediate(Word64, Instructions, int32(instructionCount))
    emitter.branchIf(LessCondition, short)
    emitter.compareImmediate(Word64, Work, int32(workCost))
    emitter.branchIf(LessCondition, short)
    emitter.subtractImmediate(Word64, Instructions, int32(instructionCount))
    emitter.subtractImmediate(Word64, Work, int32(workCost))

  proc exitStub(emitter: var Assembler, offset: int32, status: int32,
      writeback: Label) {.raises: [BasicError].} =
    ## Names the resume offset and status, then joins the shared exit.
    emitter.storeWordImmediate(Context, ContextOffset, offset)
    emitter.loadImmediate(Word32, rax, int64(status))
    emitter.branch(writeback)

  proc publishState(emitter: var Assembler) {.raises: [BasicError].} =
    ## Writes the budgets back; the status already sits in the result.
    emitter.storeDouble(Instructions, Context, ContextInstructions)
    emitter.storeDouble(Work, Context, ContextWork)

  proc guardExit(emitter: var Assembler, start: int32)
      {.raises: [BasicError].} =
    ## Hands the loop back untouched after a failed guard.
    emitter.storeWordImmediate(Context, ContextOffset, start)
    emitter.loadImmediate(Word32, rax, int64(ord(NativeGuardFailed)))
    emitter.endRegion()
  proc setSlotConstant(emitter: var Assembler, slot: int32, tag: int,
      bits: int32) {.raises: [BasicError].} =
    ## Writes a constant of a known kind straight into a slot.
    let base = int(slot) * ValueStride
    emitter.storeByteImmediate(RegistersBase, base, byte(tag))
    emitter.loadImmediate(Word32, ValueScratch[0], int64(bits))
    emitter.storeWord(ValueScratch[0], RegistersBase, base + ValuePayload)

  proc hostDataAddress(emitter: var Assembler, index: int32)
      {.raises: [BasicError].} =
    ## Leaves one host data value's address in Scratch.
    emitter.loadDouble(Scratch, Context, ContextHostData)
    emitter.addImmediate(Word64, Scratch, index * int32(ValueStride))

  proc copyHostDataToSlot(emitter: var Assembler, index, slot: int32)
      {.raises: [BasicError].} =
    ## Copies a host value entire into a slot, as the interpreter does.
    emitter.hostDataAddress(index)
    emitter.copyElementToSlot(slot)

  proc readHostDataInteger(emitter: var Assembler, scratch: int,
      index: int32, leave: Label) {.raises: [BasicError].} =
    ## Reads a host value as an integer, leaving the region if it is not.
    emitter.hostDataAddress(index)
    emitter.readElement(scratch, leave)


proc compileRegion*(code: seq[Instruction], start, stop, globals,
    slots: int, extents: seq[ArrayExtent], constants: seq[int32] = @[],
    hostData = 0): Region {.raises: [BasicError].} =
  ## Compiles one loop, or returns nil when it is outside the modelled set.
  ##
  ## Generated code indexes global storage without checking, so every
  ## index it will use is proved to be in range here, before any of it is
  ## emitted. The interpreter checks each access as it runs; compiled code
  ## cannot, which is exactly why this pass has to be exhaustive.
  when not (NativeArm64 or NativeAmd64):
    # No backend for this target: the interpreter is the only path.
    return nil
  else:
    if start < 0 or stop > code.len or start >= stop:
      echo "nil range"
      return nil
    if code.reachesOutside(start, stop):
      echo "nil outside"
      return nil

    if globals < 0 or slots < 0:
      return nil
    var usesSlots = false

    var hoisted: seq[int32]
    for index in start ..< stop:
      let item = code[index]
      if not item.isCompilable:
        echo "nil op ", item.op, " at ", index
        return nil
      item.touchedGlobals(hoisted)
      # Slots are read and written where they sit, so each index only has
      # to be proved in range; nothing is carried across the region.
      # Every array named must exist, and its cells must sit where a
      # displacement can reach them.
      # Every constant and host slot named has to exist, and a divisor
      # fixed at compile time has to be one that divides plainly.
      case item.op
      of LoadFixedOp:
        if item.b < 0 or int(item.b) >= constants.len:
          return nil
        usesSlots = true
      of LoadHostDataOp, AddGlobalHostDataOp:
        if item.b < 0 or int(item.b) >= hostData:
          return nil
        if int(item.b) >
            (MaxDisplacementBytes - ValuePayload) div ValueStride:
          return nil
        if item.op == LoadHostDataOp:
          usesSlots = true
      of AddGlobalRegisterOp:
        usesSlots = true
      of ModuloGlobalImmediateOp:
        if item.c == 0 or item.c == -1:
          return nil
      else:
        discard
      var arrayId = 0'i32
      if item.namedArray(arrayId):
        if arrayId < 0 or int(arrayId) >= extents.len:
          return nil
        let extent = extents[int(arrayId)]
        if extent.length <= 0 or extent.base < 0:
          return nil
        if int(extent.base) + int(extent.length) >
            MaxDisplacementBytes div ValueStride:
          return nil
        usesSlots = true
      var touched: seq[int32]
      item.touchedSlots(touched)
      if touched.len > 0:
        usesSlots = true
        for slot in touched:
          if slot < 0 or int(slot) >= slots:
            return nil
          if int(slot) > (MaxDisplacementBytes - ValuePayload) div ValueStride:
            return nil
      var target = 0'i32
      if item.branchTarget(target):
        # A branch may land one past the last offset, where the
        # interpreter stops, but never beyond it.
        if int(target) < 0 or int(target) > code.len:
          return nil
    if hoisted.len == 0 or hoisted.len > MaxHoistedGlobals:
      echo "nil hoisted ", hoisted.len
      return nil
    for index in hoisted:
      if index < 0 or int(index) >= globals:
        return nil
      if int(index) > (MaxDisplacementBytes - ValuePayload) div ValueStride:
        return nil
    when NativeArm64:
      # The tag is read through a scaled byte offset, which is narrower
      # than the range the bounds check above already allows.
      for index in hoisted:
        if int(index) * ValueStride + ValuePayload > 4095:
          return nil

    proc slotOf(index: int32): int {.closure, raises: [BasicError].} =
      ## Returns which hoisted register holds one global. Reaching the end
      ## would mean an operation reads a global that was never gathered,
      ## and so never bounds checked, so it refuses rather than picking a
      ## register that happens to be next.
      result = -1
      for slot, candidate in hoisted:
        if candidate == index:
          result = slot
          break
      if result < 0:
        raise newException(
          BasicError, "BASIC native compiler met an ungathered global"
        )

    const CountedLoops = NativeArm64
    let plan = planLoop(code, start, stop)
    let counted = CountedLoops and plan.counted
    let spending = CountedLoops and plan.spending and not plan.counted
    let pool =
      if MaxPooled > 0: pooledConstants(code, start, stop, MaxPooled)
      else: @[]

    proc poolSlot(value: int32): int {.closure, raises: [].} =
      ## Returns which register already holds a constant, if one does.
      for slot, held in pool:
        if held == int64(value):
          return slot
      -1

    var emitter = Assembler()
    var blocks: seq[Label]
    for index in start ..< stop:
      blocks.add(emitter.label())
    let guardFailed = emitter.label()
    let writeback = emitter.label()
    var exits: seq[(Label, int32, NativeStatus, int)]

    template blockAt(offset: int32): Label =
      blocks[int(offset) - start]

    proc exitLabel(target: int32, status: NativeStatus,
        leaving: int): Label =
      ## Names the out-of-line stub that resumes the interpreter here.
      ## A countable loop charges for how far the leaving pass got, so
      ## stubs differ by where they leave as well as where they go.
      for (stub, existing, kind, origin) in exits:
        if existing == target and kind == status and origin == leaving:
          return stub
      result = emitter.label()
      exits.add((result, target, status, leaving))

    template leaveFor(target: int32, status: NativeStatus, leaving: int) =
      ## Jumps to the stub that resumes the interpreter at an offset.
      emitter.branch(exitLabel(target, status, leaving))

    ## Entry: prove every participating global is an integer, then hoist it.
    emitter.startRegion()
    if usesSlots:
      emitter.loadRegistersBase()
    for slot, index in hoisted:
      let base = int(index) * ValueStride
      emitter.guardInteger(base, guardFailed)
      emitter.loadHoisted(slot, base)
    when CountedLoops:
      for slot, value in pool:
        emitter.loadPooled(slot, value)
      # Nothing has been written yet, so a refusal here hands the loop
      # back exactly as it was found.
      if counted:
        emitter.beginCountedLoop(
          plan.instructions, plan.work,
          exitLabel(int32(start), NativeExhausted, start)
        )
      elif spending:
        emitter.beginSpendingLoop(
          plan.passInstructions, plan.passWork,
          exitLabel(int32(start), NativeExhausted, start)
        )

    ## Body: one native block per bytecode offset, so branches keep working.
    for index in start ..< stop:
      let item = code[index]
      emitter.place(blockAt(int32(index)))

      # A slot holding anything but an integer hands this offset back to
      # the interpreter, which can work in whatever the slot does hold.
      # Nothing has been written for this operation yet, and the charge
      # for the pass so far is the one every other exit uses.
      let leaveHere = exitLabel(int32(index), NativeCompleted, index)

      template branchOut(target: int32, test: Test) =
        ## Takes an in-region branch directly, or leaves through a stub.
        if int(target) >= start and int(target) < stop:
          emitter.branchWhen(test, blockAt(target))
        else:
          emitter.branchWhen(
            test, exitLabel(target, NativeCompleted, index)
          )

      case item.op
      of MeterOp:
        when CountedLoops:
          if counted:
            # The budget was settled on entry, so a countable loop needs
            # only to know it has passes left.
            if index == start:
              emitter.checkCounter(
                exitLabel(int32(start), NativeCompleted, start)
              )
          elif spending:
            if plan.checkpoints[index - start]:
              emitter.checkSpending(
                exitLabel(int32(index), NativeCompleted, index)
              )
            emitter.recordSpending(int64(item.b), int64(item.a))
          else:
            emitter.budgetGate(
              int64(item.b), int64(item.a),
              exitLabel(int32(index), NativeExhausted, index)
            )
        else:
          emitter.budgetGate(
            int64(item.b), int64(item.a),
            exitLabel(int32(index), NativeExhausted, index)
          )
      of StoreGlobalImmediateOp:
        emitter.setSlot(slotOf(item.a), item.b)
      of MoveGlobalOp:
        emitter.copySlot(slotOf(item.a), slotOf(item.b))
      of AddGlobalImmediateOp:
        emitter.addToSlot(slotOf(item.a), item.b)
      of AddGlobalOp:
        emitter.addSlots(slotOf(item.a), slotOf(item.b))
      of LoadImmediateOp:
        emitter.setScratch(0, item.b)
        emitter.writeSlot(0, item.a)
      of MoveOp:
        emitter.readSlot(0, item.b, leaveHere)
        emitter.writeSlot(0, item.a)
      of LoadGlobalOp:
        emitter.scratchFromHoisted(0, slotOf(item.b))
        emitter.writeSlot(0, item.a)
      of StoreGlobalOp:
        emitter.readSlot(0, item.b, leaveHere)
        emitter.hoistedFromScratch(slotOf(item.a), 0)
      of AddOp, SubtractOp:
        # Whole and fixed-point numbers add and subtract through the same
        # instructions, so one path serves both and the answer keeps the
        # kind its operands agreed on.
        emitter.readNumeric(0, item.b, leaveHere)
        emitter.requireSameKind(item.c, leaveHere)
        emitter.readSlotValue(1, item.c)
        if item.op == AddOp:
          emitter.addScratch(0, 1)
        else:
          emitter.subtractScratch(0, 1)
        emitter.writeNumeric(0, item.a)
      of MultiplyOp:
        emitter.readNumeric(0, item.b, leaveHere)
        emitter.requireSameKind(item.c, leaveHere)
        emitter.readSlotValue(1, item.c)
        when ModelsFixed:
          let fixedWay = emitter.label()
          let joined = emitter.label()
          emitter.branchIfFixed(fixedWay)
          emitter.multiplyScratch(0, 1)
          emitter.branch(joined)
          emitter.place(fixedWay)
          emitter.multiplyFixed(0, 1)
          emitter.place(joined)
        else:
          emitter.requireWholeKind(leaveHere)
          emitter.multiplyScratch(0, 1)
        emitter.writeNumeric(0, item.a)
      of NegateOp:
        emitter.readNumeric(0, item.b, leaveHere)
        emitter.negateScratch(0)
        emitter.writeNumeric(0, item.a)
      of EqualOp, NotEqualOp, LessOp, LessEqualOp, GreaterOp,
          GreaterEqualOp:
        # Ordering is the same on the stored bits either way round, and
        # the answer is always a whole number.
        emitter.readNumeric(0, item.b, leaveHere)
        emitter.requireSameKind(item.c, leaveHere)
        emitter.readSlotValue(1, item.c)
        emitter.compareScratch(0, 1)
        emitter.answerCondition(0, comparisonTest(item.op))
        emitter.writeSlot(0, item.a)
      of ModuloOp, IntegerDivideOp:
        # Both want whole numbers, both refuse a zero divisor, and minus
        # one would trap on one of the two architectures, so all three go
        # back to the interpreter rather than being modelled.
        emitter.readSlot(0, item.b, leaveHere)
        emitter.readSlot(1, item.c, leaveHere)
        emitter.guardDivisor(1, leaveHere)
        if item.op == ModuloOp:
          emitter.remainderScratch(0, 1)
        else:
          emitter.quotientScratch(0, 1)
        emitter.writeSlot(0, item.a)
      of LoadFixedOp:
        emitter.setSlotConstant(item.a, FixedTag, constants[int(item.b)])
      of LoadHostDataOp:
        emitter.copyHostDataToSlot(item.b, item.a)
      of AddGlobalHostDataOp:
        emitter.readHostDataInteger(0, item.b, leaveHere)
        emitter.scratchFromHoisted(1, slotOf(item.a))
        emitter.addScratch(1, 0)
        emitter.hoistedFromScratch(slotOf(item.a), 1)
      of AddGlobalRegisterOp:
        emitter.readSlot(0, item.b, leaveHere)
        emitter.scratchFromHoisted(1, slotOf(item.a))
        emitter.addScratch(1, 0)
        emitter.hoistedFromScratch(slotOf(item.a), 1)
      of ModuloGlobalImmediateOp:
        emitter.scratchFromHoisted(0, slotOf(item.b))
        emitter.setScratch(1, item.c)
        emitter.remainderScratch(0, 1)
        emitter.hoistedFromScratch(slotOf(item.a), 0)
      of ArrayGetOp:
        emitter.readSlot(0, item.c, leaveHere)
        emitter.elementAddress(0, extents[int(item.b)], leaveHere)
        emitter.copyElementToSlot(item.a)
      of ArraySetOp:
        emitter.readSlot(0, item.b, leaveHere)
        emitter.elementAddress(0, extents[int(item.a)], leaveHere)
        emitter.copySlotToElement(item.c)
      of ArrayAddGlobalsOp:
        emitter.scratchFromHoisted(0, slotOf(item.b))
        emitter.elementAddress(0, extents[int(item.a)], leaveHere)
        emitter.readElement(0, leaveHere)
        emitter.scratchFromHoisted(1, slotOf(item.c))
        emitter.addScratch(0, 1)
        emitter.writeElement(0)
      of AddGlobalArrayGlobalIndexOp:
        emitter.scratchFromHoisted(0, slotOf(item.c))
        emitter.elementAddress(0, extents[int(item.b)], leaveHere)
        emitter.readElement(0, leaveHere)
        emitter.scratchFromHoisted(1, slotOf(item.a))
        emitter.addScratch(1, 0)
        emitter.hoistedFromScratch(slotOf(item.a), 1)
      of JumpIfZeroOp:
        emitter.readSlot(0, item.a, leaveHere)
        if int(item.b) >= start and int(item.b) < stop:
          emitter.branchIfScratchZero(0, blockAt(item.b))
        else:
          emitter.branchIfScratchZero(
            0, exitLabel(item.b, NativeCompleted, index)
          )
      of JumpOp:
        if int(item.a) >= start and int(item.a) < stop:
          when CountedLoops:
            if counted and index == stop - 1:
              emitter.advanceCounter()
          emitter.branch(blockAt(item.a))
        else:
          leaveFor(item.a, NativeCompleted, index)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp:
        emitter.compareSlot(slotOf(item.a), item.b, poolSlot(item.b))
        branchOut(item.c, takenOn(item.op))
      of JumpUnlessGlobalModuloEqualZeroOp:
        # Dividing by one or minus one always leaves no remainder, and
        # minus one would trap on x86, so never emit the divide for those.
        if item.b != 1 and item.b != -1:
          emitter.remainderTest(slotOf(item.a), item.b)
          branchOut(item.c, NotEqualTest)
      else:
        return nil

    ## Falling off the last offset resumes the interpreter at the next one.
    leaveFor(int32(stop), NativeCompleted, stop - 1)

    for (stub, target, status, leaving) in exits:
      emitter.place(stub)
      when CountedLoops:
        if counted and status == NativeCompleted:
          # Charge the passes that ran, plus how far the leaving one got.
          emitter.chargeCounted(
            plan.instructions, plan.work,
            plan.partialInstructions[leaving - start],
            plan.partialWork[leaving - start]
          )
        elif spending and status == NativeCompleted:
          emitter.chargeSpending()
      emitter.exitStub(target, int32(ord(status)), writeback)

    ## Shared exit: publish the hoisted globals and budgets, then return.
    emitter.place(writeback)
    for slot, index in hoisted:
      emitter.storeHoisted(slot, int(index) * ValueStride)
    emitter.publishState()
    emitter.endRegion()

    ## Guard failure happens before any global is written, so the loop is
    ## simply handed back untouched for the interpreter to run.
    emitter.place(guardFailed)
    emitter.guardExit(int32(start))

    emitter.resolve()
    let size = emitter.code.len * sizeof(emitter.code[0])
    if size > MaxRegionBytes:
      return nil

    result = Region(
      start: int32(start), stop: int32(stop), hoisted: hoisted, size: size
    )
    result.listing = newSeq[byte](size)
    if size > 0:
      copyMem(result.listing[0].addr, emitter.code[0].addr, size)
    result.buffer = initCodeBuffer(size)
    result.buffer.write(emitter.code)
    result.buffer.seal()
    result.call = cast[NativeCall](result.buffer.entry)

proc invoke*(region: Region, context: var NativeContext): NativeStatus
    {.raises: [].} =
  ## Runs one compiled loop and reports why it returned.
  NativeStatus(region.call(context.addr))

proc compileLoops*(code: seq[Instruction], globals, slots: int,
    extents: seq[ArrayExtent] = @[], constants: seq[int32] = @[],
    hostData = 0): seq[Region]
    {.raises: [BasicError].} =
  ## Compiles every backward-branching loop the code generator models.
  ## The result is indexed by bytecode offset, so the interpreter reaches
  ## a compiled loop with one load rather than a lookup.
  if not layoutMatches():
    return
  for index in 0 ..< code.len:
    var target = 0'i32
    if not code[index].branchTarget(target):
      continue
    if int(target) > index or int(target) < 0:
      continue
    if result.len > 0 and result[int(target)] != nil:
      continue
    var region: Region = nil
    try:
      region = compileRegion(
        code, int(target), index + 1, globals, slots, extents,
        constants, hostData
      )
    except BasicError:
      region = nil
    if region != nil:
      if result.len == 0:
        result = newSeq[Region](code.len)
      result[int(target)] = region
