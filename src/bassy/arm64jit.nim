## The AArch64 half of the code generator, included by jit.nim when the
## target is arm64. It supplies the emitters the walker there calls.
##
## x19  context            x20  instruction budget   x21  work budget
## x22  globals            x23  current frame        x24  offset table
## x25  array cells        x26  arguments            x27  frames
## x28  register file
## x9 .. x15  working registers;  x16  far addresses;  x17  one cell
##
## Everything long lived sits in a register the platform's convention
## keeps across a call, so calling back into the interpreter's code
## costs no saving beyond the two budgets it may charge.

const
  Context = x19
  Instructions = x20
  Work = x21
  GlobalsBase = x22
  RegistersBase = x23
  TableBase = x24
  MemoryBase = x25
  ArgumentsBase = x26
  FramesBase = x27
  FileBase = x28
  Temps = [x9, x10, x11, x12, x13, x14, x15]
  Far = x16
  Cell = x17
  ## The saved registers, then room to keep up to fourteen registers
  ## across a direct call to a query.
  FrameBytes = 208
  SpillOffset = 96
  NearBytes = 4095 - ValuePayload

proc temp(index: int): Register {.inline, raises: [].} =
  ## Returns one working register.
  Temps[index]

proc nativeCondition(check: Check): Condition {.raises: [].} =
  ## Maps a neutral outcome onto the architecture's encoding.
  case check
  of EqualCheck: EqualCondition
  of NotEqualCheck: NotEqualCondition
  of LessCheck: LessCondition
  of LessEqualCheck: LessEqualCondition
  of GreaterCheck: GreaterCondition
  of GreaterEqualCheck: GreaterEqualCondition

proc inverse(condition: Condition): Condition {.raises: [].} =
  ## Returns the condition that holds exactly when this one does not.
  Condition(ord(condition) xor 1)

type
  Emitter = object
    ## The assembler plus whether branches must reach anywhere at all.
    code: Assembler
    far: bool
    limit: int
    outside: Label

proc label(e: var Emitter): Label {.inline, raises: [].} =
  ## Reserves a label.
  e.code.label()

proc place(e: var Emitter, target: Label) {.inline, raises: [].} =
  ## Places a label here.
  e.code.place(target)

proc jump(e: var Emitter, target: Label) {.raises: [].} =
  ## Jumps unconditionally.
  e.code.branch(target)

proc jumpWhen(e: var Emitter, condition: Condition, target: Label)
    {.raises: [].} =
  ## Jumps when a condition holds, however far away the target is.
  if e.far:
    let skip = e.code.label()
    e.code.branchIf(condition.inverse, skip)
    e.code.branch(target)
    e.code.place(skip)
  else:
    e.code.branchIf(condition, target)

proc jumpIfZero(e: var Emitter, register: Register, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds zero.
  if e.far:
    let skip = e.code.label()
    e.code.branchIfNotZero(Word32, register, skip)
    e.code.branch(target)
    e.code.place(skip)
  else:
    e.code.branchIfZero(Word32, register, target)

proc jumpIfNotZero(e: var Emitter, register: Register, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds anything but zero.
  if e.far:
    let skip = e.code.label()
    e.code.branchIfZero(Word32, register, skip)
    e.code.branch(target)
    e.code.place(skip)
  else:
    e.code.branchIfNotZero(Word32, register, target)

proc withinProgram(e: var Emitter, offset: Register)
    {.raises: [BasicError].} =
  ## Sends an offset that is not one of the program's own to the block
  ## past the end, which refuses it, instead of reading a table entry
  ## that is not there. One unsigned comparison covers both ends.
  e.code.loadImmediate(Word32, Temps[6], int64(e.limit))
  e.code.compareRegister(Word32, offset, Temps[6])
  e.jumpWhen(CarrySetCondition, e.outside)

proc reach(e: var Emitter, place: Place): (Register, int)
    {.raises: [BasicError].} =
  ## Returns a base register and byte offset for a value, working the
  ## address out in full when the offset is too wide to encode.
  var base = Cell
  case place.home
  of SlotHome: base = RegistersBase
  of GlobalHome: base = GlobalsBase
  of ArgumentHome: base = ArgumentsBase
  of HostHome:
    e.code.loadDouble(Cell, Context, ContextHostData)
  of CellHome:
    return (Cell, 0)
  let offset = int(place.index) * ValueStride
  if offset <= NearBytes:
    return (base, offset)
  e.code.loadImmediate(Word64, Far, int64(offset))
  e.code.addRegister(Word64, Far, base, Far)
  (Far, 0)

proc readValue(e: var Emitter, value, tag: int, place: Place)
    {.raises: [BasicError].} =
  ## Reads a value's kind and its 32-bit payload.
  let (base, offset) = e.reach(place)
  e.code.loadByte(temp(tag), base, offset)
  e.code.loadWord(temp(value), base, offset + ValuePayload)

proc writeWhole(e: var Emitter, place: Place, value: int)
    {.raises: [BasicError].} =
  ## Writes a whole number.
  let (base, offset) = e.reach(place)
  e.code.storeByte(zeroRegister, base, offset)
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeKind(e: var Emitter, place: Place, tag, value: int)
    {.raises: [BasicError].} =
  ## Writes a payload under the kind held in a working register.
  let (base, offset) = e.reach(place)
  e.code.storeByte(temp(tag), base, offset)
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeFixed(e: var Emitter, place: Place, value: int)
    {.raises: [BasicError].} =
  ## Writes a fixed-point payload.
  let (base, offset) = e.reach(place)
  e.code.loadImmediate(Word32, temp(5), FixedTag)
  e.code.storeByte(temp(5), base, offset)
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeConstant(e: var Emitter, place: Place, tag: int, bits: int32)
    {.raises: [BasicError].} =
  ## Writes a constant of a known kind.
  e.code.loadImmediate(Word32, temp(6), int64(bits))
  let (base, offset) = e.reach(place)
  if tag == 0:
    e.code.storeByte(zeroRegister, base, offset)
  else:
    e.code.loadImmediate(Word32, temp(5), int64(tag))
    e.code.storeByte(temp(5), base, offset)
  e.code.storeWord(temp(6), base, offset + ValuePayload)

proc copyValue(e: var Emitter, destination, source: Place)
    {.raises: [BasicError].} =
  ## Copies a value entire, whatever kind it holds, as the interpreter
  ## does.
  let (fromBase, fromOffset) = e.reach(source)
  e.code.loadDouble(temp(5), fromBase, fromOffset)
  e.code.loadDouble(temp(6), fromBase, fromOffset + ValuePayload)
  let (toBase, toOffset) = e.reach(destination)
  e.code.storeDouble(temp(5), toBase, toOffset)
  e.code.storeDouble(temp(6), toBase, toOffset + ValuePayload)

proc unlessWhole(e: var Emitter, tag: int, slow: Label)
    {.raises: [].} =
  ## Takes the slow path unless a kind says whole number.
  e.jumpIfNotZero(temp(tag), slow)

proc unlessNumeric(e: var Emitter, tag: int, slow: Label)
    {.raises: [BasicError].} =
  ## Takes the slow path unless a kind says number of either sort.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.jumpWhen(UnsignedGreaterCondition, slow)

proc unlessSame(e: var Emitter, tag, other: int, slow: Label)
    {.raises: [].} =
  ## Takes the slow path unless two kinds agree.
  e.code.compareRegister(Word32, temp(tag), temp(other))
  e.jumpWhen(NotEqualCondition, slow)

proc jumpIfSame(e: var Emitter, tag, other: int, target: Label)
    {.raises: [].} =
  ## Jumps when two kinds agree.
  e.code.compareRegister(Word32, temp(tag), temp(other))
  e.jumpWhen(EqualCondition, target)

proc whenWhole(e: var Emitter, tag: int, target: Label) {.raises: [].} =
  ## Jumps when a kind says whole number.
  e.jumpIfZero(temp(tag), target)

proc unlessFixed(e: var Emitter, tag: int, slow: Label)
    {.raises: [BasicError].} =
  ## Takes the slow path unless a kind says fixed point.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.jumpWhen(NotEqualCondition, slow)

proc toFixed(e: var Emitter, value: int, slow: Label)
    {.raises: [BasicError].} =
  ## Turns a whole number into Q16.16 bits. One outside the fixed-point
  ## range cannot be, which the interpreter refuses, so that goes slow.
  let register = temp(value)
  e.code.loadImmediate(Word32, temp(6), 32767)
  e.code.compareRegister(Word32, register, temp(6))
  e.jumpWhen(GreaterCondition, slow)
  e.code.loadImmediate(Word32, temp(6), -32768)
  e.code.compareRegister(Word32, register, temp(6))
  e.jumpWhen(LessCondition, slow)
  e.code.shiftLeftImmediate(Word32, register, register, FixedShift)

proc scaleWide(e: var Emitter, value, tag: int) {.raises: [BasicError].} =
  ## Widens a number of either kind to sixty-four bits on the fixed-point
  ## scale, where every whole number and every fixed-point one compare
  ## exactly, as the interpreter compares them.
  let register = temp(value)
  let done = e.label()
  e.code.signExtendWord(register, register)
  e.jumpIfNotZero(temp(tag), done)
  e.code.shiftLeftImmediate(Word64, register, register, FixedShift)
  e.place(done)

proc loadWide(e: var Emitter, value: int, bits: int64) {.raises: [].} =
  ## Loads a sixty-four bit constant into a working register.
  e.code.loadImmediate(Word64, temp(value), bits)

proc compareWide(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two widened working registers.
  e.code.compareRegister(Word64, temp(left), temp(right))

proc whenFixed(e: var Emitter, tag: int, target: Label)
    {.raises: [BasicError].} =
  ## Jumps when a kind says fixed point.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.code.branchIf(EqualCondition, target)

proc loadConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [].} =
  ## Loads a constant into a working register.
  e.code.loadImmediate(Word32, temp(value), int64(bits))

proc add(e: var Emitter, left, right: int) {.raises: [].} =
  ## Adds, wrapping.
  e.code.addRegister(Word32, temp(left), temp(left), temp(right))

proc subtract(e: var Emitter, left, right: int) {.raises: [].} =
  ## Subtracts, wrapping.
  e.code.subtractRegister(Word32, temp(left), temp(left), temp(right))

proc multiply(e: var Emitter, left, right: int) {.raises: [].} =
  ## Multiplies, wrapping.
  e.code.multiply(Word32, temp(left), temp(left), temp(right))

proc negate(e: var Emitter, value: int) {.raises: [].} =
  ## Negates, wrapping.
  e.code.negate(Word32, temp(value), temp(value))

proc bitAnd(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits both hold.
  e.code.andRegister(Word32, temp(left), temp(left), temp(right))

proc bitOr(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits either holds.
  e.code.orRegister(Word32, temp(left), temp(left), temp(right))

proc bitXor(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits exactly one holds.
  e.code.xorRegister(Word32, temp(left), temp(left), temp(right))

proc bitNot(e: var Emitter, value: int) {.raises: [].} =
  ## Flips every bit.
  e.code.notRegister(Word32, temp(value), temp(value))

proc quotient(e: var Emitter, left, right: int) {.raises: [].} =
  ## Divides toward zero; the divisor is known not to be zero. The most
  ## negative number over minus one wraps back to itself here, which is
  ## the answer the interpreter defines.
  e.code.signedDivide(Word32, temp(left), temp(left), temp(right))

proc remainder(e: var Emitter, left, right: int) {.raises: [].} =
  ## Leaves what dividing left over, with the sign of the dividend.
  e.code.signedDivide(Word32, temp(6), temp(left), temp(right))
  e.code.multiplySubtract(Word32, temp(left), temp(6), temp(right),
    temp(left))

proc multiplyFixed(e: var Emitter, left, right: int)
    {.raises: [BasicError].} =
  ## Multiplies two Q16.16 numbers through a widened intermediate,
  ## rounding to nearest exactly as the fixed-point library does.
  e.code.signedMultiplyLong(temp(left), temp(left), temp(right))
  e.code.loadImmediate(Word64, temp(6), FixedRounding)
  e.code.addRegister(Word64, temp(left), temp(left), temp(6))
  e.code.arithmeticShiftRight(Word64, temp(left), temp(left), FixedShift)
  e.code.moveRegister(Word32, temp(left), temp(left))

proc widenToFixed(e: var Emitter, value, tag: int, slow: Label)
    {.raises: [BasicError].} =
  ## Turns a number of either kind into its Q16.16 bits, widened to
  ## sixty-four. A whole number outside the fixed-point range cannot
  ## become one, which the interpreter refuses, so that goes slow.
  let register = temp(value)
  let already = e.label()
  let ready = e.label()
  e.whenFixed(tag, already)
  e.code.loadImmediate(Word32, temp(6), 32767)
  e.code.compareRegister(Word32, register, temp(6))
  e.jumpWhen(GreaterCondition, slow)
  e.code.loadImmediate(Word32, temp(6), -32768)
  e.code.compareRegister(Word32, register, temp(6))
  e.jumpWhen(LessCondition, slow)
  e.code.signExtendWord(register, register)
  e.code.shiftLeftImmediate(Word64, register, register, FixedShift)
  e.jump(ready)
  e.place(already)
  e.code.signExtendWord(register, register)
  e.place(ready)

proc divideFixed(e: var Emitter, left, right: int, slow: Label)
    {.raises: [BasicError].} =
  ## Divides two widened Q16.16 numbers, rounding to nearest with halves
  ## going up, for either sign, exactly as the fixed-point library
  ## does: the signs are put right first, half the divisor is added,
  ## and the truncating divide is corrected back to a floor.
  let numerator = temp(left)
  let denominator = temp(right)
  let answer = temp(5)
  let leftOver = temp(6)
  e.code.compareImmediate(Word64, denominator, 0)
  e.jumpWhen(EqualCondition, slow)
  let signsSettled = e.label()
  e.code.branchIf(GreaterCondition, signsSettled)
  e.code.negate(Word64, numerator, numerator)
  e.code.negate(Word64, denominator, denominator)
  e.place(signsSettled)
  e.code.shiftLeftImmediate(Word64, numerator, numerator, FixedShift)
  e.code.shiftRightImmediate(Word64, answer, denominator, 1)
  e.code.addRegister(Word64, numerator, numerator, answer)
  e.code.signedDivide(Word64, answer, numerator, denominator)
  e.code.multiplySubtract(Word64, leftOver, answer, denominator,
    numerator)
  let done = e.label()
  e.code.compareImmediate(Word64, leftOver, 0)
  e.code.branchIf(EqualCondition, done)
  e.code.compareImmediate(Word64, numerator, 0)
  e.code.branchIf(GreaterEqualCondition, done)
  e.code.subtractImmediate(Word64, answer, answer, 1)
  e.place(done)
  e.code.moveRegister(Word32, numerator, answer)

proc compare(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two working registers.
  e.code.compareRegister(Word32, temp(left), temp(right))

proc compareConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [BasicError].} =
  ## Sets flags from a working register against a constant.
  if bits >= 0 and bits <= 4095:
    e.code.compareImmediate(Word32, temp(value), int(bits))
  else:
    e.code.loadImmediate(Word32, temp(6), int64(bits))
    e.code.compareRegister(Word32, temp(value), temp(6))

proc answer(e: var Emitter, value: int, check: Check) {.raises: [].} =
  ## Writes BASIC's -1 for true and zero for false.
  e.code.setOnCondition(Word32, temp(value), nativeCondition(check))

proc jumpOn(e: var Emitter, check: Check, target: Label)
    {.raises: [].} =
  ## Jumps on a comparison outcome.
  e.jumpWhen(nativeCondition(check), target)

proc jumpIfZeroValue(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds zero.
  e.jumpIfZero(temp(value), target)

proc jumpIfNotZeroValue(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds anything but zero.
  e.jumpIfNotZero(temp(value), target)

proc jumpIfLowBits(e: var Emitter, value, bits: int, target: Label)
    {.raises: [BasicError].} =
  ## Jumps when any of a working register's lowest bits is set.
  e.code.testLowBits(Word32, temp(value), bits)
  e.jumpWhen(NotEqualCondition, target)

proc cellAddress(e: var Emitter, index: int, extent: ArrayExtent,
    slow: Label) {.raises: [].} =
  ## Bounds checks an index and leaves the cell's address in Cell. One
  ## unsigned comparison covers both ends, as the interpreter's does.
  let position = temp(index)
  e.code.loadImmediate(Word32, temp(6), int64(extent.length))
  e.code.compareRegister(Word32, position, temp(6))
  e.jumpWhen(CarrySetCondition, slow)
  e.code.loadImmediate(Word32, temp(6), int64(extent.base))
  e.code.addRegister(Word32, temp(6), temp(6), position)
  e.code.addRegister(Word64, Cell, MemoryBase, temp(6), 4)

proc charge(e: var Emitter, instructions, work: int32)
    {.raises: [BasicError].} =
  ## Charges both budgets, already known to cover it, without looking.
  if instructions <= 4095:
    e.code.subtractImmediate(Word64, Instructions, Instructions,
      int(instructions))
  else:
    e.code.loadImmediate(Word64, temp(5), int64(instructions))
    e.code.subtractRegister(Word64, Instructions, Instructions, temp(5))
  if work <= 4095:
    e.code.subtractImmediate(Word64, Work, Work, int(work))
  else:
    e.code.loadImmediate(Word64, temp(6), int64(work))
    e.code.subtractRegister(Word64, Work, Work, temp(6))

proc meter(e: var Emitter, instructions, work: int32, slow: Label,
    needInstructions = int64(instructions), needWork = int64(work))
    {.raises: [BasicError].} =
  ## Checks both budgets hold what is needed before charging either, as
  ## the interpreter does. What is needed can be more than this block
  ## costs, when one look is to cover every block until the next.
  for (budget, need) in [(Instructions, needInstructions),
      (Work, needWork)]:
    if need <= 4095:
      e.code.compareImmediate(Word64, budget, int(need))
    else:
      e.code.loadImmediate(Word64, temp(5), need)
      e.code.compareRegister(Word64, budget, temp(5))
    e.jumpWhen(LessCondition, slow)
  e.charge(instructions, work)

proc frameOf(e: var Emitter, base: Register, index: Register)
    {.raises: [].} =
  ## Points a register at one register-file slot by its absolute index.
  e.code.addRegister(Word64, base, FileBase, index, 4)

proc copyValues(e: var Emitter, destination, source: Register,
    count: int) {.raises: [BasicError].} =
  ## Copies a run of whole values, in a loop once there are many.
  if count <= 8:
    for index in 0 ..< count:
      e.code.loadDouble(temp(5), source, index * ValueStride)
      e.code.loadDouble(temp(6), source, index * ValueStride + ValuePayload)
      e.code.storeDouble(temp(5), destination, index * ValueStride)
      e.code.storeDouble(temp(6), destination,
        index * ValueStride + ValuePayload)
    return
  e.code.moveRegister(Word64, temp(2), source)
  e.code.moveRegister(Word64, temp(3), destination)
  e.code.loadImmediate(Word32, temp(4), int64(count))
  let again = e.label()
  e.place(again)
  e.code.loadDouble(temp(5), temp(2), 0)
  e.code.loadDouble(temp(6), temp(2), ValuePayload)
  e.code.storeDouble(temp(5), temp(3), 0)
  e.code.storeDouble(temp(6), temp(3), ValuePayload)
  e.code.addImmediate(Word64, temp(2), temp(2), ValueStride)
  e.code.addImmediate(Word64, temp(3), temp(3), ValueStride)
  e.code.subtractImmediate(Word32, temp(4), temp(4), 1)
  e.code.branchIfNotZero(Word32, temp(4), again)

proc clearValues(e: var Emitter, destination: Register, count: int)
    {.raises: [BasicError].} =
  ## Zeroes a run of values, in a loop once there are many.
  if count <= 8:
    for index in 0 ..< count:
      e.code.storeDouble(zeroRegister, destination, index * ValueStride)
      e.code.storeDouble(zeroRegister, destination,
        index * ValueStride + ValuePayload)
    return
  e.code.moveRegister(Word64, temp(3), destination)
  e.code.loadImmediate(Word32, temp(4), int64(count))
  let again = e.label()
  e.place(again)
  e.code.storeDouble(zeroRegister, temp(3), 0)
  e.code.storeDouble(zeroRegister, temp(3), ValuePayload)
  e.code.addImmediate(Word64, temp(3), temp(3), ValueStride)
  e.code.subtractImmediate(Word32, temp(4), temp(4), 1)
  e.code.branchIfNotZero(Word32, temp(4), again)

proc enterRoutine(e: var Emitter, gosub: bool, calleeId: int32,
    calleeRegisters, calleeParameters, callerRegisters: int32,
    resumeAt: int32, limits: CallLimits, slow: Label)
    {.raises: [BasicError].} =
  ## Pushes a frame into the interpreter's own array and moves the
  ## current frame on, refusing the same two ceilings it refuses.
  let depth = temp(0)
  let oldBase = temp(1)
  let newBase = temp(2)
  let frame = temp(3)
  e.code.loadWord(depth, Context, ContextDepth)
  e.code.loadImmediate(Word32, temp(6), int64(limits.frames) - 1)
  e.code.compareRegister(Word32, depth, temp(6))
  e.jumpWhen(GreaterEqualCondition, slow)
  e.code.loadWord(oldBase, Context, ContextBase)
  e.code.loadImmediate(Word32, temp(6), int64(callerRegisters))
  e.code.addRegister(Word32, newBase, oldBase, temp(6))
  e.code.loadImmediate(Word32, temp(6),
    int64(limits.slots) - int64(calleeRegisters))
  e.code.compareRegister(Word32, newBase, temp(6))
  e.jumpWhen(GreaterCondition, slow)

  e.code.addRegister(Word64, frame, FramesBase, depth, 4)
  e.code.storeWord(oldBase, frame, FrameBase)
  e.code.loadWord(temp(4), Context, ContextRoutine)
  e.code.storeWord(temp(4), frame, FrameRoutine)
  e.code.loadImmediate(Word32, temp(4), int64(resumeAt))
  e.code.storeWord(temp(4), frame, FrameReturn)
  if gosub:
    e.code.loadImmediate(Word32, temp(4), 1)
    e.code.storeWord(temp(4), frame, FrameTag)
  else:
    e.code.storeWord(zeroRegister, frame, FrameTag)

  e.code.addImmediate(Word32, depth, depth, 1)
  e.code.storeWord(depth, Context, ContextDepth)
  e.code.storeWord(newBase, Context, ContextBase)
  e.code.loadImmediate(Word32, temp(4), int64(calleeId))
  e.code.storeWord(temp(4), Context, ContextRoutine)

  # A GOSUB hands the callee a copy of the caller's slots; a call clears
  # them and lays the arguments over the first few, in that order.
  e.code.moveRegister(Word64, frame, RegistersBase)
  e.frameOf(RegistersBase, newBase)
  if gosub:
    e.copyValues(RegistersBase, frame, int(calleeRegisters))
  else:
    e.clearValues(RegistersBase, int(calleeRegisters))
    e.copyValues(RegistersBase, ArgumentsBase, int(calleeParameters))

proc leaveRoutine(e: var Emitter, parameters: int32, exitSub: bool,
    slow: Label) {.raises: [BasicError].} =
  ## Pops a frame and jumps to wherever it said to carry on. A GOSUB
  ## frame first hands the shared parameters back to the caller. Leaving
  ## a sub outright only goes this way when its own frame is on top.
  ## Nothing is written until every refusal has been passed, the offset
  ## it would carry on at included, so a refusal leaves the frame on.
  let depth = temp(0)
  let frame = temp(1)
  let base = temp(2)
  let resume = temp(3)
  e.code.loadWord(depth, Context, ContextDepth)
  e.jumpIfZero(depth, slow)
  e.code.subtractImmediate(Word32, depth, depth, 1)
  e.code.addRegister(Word64, frame, FramesBase, depth, 4)
  if exitSub:
    e.code.loadByte(temp(4), frame, FrameTag)
    e.jumpIfNotZero(temp(4), slow)
  e.code.loadWord(resume, frame, FrameReturn)
  e.withinProgram(resume)
  e.code.storeWord(depth, Context, ContextDepth)
  if parameters > 0:
    let plain = e.label()
    e.code.loadByte(temp(4), frame, FrameTag)
    e.code.compareImmediate(Word32, temp(4), 1)
    e.code.branchIf(NotEqualCondition, plain)
    e.code.loadWord(base, frame, FrameBase)
    e.frameOf(Far, base)
    e.copyValues(Far, RegistersBase, int(parameters))
    e.place(plain)
  # A long copy works through the same registers, so what it needs from
  # the frame is read again after it rather than kept across it.
  e.code.loadWord(base, frame, FrameBase)
  e.code.loadWord(resume, frame, FrameReturn)
  e.code.storeWord(base, Context, ContextBase)
  e.code.loadWord(temp(4), frame, FrameRoutine)
  e.code.storeWord(temp(4), Context, ContextRoutine)
  e.code.storeWord(resume, Context, ContextOffset)
  e.frameOf(RegistersBase, base)
  e.code.addRegister(Word64, temp(4), TableBase, resume, 3)
  e.code.loadDouble(temp(4), temp(4), 0)
  e.code.jumpRegister(temp(4))

proc callSlow(e: var Emitter, offset: int32, routine: Label)
    {.raises: [].} =
  ## Runs the interpreter's own code for one instruction.
  e.code.loadImmediate(Word32, x1, int64(offset))
  e.code.branchLink(routine)

proc slowRoutine(e: var Emitter, failed: Label, helper: int)
    {.raises: [BasicError].} =
  ## The one place compiled code calls out. The budgets go into the
  ## context for the interpreter's code to charge, and come back from it
  ## along with the frame, since a call or a return may have moved it.
  ## Every storage base comes back too: host code may have replaced a
  ## buffer, and nothing held from before the call may be trusted after.
  e.code.storePair(framePointer, linkRegister, stackPointer, -16, true)
  e.code.storeDouble(Instructions, Context, ContextInstructions)
  e.code.storeDouble(Work, Context, ContextWork)
  e.code.moveRegister(Word64, x0, Context)
  e.code.loadDouble(temp(0), Context, helper)
  e.code.callRegister(temp(0))
  e.code.moveRegister(Word32, temp(0), x0)
  e.code.loadDouble(Instructions, Context, ContextInstructions)
  e.code.loadDouble(Work, Context, ContextWork)
  e.code.loadDouble(GlobalsBase, Context, 0)
  e.code.loadDouble(MemoryBase, Context, ContextMemory)
  e.code.loadDouble(ArgumentsBase, Context, ContextArguments)
  e.code.loadDouble(FramesBase, Context, ContextFrames)
  e.code.loadDouble(FileBase, Context, ContextRegisterFile)
  e.code.loadWord(temp(1), Context, ContextBase)
  e.frameOf(RegistersBase, temp(1))
  e.code.loadPair(framePointer, linkRegister, stackPointer, 16, true)
  e.code.branchIfNotZero(Word32, temp(0), failed)
  e.code.returnToCaller()

proc dispatch(e: var Emitter) {.raises: [BasicError].} =
  ## Jumps to the block for whatever offset the context names.
  e.code.loadWord(temp(0), Context, ContextOffset)
  e.withinProgram(temp(0))
  e.code.addRegister(Word64, temp(1), TableBase, temp(0), 3)
  e.code.loadDouble(temp(1), temp(1), 0)
  e.code.jumpRegister(temp(1))

proc prologue(e: var Emitter) {.raises: [BasicError].} =
  ## Saves what the platform says to keep and loads the machine state.
  e.code.storePair(framePointer, linkRegister, stackPointer, -FrameBytes,
    true)
  e.code.storePair(x19, x20, stackPointer, 16)
  e.code.storePair(x21, x22, stackPointer, 32)
  e.code.storePair(x23, x24, stackPointer, 48)
  e.code.storePair(x25, x26, stackPointer, 64)
  e.code.storePair(x27, x28, stackPointer, 80)
  e.code.moveRegister(Word64, Context, x0)
  e.code.loadDouble(GlobalsBase, Context, 0)
  e.code.loadDouble(Instructions, Context, ContextInstructions)
  e.code.loadDouble(Work, Context, ContextWork)
  e.code.loadDouble(FileBase, Context, ContextRegisterFile)
  e.code.loadDouble(TableBase, Context, ContextTable)
  e.code.loadDouble(MemoryBase, Context, ContextMemory)
  e.code.loadDouble(ArgumentsBase, Context, ContextArguments)
  e.code.loadDouble(FramesBase, Context, ContextFrames)
  e.code.loadWord(temp(0), Context, ContextBase)
  e.frameOf(RegistersBase, temp(0))

proc restoreAndReturn(e: var Emitter) {.raises: [BasicError].} =
  ## Restores what the platform says to keep and returns x0 as it is.
  e.code.loadPair(x19, x20, stackPointer, 16)
  e.code.loadPair(x21, x22, stackPointer, 32)
  e.code.loadPair(x23, x24, stackPointer, 48)
  e.code.loadPair(x25, x26, stackPointer, 64)
  e.code.loadPair(x27, x28, stackPointer, 80)
  e.code.loadPair(framePointer, linkRegister, stackPointer, FrameBytes,
    true)
  e.code.returnToCaller()

proc epilogue(e: var Emitter, status: NativeStatus)
    {.raises: [BasicError].} =
  ## Restores what the platform says to keep and returns a status.
  e.code.loadImmediate(Word32, x0, int64(ord(status)))
  e.restoreAndReturn()

proc leaveWithAnswer(e: var Emitter) {.raises: [BasicError].} =
  ## Returns whatever status the interpreter's code answered with.
  e.code.moveRegister(Word32, x0, temp(0))
  e.restoreAndReturn()

## Globals held in registers
##
## Inside a specialised loop its globals live in the registers below,
## proved whole numbers on the way in. Nothing in such a loop calls out,
## so registers the convention lets a callee clobber are safe to use.

const Hoisting* = [x0, x1, x2, x3, x4, x5, x6, x7]

proc hoisted(slot: int): Register {.inline, raises: [].} =
  ## Returns the register holding one hoisted global.
  Hoisting[slot]

proc globalAt(e: var Emitter, index: int32): (Register, int)
    {.raises: [BasicError].} =
  ## Returns a base register and byte offset for one global.
  e.reach(global(index))

proc guardHoisted(e: var Emitter, index: int32, failed: Label)
    {.raises: [BasicError].} =
  ## Leaves for the general code unless a global holds a whole number.
  let (base, offset) = e.globalAt(index)
  e.code.loadByte(temp(0), base, offset)
  e.jumpIfNotZero(temp(0), failed)

proc loadHoisted(e: var Emitter, slot: int, index: int32)
    {.raises: [BasicError].} =
  ## Reads one global's payload into its register.
  let (base, offset) = e.globalAt(index)
  e.code.loadWord(hoisted(slot), base, offset + ValuePayload)

proc storeHoisted(e: var Emitter, slot: int, index: int32)
    {.raises: [BasicError].} =
  ## Publishes one register back as a whole number.
  let (base, offset) = e.globalAt(index)
  e.code.storeByte(zeroRegister, base, offset)
  e.code.storeWord(hoisted(slot), base, offset + ValuePayload)

proc beginHoisting(e: var Emitter) {.raises: [].} =
  ## The globals stay addressable throughout, so nothing to prepare.
  discard

proc endHoisting(e: var Emitter) {.raises: [].} =
  ## Nothing borrowed, so nothing to give back.
  discard

proc setHoisted(e: var Emitter, slot: int, bits: int32) {.raises: [].} =
  ## Loads a constant into a hoisted global.
  e.code.loadImmediate(Word32, hoisted(slot), int64(bits))

proc copyHoisted(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Copies one hoisted global into another.
  e.code.moveRegister(Word32, hoisted(destination), hoisted(source))

proc addHoisted(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Adds one hoisted global into another, wrapping.
  e.code.addRegister(Word32, hoisted(destination), hoisted(destination),
    hoisted(source))

proc addHoistedConstant(e: var Emitter, slot: int, bits: int32)
    {.raises: [BasicError].} =
  ## Adds a constant to a hoisted global, wrapping.
  let target = hoisted(slot)
  if bits >= 0 and bits <= 4095:
    e.code.addImmediate(Word32, target, target, int(bits))
  elif bits < 0 and bits >= -4095:
    e.code.subtractImmediate(Word32, target, target, int(-bits))
  else:
    e.code.loadImmediate(Word32, temp(6), int64(bits))
    e.code.addRegister(Word32, target, target, temp(6))

proc hoistedToTemp(e: var Emitter, value, slot: int) {.raises: [].} =
  ## Copies a hoisted global into a working register.
  e.code.moveRegister(Word32, temp(value), hoisted(slot))

proc tempToHoisted(e: var Emitter, slot, value: int) {.raises: [].} =
  ## Copies a working register into a hoisted global.
  e.code.moveRegister(Word32, hoisted(slot), temp(value))

proc addTempToHoisted(e: var Emitter, slot, value: int) {.raises: [].} =
  ## Adds a working register into a hoisted global, wrapping.
  e.code.addRegister(Word32, hoisted(slot), hoisted(slot), temp(value))

proc writeFromHoisted(e: var Emitter, place: Place, slot: int)
    {.raises: [BasicError].} =
  ## Writes a hoisted global, always a whole number, somewhere in memory.
  let (base, offset) = e.reach(place)
  e.code.storeByte(zeroRegister, base, offset)
  e.code.storeWord(hoisted(slot), base, offset + ValuePayload)

proc compareHoisted(e: var Emitter, slot: int, bits: int32)
    {.raises: [BasicError].} =
  ## Sets flags from a hoisted global against a constant.
  if bits >= 0 and bits <= 4095:
    e.code.compareImmediate(Word32, hoisted(slot), int(bits))
  else:
    e.code.loadImmediate(Word32, temp(6), int64(bits))
    e.code.compareRegister(Word32, hoisted(slot), temp(6))

## Values held in registers across a block
##
## A block's fast version keeps the slots and globals it touches in the
## registers below. Nothing in the pool outlives the block: every held
## value is written back before anything else could look at memory.

const
  Pool* = [x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13]
  FastScratch = x14

proc pooled(index: int): Register {.inline, raises: [].} =
  ## Returns one pool register.
  Pool[index]

proc fastLoad(e: var Emitter, payload, tag: int, place: Place,
    deopt: Label) {.raises: [BasicError].} =
  ## Reads a value's kind and payload, taking the deopt path unless it
  ## is a number of either kind.
  let (base, offset) = e.reach(place)
  e.code.loadByte(pooled(tag), base, offset)
  e.code.loadWord(pooled(payload), base, offset + ValuePayload)
  e.code.compareImmediate(Word32, pooled(tag), FixedTag)
  e.jumpWhen(UnsignedGreaterCondition, deopt)

proc fastStore(e: var Emitter, place: Place, payload, tag, kind: int)
    {.raises: [BasicError].} =
  ## Writes a value back: its kind from a register, or the known kind.
  let (base, offset) = e.reach(place)
  if tag >= 0:
    e.code.storeByte(pooled(tag), base, offset)
  elif kind == 0:
    e.code.storeByte(zeroRegister, base, offset)
  else:
    e.code.loadImmediate(Word32, FastScratch, int64(kind))
    e.code.storeByte(FastScratch, base, offset)
  e.code.storeWord(pooled(payload), base, offset + ValuePayload)

proc fastMove(e: var Emitter, destination, source: int) {.raises: [].} =
  ## Copies one pool register into another.
  e.code.moveRegister(Word32, pooled(destination), pooled(source))

proc fastConstant(e: var Emitter, destination: int, bits: int32)
    {.raises: [].} =
  ## Loads a constant into a pool register.
  e.code.loadImmediate(Word32, pooled(destination), int64(bits))

proc fastAdd(e: var Emitter, destination, source: int) {.raises: [].} =
  ## Adds, wrapping.
  e.code.addRegister(Word32, pooled(destination), pooled(destination),
    pooled(source))

proc fastSubtract(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Subtracts, wrapping.
  e.code.subtractRegister(Word32, pooled(destination),
    pooled(destination), pooled(source))

proc fastMultiply(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Multiplies, wrapping.
  e.code.multiply(Word32, pooled(destination), pooled(destination),
    pooled(source))

proc fastMultiplyFixed(e: var Emitter, destination, source: int)
    {.raises: [BasicError].} =
  ## Multiplies two Q16.16 numbers, rounding as the library does.
  let target = pooled(destination)
  e.code.signedMultiplyLong(target, target, pooled(source))
  e.code.loadImmediate(Word64, FastScratch, FixedRounding)
  e.code.addRegister(Word64, target, target, FastScratch)
  e.code.arithmeticShiftRight(Word64, target, target, FixedShift)
  e.code.moveRegister(Word32, target, target)

proc fastNegate(e: var Emitter, destination: int) {.raises: [].} =
  ## Negates, wrapping.
  e.code.negate(Word32, pooled(destination), pooled(destination))

proc fastToFixed(e: var Emitter, destination: int, deopt: Label)
    {.raises: [BasicError].} =
  ## Turns a whole number into Q16.16 bits, or takes the deopt path when
  ## it is outside the fixed-point range, which the interpreter refuses.
  let target = pooled(destination)
  e.code.loadImmediate(Word32, FastScratch, 32767)
  e.code.compareRegister(Word32, target, FastScratch)
  e.jumpWhen(GreaterCondition, deopt)
  e.code.loadImmediate(Word32, FastScratch, -32768)
  e.code.compareRegister(Word32, target, FastScratch)
  e.jumpWhen(LessCondition, deopt)
  e.code.shiftLeftImmediate(Word32, target, target, FixedShift)

proc fastCompare(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two pool registers.
  e.code.compareRegister(Word32, pooled(left), pooled(right))

proc fastCompareWide(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two widened pool registers.
  e.code.compareRegister(Word64, pooled(left), pooled(right))

proc fastCompareConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [BasicError].} =
  ## Sets flags from a pool register against a constant.
  if bits >= 0 and bits <= 4095:
    e.code.compareImmediate(Word32, pooled(value), int(bits))
  else:
    e.code.loadImmediate(Word32, FastScratch, int64(bits))
    e.code.compareRegister(Word32, pooled(value), FastScratch)

proc fastLoadWide(e: var Emitter, destination: int, bits: int64)
    {.raises: [].} =
  ## Loads a sixty-four bit constant into a pool register.
  e.code.loadImmediate(Word64, pooled(destination), bits)

proc fastScaleWide(e: var Emitter, value, tag: int)
    {.raises: [BasicError].} =
  ## Widens a number to sixty-four bits on the fixed-point scale, its
  ## kind read from a register.
  let target = pooled(value)
  let done = e.label()
  e.code.signExtendWord(target, target)
  e.jumpIfNotZero(pooled(tag), done)
  e.code.shiftLeftImmediate(Word64, target, target, FixedShift)
  e.place(done)

proc fastAnswer(e: var Emitter, destination: int, check: Check)
    {.raises: [].} =
  ## Writes BASIC's -1 for true and zero for false.
  e.code.setOnCondition(Word32, pooled(destination),
    nativeCondition(check))

proc fastJumpIfZero(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a pool register holds zero.
  e.jumpIfZero(pooled(value), target)

proc fastJumpIfNotZero(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a pool register holds anything but zero.
  e.jumpIfNotZero(pooled(value), target)

proc fastJumpIfDiffer(e: var Emitter, left, right: int, target: Label)
    {.raises: [].} =
  ## Jumps when two pool registers differ.
  e.code.compareRegister(Word32, pooled(left), pooled(right))
  e.jumpWhen(NotEqualCondition, target)

proc fastCellAddress(e: var Emitter, index: int, extent: ArrayExtent,
    deopt: Label) {.raises: [BasicError].} =
  ## Bounds checks an index held in the pool, leaving it untouched, and
  ## leaves the cell's address in Cell.
  let position = pooled(index)
  e.code.loadImmediate(Word32, FastScratch, int64(extent.length))
  e.code.compareRegister(Word32, position, FastScratch)
  e.jumpWhen(CarrySetCondition, deopt)
  e.code.loadImmediate(Word32, FastScratch, int64(extent.base))
  e.code.addRegister(Word32, FastScratch, FastScratch, position)
  e.code.addRegister(Word64, Cell, MemoryBase, FastScratch, 4)

proc callQuery(e: var Emitter, offset: int32, keep: seq[Register],
    refused: Label) {.raises: [BasicError].} =
  ## Asks a query directly, keeping the registers that hold live values on
  ## the stack across it, since a callee is free to clobber them. Leaves
  ## for the refused path when the query answers that it did not answer.
  for index, register in keep:
    e.code.storeDouble(register, stackPointer, SpillOffset + index * 8)
  e.code.moveRegister(Word64, x0, Context)
  e.code.loadImmediate(Word32, x1, int64(offset))
  e.code.loadDouble(FastScratch, Context, ContextQueryStep)
  e.code.callRegister(FastScratch)
  e.code.moveRegister(Word32, FastScratch, x0)
  for index, register in keep:
    e.code.loadDouble(register, stackPointer, SpillOffset + index * 8)
  e.jumpIfNotZero(FastScratch, refused)

## Strings read in place
##
## A string value is its storage's owner in the high half and a handle
## into the span table in the low half. Everything is checked just as
## the interpreter checks it, and anything amiss takes the slow path,
## which raises the interpreter's own error.

proc stringSpan(e: var Emitter, place: Place, reference, start,
    length: Register, slow: Label) {.raises: [BasicError].} =
  ## Reads a string's start and length, or takes the slow path unless
  ## the value is a string of this storage's current generation.
  let (base, offset) = e.reach(place)
  e.code.loadByte(start, base, offset)
  e.code.compareImmediate(Word32, start, StringTag)
  e.jumpWhen(NotEqualCondition, slow)
  e.code.loadDouble(reference, base, offset + ValuePayload)
  e.code.loadDouble(length, Context, ContextStringOwner)
  e.code.loadWord(length, length, 0)
  e.jumpIfZero(length, slow)
  e.code.shiftRightImmediate(Word64, start, reference, 32)
  e.code.compareRegister(Word32, start, length)
  e.jumpWhen(NotEqualCondition, slow)
  e.code.loadDouble(length, Context, ContextStringSpans)
  e.code.loadDouble(start, length, 0)
  e.code.moveRegister(Word32, reference, reference)
  e.code.compareRegister(Word64, reference, start)
  e.jumpWhen(CarrySetCondition, slow)
  e.code.loadDouble(length, length, 8)
  e.code.addRegister(Word64, length, length, reference, 3)
  e.code.loadWord(start, length, 8)
  e.code.loadWord(length, length, 12)

proc chargeWork(e: var Emitter, cost: Register, slow: Label)
    {.raises: [].} =
  ## Charges work worked out at run time, or takes the slow path when it
  ## cannot be afforded, where the interpreter raises.
  e.code.compareRegister(Word64, Work, cost)
  e.jumpWhen(LessCondition, slow)
  e.code.subtractRegister(Word64, Work, Work, cost)

proc arenaBase(e: var Emitter, destination: Register)
    {.raises: [BasicError].} =
  ## Points at the first byte of the string arena.
  e.code.loadDouble(destination, Context, ContextStringArena)
  e.code.loadDouble(destination, destination, 8)
  e.code.addImmediate(Word64, destination, destination, 8)

proc stringFunction(e: var Emitter, function: TextFunction, slow: Label)
    {.raises: [BasicError].} =
  ## Answers LEN or ASC of the first argument into the first working
  ## register, charging what the interpreter charges.
  e.stringSpan(argument(0), x0, x1, x2, slow)
  if function == CodeFunction:
    e.jumpIfZero(x2, slow)
  e.code.addImmediate(Word64, x3, x2, 1)
  e.chargeWork(x3, slow)
  if function == LengthFunction:
    e.code.moveRegister(Word32, temp(0), x2)
  else:
    e.arenaBase(x4)
    e.code.addRegister(Word64, x4, x4, x1)
    e.code.loadByte(temp(0), x4, 0)

proc stringEquality(e: var Emitter, left, right: Place, equal: bool,
    slow: Label) {.raises: [BasicError].} =
  ## Answers whether two strings hold the same bytes, into the first
  ## working register, charging both lengths as the interpreter does.
  e.stringSpan(left, x0, x1, x2, slow)
  e.stringSpan(right, x3, x4, x5, slow)
  e.code.addRegister(Word64, x6, x2, x5)
  e.chargeWork(x6, slow)
  let differ = e.label()
  let same = e.label()
  let done = e.label()
  e.code.compareRegister(Word32, x2, x5)
  e.code.branchIf(NotEqualCondition, differ)
  e.arenaBase(x6)
  e.code.addRegister(Word64, x1, x6, x1)
  e.code.addRegister(Word64, x4, x6, x4)
  e.code.branchIfZero(Word32, x2, same)
  let again = e.label()
  e.place(again)
  e.code.loadByte(x7, x1, 0)
  e.code.loadByte(x8, x4, 0)
  e.code.compareRegister(Word32, x7, x8)
  e.code.branchIf(NotEqualCondition, differ)
  e.code.addImmediate(Word64, x1, x1, 1)
  e.code.addImmediate(Word64, x4, x4, 1)
  e.code.subtractImmediate(Word32, x2, x2, 1)
  e.code.branchIfNotZero(Word32, x2, again)
  e.place(same)
  e.code.loadImmediate(Word32, temp(0), if equal: -1 else: 0)
  e.jump(done)
  e.place(differ)
  e.code.loadImmediate(Word32, temp(0), if equal: 0 else: -1)
  e.place(done)

proc jumpUnlessTag(e: var Emitter, tag: int, value: int, target: Label)
    {.raises: [BasicError].} =
  ## Jumps unless a working register holds one particular tag.
  e.code.compareImmediate(Word32, temp(tag), value)
  e.jumpWhen(NotEqualCondition, target)

proc halt(e: var Emitter, offset: int32) {.raises: [BasicError].} =
  ## Publishes the budgets and where the program stopped, then returns.
  e.code.storeDouble(Instructions, Context, ContextInstructions)
  e.code.storeDouble(Work, Context, ContextWork)
  e.code.loadImmediate(Word32, temp(0), int64(offset))
  e.code.storeWord(temp(0), Context, ContextOffset)
  e.epilogue(NativeCompleted)

proc finish(e: var Emitter): seq[byte] {.raises: [BasicError].} =
  ## Resolves every branch and returns the finished bytes.
  e.code.resolve()
  result = newSeq[byte](e.code.code.len * 4)
  if result.len > 0:
    copyMem(result[0].addr, e.code.code[0].addr, result.len)

proc offsetBytes(e: Emitter, target: Label): int {.raises: [].} =
  ## Returns where a label ended up, in bytes.
  e.code.offsetOf(target) * 4
