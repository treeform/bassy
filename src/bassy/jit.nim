## Compiles hot integer loops from the register bytecode to machine code.
##
## A region is one backward-branching loop whose every operation is an
## integer operation on global variables. On entry the compiled code proves
## each participating global still holds an integer, hoists it into a
## machine register, and from then on runs without tags, without memory
## traffic, and without dispatch. Any operation the compiler does not
## model, and any value that is not an integer, leaves the loop to the
## interpreter, so the two always agree on results and on budgets.

import
  std/tables,
  bytecode, machine, numbers

export machine.jitSupported

when defined(arm64):
  import arm64

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
    words*: int
    buffer: CodeBuffer
    call: NativeCall

const
  ValueStride = 16
  ValuePayload = 8
  MaxHoistedGlobals* = 7
  MaxRegionWords = 4096

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

when defined(arm64):
  ## AArch64 code generation
  ##
  ## x0   context pointer, live for the whole region
  ## x19  base of the globals array
  ## x20  remaining instruction budget
  ## x21  remaining work budget
  ## x22+ hoisted globals, one per entry in the region's list
  ## x9, x10  scratch

  const
    GlobalsBase = x19
    RemainingInstructions = x20
    RemainingWork = x21
    FirstHoisted = 22
    Scratch = x9
    OtherScratch = x10
    ResumeOffset = x11
    ResumeStatus = x12
    FrameBytes = 96

  proc hoistedRegister(slot: int): Register {.raises: [].} =
    ## Returns the callee-saved register holding one hoisted global.
    Register(uint32(FirstHoisted + slot))

  proc saveRegisters(assembler: var Assembler) {.raises: [BasicError].} =
    ## Preserves the callee-saved registers this region claims.
    assembler.storePair(
      framePointer, linkRegister, stackPointer, -FrameBytes, true
    )
    assembler.storePair(x19, x20, stackPointer, 16)
    assembler.storePair(x21, x22, stackPointer, 32)
    assembler.storePair(x23, x24, stackPointer, 48)
    assembler.storePair(x25, x26, stackPointer, 64)
    assembler.storePair(x27, x28, stackPointer, 80)

  proc restoreRegisters(assembler: var Assembler) {.raises: [BasicError].} =
    ## Restores the callee-saved registers and pops the frame.
    assembler.loadPair(x19, x20, stackPointer, 16)
    assembler.loadPair(x21, x22, stackPointer, 32)
    assembler.loadPair(x23, x24, stackPointer, 48)
    assembler.loadPair(x25, x26, stackPointer, 64)
    assembler.loadPair(x27, x28, stackPointer, 80)
    assembler.loadPair(
      framePointer, linkRegister, stackPointer, FrameBytes, true
    )

  proc compareAgainst(assembler: var Assembler, left: Register, value: int32)
      {.raises: [BasicError].} =
    ## Compares a register with a constant, widening it when necessary.
    if value >= 0 and value <= 4095:
      assembler.compareImmediate(Word32, left, int(value))
    else:
      assembler.loadImmediate(Word32, Scratch, int64(value))
      assembler.compareRegister(Word32, left, Scratch)

  proc addConstant(assembler: var Assembler, target: Register, value: int32)
      {.raises: [BasicError].} =
    ## Adds a constant to a register, widening it when necessary.
    if value >= 0 and value <= 4095:
      assembler.addImmediate(Word32, target, target, int(value))
    elif value < 0 and value >= -4095:
      assembler.subtractImmediate(Word32, target, target, int(-value))
    else:
      assembler.loadImmediate(Word32, Scratch, int64(value))
      assembler.addRegister(Word32, target, target, Scratch)

  proc jumpCondition(op: Op): Condition {.raises: [].} =
    ## Returns the condition on which a fused test takes its branch.
    case op
    of JumpUnlessGlobalEqualImmediateOp: NotEqualCondition
    of JumpUnlessGlobalNotEqualImmediateOp: EqualCondition
    of JumpUnlessGlobalLessImmediateOp: GreaterEqualCondition
    of JumpUnlessGlobalLessEqualImmediateOp: GreaterCondition
    of JumpUnlessGlobalGreaterImmediateOp: LessEqualCondition
    of JumpUnlessGlobalGreaterEqualImmediateOp: LessCondition
    else: AlwaysCondition

proc compileRegion*(code: seq[Instruction], start, stop: int): Region
    {.raises: [BasicError].} =
  ## Compiles one loop, or returns nil when it is outside the modelled set.
  when not defined(arm64):
    return nil
  else:
    if not jitSupported():
      return nil
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
    for index in hoisted:
      if int(index) * ValueStride + ValuePayload > 4095:
        return nil

    var assembler = Assembler()
    var blocks: seq[Label]
    for index in start ..< stop:
      blocks.add(assembler.label())

    proc slotOf(index: int32): int {.closure, raises: [].} =
      ## Returns which hoisted register holds one global.
      for slot, candidate in hoisted:
        if candidate == index:
          return slot
      -1

    template blockAt(offset: int32): Label =
      blocks[int(offset) - start]
    let guardFailed = assembler.label()
    let resume = assembler.label()
    var exits: seq[(Label, int32, NativeStatus)]

    template leaveFor(target: int32, status: NativeStatus) =
      ## Branches to a stub that resumes the interpreter at an offset.
      let stub = assembler.label()
      exits.add((stub, target, status))
      assembler.branch(stub)

    ## Entry: prove every participating global is an integer, then hoist it.
    assembler.saveRegisters()
    assembler.loadDouble(GlobalsBase, x0, 0)
    assembler.loadDouble(RemainingInstructions, x0, 8)
    assembler.loadDouble(RemainingWork, x0, 16)
    for slot, index in hoisted:
      let base = int(index) * ValueStride
      assembler.loadByte(Scratch, GlobalsBase, base)
      assembler.branchIfNotZero(Word32, Scratch, guardFailed)
      assembler.loadWord(
        hoistedRegister(slot), GlobalsBase, base + ValuePayload
      )

    ## Body: one native block per bytecode offset, so branches keep working.
    for index in start ..< stop:
      let item = code[index]
      assembler.place(blockAt(int32(index)))

      template branchOut(target: int32, condition: Condition) =
        ## Takes an in-region branch directly, or leaves through a stub.
        if int(target) >= start and int(target) < stop:
          assembler.branchIf(condition, blockAt(target))
        else:
          let taken = assembler.label()
          let skipped = assembler.label()
          assembler.branchIf(condition, taken)
          assembler.branch(skipped)
          assembler.place(taken)
          leaveFor(target, NativeCompleted)
          assembler.place(skipped)

      case item.op
      of MeterOp:
        # Both budgets are checked before either is charged, exactly as the
        # interpreter does, so a refusal leaves the counters untouched and
        # the interpreter raises the same error when it re-runs this offset.
        assembler.loadImmediate(Word64, Scratch, int64(item.b))
        assembler.loadImmediate(Word64, OtherScratch, int64(item.a))
        let charge = assembler.label()
        let short = assembler.label()
        assembler.compareRegister(Word64, RemainingInstructions, Scratch)
        assembler.branchIf(LessCondition, short)
        assembler.compareRegister(Word64, RemainingWork, OtherScratch)
        assembler.branchIf(GreaterEqualCondition, charge)
        assembler.place(short)
        leaveFor(int32(index), NativeExhausted)
        assembler.place(charge)
        assembler.subtractRegister(
          Word64, RemainingInstructions, RemainingInstructions, Scratch
        )
        assembler.subtractRegister(
          Word64, RemainingWork, RemainingWork, OtherScratch
        )
      of StoreGlobalImmediateOp:
        assembler.loadImmediate(
          Word32, hoistedRegister(slotOf(item.a)), int64(item.b)
        )
      of MoveGlobalOp:
        assembler.moveRegister(
          Word32, hoistedRegister(slotOf(item.a)),
          hoistedRegister(slotOf(item.b))
        )
      of AddGlobalImmediateOp:
        assembler.addConstant(hoistedRegister(slotOf(item.a)), item.b)
      of AddGlobalOp:
        let target = hoistedRegister(slotOf(item.a))
        assembler.addRegister(
          Word32, target, target, hoistedRegister(slotOf(item.b))
        )
      of JumpOp:
        if int(item.a) >= start and int(item.a) < stop:
          assembler.branch(blockAt(item.a))
        else:
          leaveFor(item.a, NativeCompleted)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp:
        assembler.compareAgainst(hoistedRegister(slotOf(item.a)), item.b)
        branchOut(item.c, jumpCondition(item.op))
      of JumpUnlessGlobalModuloEqualZeroOp:
        let source = hoistedRegister(slotOf(item.a))
        assembler.loadImmediate(Word32, Scratch, int64(item.b))
        assembler.signedDivide(Word32, OtherScratch, source, Scratch)
        assembler.multiplySubtract(
          Word32, OtherScratch, OtherScratch, Scratch, source
        )
        assembler.compareImmediate(Word32, OtherScratch, 0)
        branchOut(item.c, NotEqualCondition)
      else:
        return nil

    ## Falling off the last offset resumes the interpreter at the next one.
    leaveFor(int32(stop), NativeCompleted)

    ## Exit stubs: name the resume offset and status, then share one path.
    for (stub, target, status) in exits:
      assembler.place(stub)
      assembler.loadImmediate(Word32, ResumeOffset, int64(target))
      assembler.loadImmediate(Word32, ResumeStatus, int64(ord(status)))
      assembler.branch(resume)

    ## Resume: publish the hoisted globals and the budgets, then return.
    assembler.place(resume)
    for slot, index in hoisted:
      let base = int(index) * ValueStride
      assembler.storeByte(zeroRegister, GlobalsBase, base)
      assembler.storeWord(
        hoistedRegister(slot), GlobalsBase, base + ValuePayload
      )
    assembler.storeDouble(RemainingInstructions, x0, 8)
    assembler.storeDouble(RemainingWork, x0, 16)
    assembler.storeWord(ResumeOffset, x0, 24)
    assembler.moveRegister(Word32, x0, ResumeStatus)
    assembler.restoreRegisters()
    assembler.returnToCaller()

    ## Guard failure happens before any global is written, so the loop is
    ## simply handed back untouched for the interpreter to run.
    assembler.place(guardFailed)
    assembler.loadImmediate(Word32, ResumeOffset, int64(start))
    assembler.storeWord(ResumeOffset, x0, 24)
    assembler.loadImmediate(Word32, x0, int64(ord(NativeGuardFailed)))
    assembler.restoreRegisters()
    assembler.returnToCaller()

    assembler.resolve()
    if assembler.code.len > MaxRegionWords:
      return nil

    result = Region(
      start: int32(start),
      stop: int32(stop),
      hoisted: hoisted,
      words: assembler.code.len
    )
    result.buffer = initCodeBuffer(assembler.code.len * sizeof(uint32))
    result.buffer.write(assembler.code)
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
