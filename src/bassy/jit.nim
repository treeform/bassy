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
  std/tables,
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
    FrameBytes = 96
    MaxDisplacement = 4095

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

  proc compareSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
    ## Sets flags from a hoisted register against a constant.
    let target = slotRegister(slot)
    if value >= 0 and value <= MaxDisplacement:
      emitter.compareImmediate(Word32, target, int(value))
    else:
      emitter.loadImmediate(Word32, Scratch, int64(value))
      emitter.compareRegister(Word32, target, Scratch)

  proc remainderTest(emitter: var Assembler, slot: int, divisor: int32)
      {.raises: [BasicError].} =
    ## Sets flags so NotEqualTest means the remainder is not zero.
    let source = slotRegister(slot)
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
  ## x86-64 code generation, System V calling convention
  ##
  ## rdi  context pointer, live for the whole region
  ## rbx  base of the globals array
  ## r12  remaining instruction budget
  ## r13  remaining work budget
  ## r14, r15, rsi, rcx, r8, r9, r10  hoisted globals
  ## rax and rdx are reserved for the divide;  r11 is scratch

  const
    Context = rdi
    GlobalsBase = rbx
    Instructions = r12
    Work = r13
    Scratch = r11
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

  proc compareSlot(emitter: var Assembler, slot: int, value: int32)
      {.raises: [BasicError].} =
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

    var emitter = Assembler()
    var blocks: seq[Label]
    for index in start ..< stop:
      blocks.add(emitter.label())
    let guardFailed = emitter.label()
    let writeback = emitter.label()
    var exits: seq[(Label, int32, NativeStatus)]

    template blockAt(offset: int32): Label =
      blocks[int(offset) - start]

    template leaveFor(target: int32, status: NativeStatus) =
      ## Branches to a stub that resumes the interpreter at an offset.
      let stub = emitter.label()
      exits.add((stub, target, status))
      emitter.branch(stub)

    ## Entry: prove every participating global is an integer, then hoist it.
    emitter.startRegion()
    for slot, index in hoisted:
      let base = int(index) * ValueStride
      emitter.guardInteger(base, guardFailed)
      emitter.loadHoisted(slot, base)

    ## Body: one native block per bytecode offset, so branches keep working.
    for index in start ..< stop:
      let item = code[index]
      emitter.place(blockAt(int32(index)))

      template branchOut(target: int32, test: Test) =
        ## Takes an in-region branch directly, or leaves through a stub.
        if int(target) >= start and int(target) < stop:
          emitter.branchWhen(test, blockAt(target))
        else:
          let taken = emitter.label()
          let skipped = emitter.label()
          emitter.branchWhen(test, taken)
          emitter.branch(skipped)
          emitter.place(taken)
          leaveFor(target, NativeCompleted)
          emitter.place(skipped)

      case item.op
      of MeterOp:
        let short = emitter.label()
        let past = emitter.label()
        emitter.budgetGate(int64(item.b), int64(item.a), short)
        emitter.branch(past)
        emitter.place(short)
        leaveFor(int32(index), NativeExhausted)
        emitter.place(past)
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
          emitter.branch(blockAt(item.a))
        else:
          leaveFor(item.a, NativeCompleted)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp:
        emitter.compareSlot(slotOf(item.a), item.b)
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
    leaveFor(int32(stop), NativeCompleted)

    for (stub, target, status) in exits:
      emitter.place(stub)
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
    result.buffer = initCodeBuffer(size)
    result.buffer.write(emitter.code)
    result.buffer.seal()
    result.call = cast[NativeCall](result.buffer.entry)

proc invoke*(region: Region, context: var NativeContext): NativeStatus
    {.raises: [].} =
  ## Runs one compiled loop and reports why it returned.
  NativeStatus(region.call(context.addr))

proc compileLoops*(code: seq[Instruction]): Table[int32, Region]
    {.raises: [BasicError].} =
  ## Compiles every backward-branching loop the code generator models.
  for index in 0 ..< code.len:
    var target = 0'i32
    if not code[index].branchTarget(target):
      continue
    if int(target) > index or int(target) < 0:
      continue
    if target in result:
      continue
    let region = compileRegion(code, int(target), index + 1)
    if region != nil:
      result[target] = region
