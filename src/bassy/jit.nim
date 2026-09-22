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
    globals*: pointer
    remainingInstructions*: int64
    remainingWork*: int64
    pc*: int32

  NativeCall = proc(context: ptr NativeContext): int32
    {.cdecl, gcsafe, raises: [].}

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
  MaxHoistedGlobals* = 7
  MaxRegionBytes = 32 * 1024

## Region discovery

proc isCompilable(item: Instruction): bool {.raises: [].} =
  ## Reports whether one operation has a modelled integer translation.
  case item.op
  of MeterOp, JumpOp, StoreGlobalImmediateOp, MoveGlobalOp,
      AddGlobalImmediateOp, AddGlobalOp,
      JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp:
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
  else:
    discard

proc branchTarget(item: Instruction, target: var int32): bool
    {.raises: [].} =
  ## Reports whether an operation branches, and to where.
  case item.op
  of JumpOp:
    target = item.a
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

proc planLoop(code: seq[Instruction], start, stop: int): LoopPlan
    {.raises: [].} =
  ## Measures one pass through a loop and reports whether it is countable.
  result.partialInstructions = newSeq[int64](stop - start)
  result.partialWork = newSeq[int64](stop - start)
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
  result.spending = result.passInstructions > 0 and result.passWork > 0
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

proc reachesOutside(code: seq[Instruction], start, stop: int): bool
    {.raises: [].} =
  ## Reports whether the loop can be entered anywhere but its first offset.
  for index in 0 ..< code.len:
    if index >= start and index < stop:
      continue
    var target = 0'i32
    if code[index].branchTarget(target):
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
    Instructions = r12
    Work = r13
    Scratch = r11

  when defined(windows):
    const
      Context = rcx
      Hoisted = [r14, r15, rsi, rdi, r8, r9, r10]
      Saved = [rbx, r12, r13, r14, r15, rsi, rdi]
  else:
    const
      Context = rdi
      Hoisted = [r14, r15, rsi, rcx, r8, r9, r10]
      Saved = [rbx, r12, r13, r14, r15]

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

  proc guardInteger(emitter: var Assembler, base: int, failed: Label)
      {.raises: [BasicError].} =
    ## Leaves the region unless the global at this offset holds an integer.
    emitter.loadByteZeroed(Scratch, GlobalsBase, base)
    emitter.testRegister(Word32, Scratch, Scratch)
    emitter.branchIf(NotEqualCondition, failed)

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

proc compileRegion*(code: seq[Instruction], start, stop: int): Region
    {.raises: [BasicError].} =
  ## Compiles one loop, or returns nil when it is outside the modelled set.
  when not (NativeArm64 or NativeAmd64):
    # No backend for this target: the interpreter is the only path.
    return nil
  else:
    if start < 0 or stop > code.len or start >= stop:
      return nil
    if code.reachesOutside(start, stop):
      return nil

    var hoisted: seq[int32]
    for index in start ..< stop:
      let item = code[index]
      if not item.isCompilable:
        return nil
      item.touchedGlobals(hoisted)
      var target = 0'i32
      if item.branchTarget(target):
        if int(target) < 0 or int(target) > code.len:
          return nil
    if hoisted.len == 0 or hoisted.len > MaxHoistedGlobals:
      return nil
    when NativeArm64:
      # The guard reads the tag through a scaled byte offset.
      for index in hoisted:
        if int(index) * ValueStride + ValuePayload > 4095:
          return nil

    proc slotOf(index: int32): int {.closure, raises: [].} =
      ## Returns which hoisted register holds one global.
      for slot, candidate in hoisted:
        if candidate == index:
          return slot
      -1

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
            if index == start:
              emitter.checkSpending(
                exitLabel(int32(start), NativeCompleted, start)
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

proc compileLoops*(code: seq[Instruction]): seq[Region]
    {.raises: [BasicError].} =
  ## Compiles every backward-branching loop the code generator models.
  ## The result is indexed by bytecode offset, so the interpreter reaches
  ## a compiled loop with one load rather than a lookup.
  for index in 0 ..< code.len:
    var target = 0'i32
    if not code[index].branchTarget(target):
      continue
    if int(target) > index or int(target) < 0:
      continue
    if result.len > 0 and result[int(target)] != nil:
      continue
    let region = compileRegion(code, int(target), index + 1)
    if region != nil:
      if result.len == 0:
        result = newSeq[Region](code.len)
      result[int(target)] = region
