## The x86-64 half of the code generator, included by jit.nim when the
## target is amd64. It supplies the emitters the walker there calls.
##
## r15  context            r12  instruction budget   r13  work budget
## rbx  globals            rbp  current frame
## rax rcx rsi rdi r8 r9 r10  working registers;  r11  one cell;
## rdx  the divide's high half and a spare
##
## The six long-lived registers are the ones both platform conventions
## keep across a call. Windows also keeps rsi and rdi, so those are
## saved on the way in there. Everything else the program touches
## rarely is read from the context when it is needed.

const
  Context = r15
  Instructions = r12
  Work = r13
  GlobalsBase = rbx
  RegistersBase = rbp
  Temps = [rax, rcx, rsi, rdi, r8, r9, r10]
  Cell = r11
  Spare = rdx

when defined(windows):
  const
    FirstArgument = rcx
    SecondArgument = rdx
    Saved = [rbx, rbp, r12, r13, r14, r15, rsi, rdi]
    ## Four shadow slots for the callee, room to keep seven registers
    ## across a direct call to a query, and eight to realign.
    Padding = 104
    SpillOffset = 32
else:
  const
    FirstArgument = rdi
    SecondArgument = rsi
    Saved = [rbx, rbp, r12, r13, r14, r15]
    ## Room to keep seven registers across a direct call to a query, and
    ## eight to realign.
    Padding = 72
    SpillOffset = 0

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

type
  Emitter = object
    ## The assembler. Every branch here reaches anywhere already, so
    ## there is nothing to widen.
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
  ## Jumps when a condition holds.
  e.code.branchIf(condition, target)

proc withinProgram(e: var Emitter, offset: Register) {.raises: [].} =
  ## Sends an offset that is not one of the program's own to the block
  ## past the end, which refuses it, instead of reading a table entry
  ## that is not there. One unsigned comparison covers both ends.
  e.code.compareImmediate(Word32, offset, int32(e.limit))
  e.jumpWhen(AboveEqualCondition, e.outside)

proc contextField(e: var Emitter, destination: Register, offset: int)
    {.raises: [BasicError].} =
  ## Loads one pointer from the context.
  e.code.loadDouble(destination, Context, offset)

proc reach(e: var Emitter, place: Place): (Register, int)
    {.raises: [BasicError].} =
  ## Returns a base register and byte offset for a value. Displacements
  ## are thirty-two bits wide here, so every index is reached directly.
  let offset = int(place.index) * ValueStride
  case place.home
  of SlotHome: (RegistersBase, offset)
  of GlobalHome: (GlobalsBase, offset)
  of ArgumentHome:
    e.contextField(Cell, ContextArguments)
    (Cell, offset)
  of HostHome:
    e.contextField(Cell, ContextHostData)
    (Cell, offset)
  of CellHome: (Cell, 0)

proc readValue(e: var Emitter, value, tag: int, place: Place)
    {.raises: [BasicError].} =
  ## Reads a value's kind and its 32-bit payload.
  let (base, offset) = e.reach(place)
  e.code.loadByteZeroed(temp(tag), base, offset)
  e.code.loadWord(temp(value), base, offset + ValuePayload)

proc writeWhole(e: var Emitter, place: Place, value: int)
    {.raises: [BasicError].} =
  ## Writes a whole number.
  let (base, offset) = e.reach(place)
  e.code.storeByteImmediate(base, offset, 0)
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeKind(e: var Emitter, place: Place, tag, value: int)
    {.raises: [BasicError].} =
  ## Writes a payload under the kind held in a working register.
  let (base, offset) = e.reach(place)
  e.code.storeByteLow(base, offset, temp(tag))
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeFixed(e: var Emitter, place: Place, value: int)
    {.raises: [BasicError].} =
  ## Writes a fixed-point payload.
  let (base, offset) = e.reach(place)
  e.code.storeByteImmediate(base, offset, byte(FixedTag))
  e.code.storeWord(temp(value), base, offset + ValuePayload)

proc writeConstant(e: var Emitter, place: Place, tag: int, bits: int32)
    {.raises: [BasicError].} =
  ## Writes a constant of a known kind.
  let (base, offset) = e.reach(place)
  e.code.storeByteImmediate(base, offset, byte(tag))
  e.code.storeWordImmediate(base, offset + ValuePayload, bits)

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
  e.code.testRegister(Word32, temp(tag), temp(tag))
  e.jumpWhen(NotEqualCondition, slow)

proc unlessNumeric(e: var Emitter, tag: int, slow: Label)
    {.raises: [].} =
  ## Takes the slow path unless a kind says number of either sort.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.jumpWhen(AboveCondition, slow)

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
  e.code.testRegister(Word32, temp(tag), temp(tag))
  e.jumpWhen(EqualCondition, target)

proc unlessFixed(e: var Emitter, tag: int, slow: Label) {.raises: [].} =
  ## Takes the slow path unless a kind says fixed point.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.jumpWhen(NotEqualCondition, slow)

proc toFixed(e: var Emitter, value: int, slow: Label)
    {.raises: [BasicError].} =
  ## Turns a whole number into Q16.16 bits. One outside the fixed-point
  ## range cannot be, which the interpreter refuses, so that goes slow.
  let register = temp(value)
  e.code.compareImmediate(Word32, register, 32767)
  e.jumpWhen(GreaterCondition, slow)
  e.code.compareImmediate(Word32, register, -32768)
  e.jumpWhen(LessCondition, slow)
  e.code.shiftLeftImmediate(Word32, register, FixedShift)

proc scaleWide(e: var Emitter, value, tag: int) {.raises: [BasicError].} =
  ## Widens a number of either kind to sixty-four bits on the fixed-point
  ## scale, where every whole number and every fixed-point one compare
  ## exactly, as the interpreter compares them.
  let register = temp(value)
  let done = e.label()
  e.code.signExtendDouble(register, register)
  e.code.testRegister(Word32, temp(tag), temp(tag))
  e.jumpWhen(NotEqualCondition, done)
  e.code.shiftLeftImmediate(Word64, register, FixedShift)
  e.place(done)

proc loadWide(e: var Emitter, value: int, bits: int64) {.raises: [].} =
  ## Loads a sixty-four bit constant into a working register.
  e.code.loadImmediate(Word64, temp(value), bits)

proc compareWide(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two widened working registers.
  e.code.compareRegister(Word64, temp(left), temp(right))

proc whenFixed(e: var Emitter, tag: int, target: Label)
    {.raises: [].} =
  ## Jumps when a kind says fixed point.
  e.code.compareImmediate(Word32, temp(tag), FixedTag)
  e.jumpWhen(EqualCondition, target)

proc loadConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [].} =
  ## Loads a constant into a working register.
  e.code.loadImmediate(Word32, temp(value), int64(bits))

proc add(e: var Emitter, left, right: int) {.raises: [].} =
  ## Adds, wrapping.
  e.code.addRegister(Word32, temp(left), temp(right))

proc subtract(e: var Emitter, left, right: int) {.raises: [].} =
  ## Subtracts, wrapping.
  e.code.subtractRegister(Word32, temp(left), temp(right))

proc multiply(e: var Emitter, left, right: int) {.raises: [].} =
  ## Multiplies, wrapping.
  e.code.multiplyRegister(Word32, temp(left), temp(right))

proc negate(e: var Emitter, value: int) {.raises: [].} =
  ## Negates, wrapping.
  e.code.negateRegister(Word32, temp(value))

proc bitAnd(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits both hold.
  e.code.andRegister(Word32, temp(left), temp(right))

proc bitOr(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits either holds.
  e.code.orRegister(Word32, temp(left), temp(right))

proc bitXor(e: var Emitter, left, right: int) {.raises: [].} =
  ## Keeps the bits exactly one holds.
  e.code.xorRegister(Word32, temp(left), temp(right))

proc bitNot(e: var Emitter, value: int) {.raises: [].} =
  ## Flips every bit.
  e.code.notRegister(Word32, temp(value))

proc divide(e: var Emitter, left, right: int, keepRemainder: bool)
    {.raises: [].} =
  ## Divides toward zero; the divisor is known not to be zero. The
  ## hardware traps on the most negative number over minus one, which
  ## the interpreter defines, so minus one is answered without dividing:
  ## the quotient is the negation, wrapping, and nothing is left over.
  let normal = e.label()
  let done = e.label()
  e.code.compareImmediate(Word32, temp(right), -1)
  e.jumpWhen(NotEqualCondition, normal)
  if keepRemainder:
    e.code.loadImmediate(Word32, temp(left), 0)
  else:
    e.code.negateRegister(Word32, temp(left))
  e.jump(done)
  e.place(normal)
  e.code.moveRegister(Word32, rax, temp(left))
  e.code.signExtendToPair(Word32)
  e.code.signedDivide(Word32, temp(right))
  if keepRemainder:
    e.code.moveRegister(Word32, temp(left), Spare)
  else:
    e.code.moveRegister(Word32, temp(left), rax)
  e.place(done)

proc quotient(e: var Emitter, left, right: int) {.raises: [].} =
  ## Divides toward zero.
  e.divide(left, right, false)

proc remainder(e: var Emitter, left, right: int)
    {.raises: [].} =
  ## Leaves what dividing left over, with the sign of the dividend.
  e.divide(left, right, true)

proc multiplyFixed(e: var Emitter, left, right: int)
    {.raises: [BasicError].} =
  ## Multiplies two Q16.16 numbers through a widened intermediate,
  ## rounding to nearest exactly as the fixed-point library does.
  e.code.signExtendDouble(temp(left), temp(left))
  e.code.signExtendDouble(temp(6), temp(right))
  e.code.multiplyRegister(Word64, temp(left), temp(6))
  e.code.addImmediate(Word64, temp(left), int32(FixedRounding))
  e.code.shiftRightImmediate(Word64, temp(left), FixedShift)
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
  e.code.compareImmediate(Word32, register, 32767)
  e.jumpWhen(GreaterCondition, slow)
  e.code.compareImmediate(Word32, register, -32768)
  e.jumpWhen(LessCondition, slow)
  e.code.signExtendDouble(register, register)
  e.code.shiftLeftImmediate(Word64, register, FixedShift)
  e.jump(ready)
  e.place(already)
  e.code.signExtendDouble(register, register)
  e.place(ready)

proc divideFixed(e: var Emitter, left, right: int, slow: Label)
    {.raises: [BasicError].} =
  ## Divides two widened Q16.16 numbers, rounding to nearest with halves
  ## going up, for either sign, exactly as the fixed-point library
  ## does: the signs are put right first, half the divisor is added,
  ## and the truncating divide is corrected back to a floor. The divide
  ## works in rax and rdx, so the numerator is moved there.
  let denominator = temp(right)
  let half = temp(5)
  let numerator = temp(6)
  e.code.moveRegister(Word64, rax, temp(left))
  e.code.compareImmediate(Word64, denominator, 0)
  e.jumpWhen(EqualCondition, slow)
  let signsSettled = e.label()
  e.jumpWhen(GreaterCondition, signsSettled)
  e.code.negateRegister(Word64, rax)
  e.code.negateRegister(Word64, denominator)
  e.place(signsSettled)
  e.code.shiftLeftImmediate(Word64, rax, FixedShift)
  e.code.moveRegister(Word64, half, denominator)
  e.code.shiftRightImmediate(Word64, half, 1)
  e.code.addRegister(Word64, rax, half)
  e.code.moveRegister(Word64, numerator, rax)
  e.code.signExtendToPair(Word64)
  e.code.signedDivide(Word64, denominator)
  let done = e.label()
  e.code.testRegister(Word64, Spare, Spare)
  e.jumpWhen(EqualCondition, done)
  e.code.testRegister(Word64, numerator, numerator)
  e.jumpWhen(GreaterEqualCondition, done)
  e.code.subtractImmediate(Word64, rax, 1)
  e.place(done)
  e.code.moveRegister(Word32, temp(left), rax)

proc compare(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two working registers.
  e.code.compareRegister(Word32, temp(left), temp(right))

proc compareConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [].} =
  ## Sets flags from a working register against a constant.
  e.code.compareImmediate(Word32, temp(value), bits)

proc answer(e: var Emitter, value: int, check: Check) {.raises: [].} =
  ## Writes BASIC's -1 for true and zero for false. The byte form only
  ## names the low byte of rax, rcx, rdx and rbx without a prefix, so
  ## this is only ever asked of the first working register.
  e.code.setIfCondition(temp(value), nativeCondition(check))
  e.code.negateRegister(Word32, temp(value))

proc jumpOn(e: var Emitter, check: Check, target: Label)
    {.raises: [].} =
  ## Jumps on a comparison outcome.
  e.jumpWhen(nativeCondition(check), target)

proc jumpIfZeroValue(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds zero.
  e.code.testRegister(Word32, temp(value), temp(value))
  e.jumpWhen(EqualCondition, target)

proc jumpIfNotZeroValue(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a working register holds anything but zero.
  e.code.testRegister(Word32, temp(value), temp(value))
  e.jumpWhen(NotEqualCondition, target)

proc jumpIfLowBits(e: var Emitter, value, bits: int, target: Label)
    {.raises: [].} =
  ## Jumps when any of a working register's lowest bits is set.
  e.code.testImmediate(Word32, temp(value), int32((1'i64 shl bits) - 1))
  e.jumpWhen(NotEqualCondition, target)

proc cellAddress(e: var Emitter, index: int, extent: ArrayExtent,
    slow: Label) {.raises: [BasicError].} =
  ## Bounds checks an index and leaves the cell's address in Cell. One
  ## unsigned comparison covers both ends, as the interpreter's does.
  ## The cells' base is read from the context rather than kept in a
  ## register, which leaves one more register for a loop's globals. The
  ## index register is left scaled.
  e.code.compareImmediate(Word32, temp(index), extent.length)
  e.jumpWhen(AboveEqualCondition, slow)
  e.code.addImmediate(Word32, temp(index), extent.base)
  e.code.shiftLeftImmediate(Word64, temp(index), 4)
  e.contextField(Cell, ContextMemory)
  e.code.addRegister(Word64, Cell, temp(index))

proc charge(e: var Emitter, instructions, work: int32) {.raises: [].} =
  ## Charges both budgets, already known to cover it, without looking.
  e.code.subtractImmediate(Word64, Instructions, instructions)
  e.code.subtractImmediate(Word64, Work, work)

proc meter(e: var Emitter, instructions, work: int32, slow: Label,
    needInstructions = int64(instructions), needWork = int64(work))
    {.raises: [].} =
  ## Checks both budgets hold what is needed before charging either, as
  ## the interpreter does. What is needed can be more than this block
  ## costs, when one look is to cover every block until the next.
  for (budget, need) in [(Instructions, needInstructions),
      (Work, needWork)]:
    if need <= int64(high(int32)):
      e.code.compareImmediate(Word64, budget, int32(need))
    else:
      e.code.loadImmediate(Word64, Spare, need)
      e.code.compareRegister(Word64, budget, Spare)
    e.jumpWhen(LessCondition, slow)
  e.charge(instructions, work)

proc slotAddress(e: var Emitter, destination, index: Register)
    {.raises: [BasicError].} =
  ## Points a register at one register-file slot by its absolute index.
  ## The index register is left scaled.
  e.contextField(destination, ContextRegisterFile)
  e.code.shiftLeftImmediate(Word64, index, 4)
  e.code.addRegister(Word64, destination, index)

proc copyValues(e: var Emitter, destination, source: Register,
    count: int) {.raises: [BasicError].} =
  ## Copies a run of whole values, in a loop once there are many. Works
  ## in rax, rdx, r8, r9 and r10, so neither end may be one of those.
  if count <= 8:
    for index in 0 ..< count:
      e.code.loadDouble(rax, source, index * ValueStride)
      e.code.loadDouble(Spare, source, index * ValueStride + ValuePayload)
      e.code.storeDouble(rax, destination, index * ValueStride)
      e.code.storeDouble(Spare, destination,
        index * ValueStride + ValuePayload)
    return
  e.code.moveRegister(Word64, r10, source)
  e.code.moveRegister(Word64, r9, destination)
  e.code.loadImmediate(Word32, r8, int64(count))
  let again = e.label()
  e.place(again)
  e.code.loadDouble(rax, r10, 0)
  e.code.loadDouble(Spare, r10, ValuePayload)
  e.code.storeDouble(rax, r9, 0)
  e.code.storeDouble(Spare, r9, ValuePayload)
  e.code.addImmediate(Word64, r10, ValueStride)
  e.code.addImmediate(Word64, r9, ValueStride)
  e.code.subtractImmediate(Word32, r8, 1)
  e.jumpWhen(NotEqualCondition, again)

proc clearValues(e: var Emitter, destination: Register, count: int)
    {.raises: [BasicError].} =
  ## Zeroes a run of values, in a loop once there are many.
  e.code.loadImmediate(Word32, rax, 0)
  if count <= 8:
    for index in 0 ..< count:
      e.code.storeDouble(rax, destination, index * ValueStride)
      e.code.storeDouble(rax, destination,
        index * ValueStride + ValuePayload)
    return
  e.code.moveRegister(Word64, r9, destination)
  e.code.loadImmediate(Word32, r8, int64(count))
  let again = e.label()
  e.place(again)
  e.code.storeDouble(rax, r9, 0)
  e.code.storeDouble(rax, r9, ValuePayload)
  e.code.addImmediate(Word64, r9, ValueStride)
  e.code.subtractImmediate(Word32, r8, 1)
  e.jumpWhen(NotEqualCondition, again)

proc enterRoutine(e: var Emitter, gosub: bool, calleeId: int32,
    calleeRegisters, calleeParameters, callerRegisters: int32,
    resumeAt: int32, limits: CallLimits, slow: Label)
    {.raises: [BasicError].} =
  ## Pushes a frame into the interpreter's own array and moves the
  ## current frame on, refusing the same two ceilings it refuses.
  let depth = rax
  let oldBase = rcx
  let newBase = rsi
  let frame = rdi
  e.code.loadWord(depth, Context, ContextDepth)
  e.code.compareImmediate(Word32, depth, limits.frames - 1)
  e.jumpWhen(GreaterEqualCondition, slow)
  e.code.loadWord(oldBase, Context, ContextBase)
  e.code.moveRegister(Word32, newBase, oldBase)
  e.code.addImmediate(Word32, newBase, callerRegisters)
  e.code.compareImmediate(Word32, newBase,
    limits.slots - calleeRegisters)
  e.jumpWhen(GreaterCondition, slow)

  e.contextField(frame, ContextFrames)
  e.code.moveRegister(Word32, r8, depth)
  e.code.shiftLeftImmediate(Word64, r8, 4)
  e.code.addRegister(Word64, frame, r8)
  e.code.storeWord(oldBase, frame, FrameBase)
  e.code.loadWord(r8, Context, ContextRoutine)
  e.code.storeWord(r8, frame, FrameRoutine)
  e.code.storeWordImmediate(frame, FrameReturn, resumeAt)
  e.code.storeWordImmediate(frame, FrameTag, if gosub: 1 else: 0)

  e.code.addImmediate(Word32, depth, 1)
  e.code.storeWord(depth, Context, ContextDepth)
  e.code.storeWord(newBase, Context, ContextBase)
  e.code.storeWordImmediate(Context, ContextRoutine, calleeId)

  # A GOSUB hands the callee a copy of the caller's slots; a call clears
  # them and lays the arguments over the first few, in that order.
  e.code.moveRegister(Word64, frame, RegistersBase)
  e.code.moveRegister(Word32, rcx, newBase)
  e.slotAddress(RegistersBase, rcx)
  if gosub:
    e.copyValues(RegistersBase, frame, int(calleeRegisters))
  else:
    e.clearValues(RegistersBase, int(calleeRegisters))
    if calleeParameters > 0:
      e.contextField(Cell, ContextArguments)
      e.copyValues(RegistersBase, Cell, int(calleeParameters))

proc leaveRoutine(e: var Emitter, parameters: int32, exitSub: bool,
    slow: Label) {.raises: [BasicError].} =
  ## Pops a frame and jumps to wherever it said to carry on. A GOSUB
  ## frame first hands the shared parameters back to the caller. Leaving
  ## a sub outright only goes this way when its own frame is on top.
  ## Nothing is written until every refusal has been passed, the offset
  ## it would carry on at included, so a refusal leaves the frame on.
  let depth = rax
  let frame = rcx
  let base = rsi
  e.code.loadWord(depth, Context, ContextDepth)
  e.code.testRegister(Word32, depth, depth)
  e.jumpWhen(EqualCondition, slow)
  e.code.subtractImmediate(Word32, depth, 1)
  e.contextField(frame, ContextFrames)
  e.code.moveRegister(Word32, r8, depth)
  e.code.shiftLeftImmediate(Word64, r8, 4)
  e.code.addRegister(Word64, frame, r8)
  if exitSub:
    e.code.loadByteZeroed(Spare, frame, FrameTag)
    e.code.testRegister(Word32, Spare, Spare)
    e.jumpWhen(NotEqualCondition, slow)
  e.code.loadWord(Cell, frame, FrameReturn)
  e.withinProgram(Cell)
  e.code.storeWord(depth, Context, ContextDepth)
  e.code.loadWord(base, frame, FrameBase)
  if parameters > 0:
    let plain = e.label()
    e.code.loadByteZeroed(Spare, frame, FrameTag)
    e.code.compareImmediate(Word32, Spare, 1)
    e.jumpWhen(NotEqualCondition, plain)
    e.code.moveRegister(Word32, r8, base)
    e.slotAddress(rdi, r8)
    e.copyValues(rdi, RegistersBase, int(parameters))
    e.place(plain)
  e.code.storeWord(base, Context, ContextBase)
  e.code.loadWord(Spare, frame, FrameRoutine)
  e.code.storeWord(Spare, Context, ContextRoutine)
  e.code.loadWord(Spare, frame, FrameReturn)
  e.code.storeWord(Spare, Context, ContextOffset)
  e.code.moveRegister(Word32, r8, base)
  e.slotAddress(RegistersBase, r8)
  e.contextField(rax, ContextTable)
  e.code.shiftLeftImmediate(Word64, Spare, 3)
  e.code.addRegister(Word64, rax, Spare)
  e.code.loadDouble(rax, rax, 0)
  e.code.jumpRegister(rax)

proc callSlow(e: var Emitter, offset: int32, routine: Label)
    {.raises: [].} =
  ## Runs the interpreter's own code for one instruction.
  e.code.loadImmediate(Word32, SecondArgument, int64(offset))
  e.code.callLabel(routine)

proc slowRoutine(e: var Emitter, failed: Label, helper: int)
    {.raises: [BasicError].} =
  ## The one place compiled code calls out. The budgets go into the
  ## context for the interpreter's code to charge, and come back from it
  ## along with the frame, since a call or a return may have moved it.
  ## The globals' base comes back too, host code having possibly replaced
  ## that buffer; every other base is read from the context where used.
  ## A failure leaves through the shared exit, dropping the return
  ## address this routine was called with on the way.
  let refused = e.label()
  e.code.storeDouble(Instructions, Context, ContextInstructions)
  e.code.storeDouble(Work, Context, ContextWork)
  e.code.moveRegister(Word64, FirstArgument, Context)
  e.code.subtractImmediate(Word64, rsp, Padding)
  e.contextField(rax, helper)
  e.code.callRegister(rax)
  e.code.addImmediate(Word64, rsp, Padding)
  e.code.moveRegister(Word32, r10, rax)
  e.code.loadDouble(Instructions, Context, ContextInstructions)
  e.code.loadDouble(Work, Context, ContextWork)
  e.contextField(GlobalsBase, 0)
  e.code.loadWord(rcx, Context, ContextBase)
  e.slotAddress(RegistersBase, rcx)
  e.code.testRegister(Word32, r10, r10)
  e.jumpWhen(NotEqualCondition, refused)
  e.code.returnToCaller()
  e.place(refused)
  e.code.addImmediate(Word64, rsp, 8)
  e.jump(failed)

proc dispatch(e: var Emitter) {.raises: [BasicError].} =
  ## Jumps to the block for whatever offset the context names.
  e.code.loadWord(rax, Context, ContextOffset)
  e.withinProgram(rax)
  e.code.shiftLeftImmediate(Word64, rax, 3)
  e.contextField(rcx, ContextTable)
  e.code.addRegister(Word64, rcx, rax)
  e.code.loadDouble(rcx, rcx, 0)
  e.code.jumpRegister(rcx)

proc prologue(e: var Emitter) {.raises: [BasicError].} =
  ## Saves what the platform says to keep and loads the machine state.
  for register in Saved:
    e.code.push(register)
  e.code.subtractImmediate(Word64, rsp, Padding)
  e.code.moveRegister(Word64, Context, FirstArgument)
  e.code.loadDouble(GlobalsBase, Context, 0)
  e.code.loadDouble(Instructions, Context, ContextInstructions)
  e.code.loadDouble(Work, Context, ContextWork)
  e.code.loadWord(rcx, Context, ContextBase)
  e.slotAddress(RegistersBase, rcx)

proc restoreAndReturn(e: var Emitter) {.raises: [].} =
  ## Restores what the platform says to keep and returns rax as it is.
  e.code.addImmediate(Word64, rsp, Padding)
  for index in countdown(Saved.len - 1, 0):
    e.code.pop(Saved[index])
  e.code.returnToCaller()

proc epilogue(e: var Emitter, status: NativeStatus)
    {.raises: [].} =
  ## Restores what the platform says to keep and returns a status.
  e.code.loadImmediate(Word32, rax, int64(ord(status)))
  e.restoreAndReturn()

proc leaveWithAnswer(e: var Emitter) {.raises: [].} =
  ## Returns whatever status the interpreter's code answered with.
  e.code.moveRegister(Word32, rax, r10)
  e.restoreAndReturn()

## Globals held in registers
##
## Inside a specialised loop its globals live in the registers below,
## proved whole numbers on the way in. The globals' own base register is
## one of them, so the globals are reached through Cell while a loop
## runs, and the base is read back from the context on the way out.

const Hoisting* = [r8, r14, rbx]

proc hoisted(slot: int): Register {.inline, raises: [].} =
  ## Returns the register holding one hoisted global.
  Hoisting[slot]

proc beginHoisting(e: var Emitter) {.raises: [BasicError].} =
  ## Reaches the globals through Cell, which no hoisted value occupies.
  e.contextField(Cell, 0)

proc endHoisting(e: var Emitter) {.raises: [BasicError].} =
  ## Puts the globals' base back where the general code expects it.
  e.contextField(GlobalsBase, 0)

proc guardHoisted(e: var Emitter, index: int32, failed: Label)
    {.raises: [BasicError].} =
  ## Leaves for the general code unless a global holds a whole number.
  let offset = int(index) * ValueStride
  e.code.loadByteZeroed(temp(0), Cell, offset)
  e.code.testRegister(Word32, temp(0), temp(0))
  e.jumpWhen(NotEqualCondition, failed)

proc loadHoisted(e: var Emitter, slot: int, index: int32)
    {.raises: [BasicError].} =
  ## Reads one global's payload into its register.
  e.code.loadWord(hoisted(slot), Cell,
    int(index) * ValueStride + ValuePayload)

proc storeHoisted(e: var Emitter, slot: int, index: int32)
    {.raises: [BasicError].} =
  ## Publishes one register back as a whole number.
  let offset = int(index) * ValueStride
  e.code.storeByteImmediate(Cell, offset, 0)
  e.code.storeWord(hoisted(slot), Cell, offset + ValuePayload)

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
  e.code.addRegister(Word32, hoisted(destination), hoisted(source))

proc addHoistedConstant(e: var Emitter, slot: int, bits: int32)
    {.raises: [].} =
  ## Adds a constant to a hoisted global, wrapping.
  e.code.addImmediate(Word32, hoisted(slot), bits)

proc hoistedToTemp(e: var Emitter, value, slot: int) {.raises: [].} =
  ## Copies a hoisted global into a working register.
  e.code.moveRegister(Word32, temp(value), hoisted(slot))

proc tempToHoisted(e: var Emitter, slot, value: int) {.raises: [].} =
  ## Copies a working register into a hoisted global.
  e.code.moveRegister(Word32, hoisted(slot), temp(value))

proc addTempToHoisted(e: var Emitter, slot, value: int) {.raises: [].} =
  ## Adds a working register into a hoisted global, wrapping.
  e.code.addRegister(Word32, hoisted(slot), temp(value))

proc writeFromHoisted(e: var Emitter, place: Place, slot: int)
    {.raises: [BasicError].} =
  ## Writes a hoisted global, always a whole number, somewhere in memory.
  ## The place is reached through Cell, which holds no hoisted value.
  let (base, offset) = e.reach(place)
  e.code.storeByteImmediate(base, offset, 0)
  e.code.storeWord(hoisted(slot), base, offset + ValuePayload)

proc compareHoisted(e: var Emitter, slot: int, bits: int32)
    {.raises: [].} =
  ## Sets flags from a hoisted global against a constant.
  e.code.compareImmediate(Word32, hoisted(slot), bits)

## Values held in registers across a block
##
## A block's fast version keeps the slots and globals it touches in the
## registers below. Nothing in the pool outlives the block: every held
## value is written back before anything else could look at memory. rax
## and rdx stay out of the pool for the divide and as scratch.

const
  Pool* = [rcx, rsi, rdi, r8, r9, r10, r14]
  FastScratch = rax

proc pooled(index: int): Register {.inline, raises: [].} =
  ## Returns one pool register.
  Pool[index]

proc fastLoad(e: var Emitter, payload, tag: int, place: Place,
    deopt: Label) {.raises: [BasicError].} =
  ## Reads a value's kind and payload, taking the deopt path unless it
  ## is a number of either kind.
  let (base, offset) = e.reach(place)
  e.code.loadByteZeroed(pooled(tag), base, offset)
  e.code.loadWord(pooled(payload), base, offset + ValuePayload)
  e.code.compareImmediate(Word32, pooled(tag), FixedTag)
  e.jumpWhen(AboveCondition, deopt)

proc fastStore(e: var Emitter, place: Place, payload, tag, kind: int)
    {.raises: [BasicError].} =
  ## Writes a value back: its kind from a register, or the known kind.
  let (base, offset) = e.reach(place)
  if tag >= 0:
    e.code.storeByteLow(base, offset, pooled(tag))
  else:
    e.code.storeByteImmediate(base, offset, byte(kind))
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
  e.code.addRegister(Word32, pooled(destination), pooled(source))

proc fastSubtract(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Subtracts, wrapping.
  e.code.subtractRegister(Word32, pooled(destination), pooled(source))

proc fastMultiply(e: var Emitter, destination, source: int)
    {.raises: [].} =
  ## Multiplies, wrapping.
  e.code.multiplyRegister(Word32, pooled(destination), pooled(source))

proc fastMultiplyFixed(e: var Emitter, destination, source: int)
    {.raises: [BasicError].} =
  ## Multiplies two Q16.16 numbers, rounding as the library does.
  let target = pooled(destination)
  e.code.signExtendDouble(target, target)
  e.code.signExtendDouble(FastScratch, pooled(source))
  e.code.multiplyRegister(Word64, target, FastScratch)
  e.code.addImmediate(Word64, target, int32(FixedRounding))
  e.code.shiftRightImmediate(Word64, target, FixedShift)
  e.code.moveRegister(Word32, target, target)

proc fastNegate(e: var Emitter, destination: int) {.raises: [].} =
  ## Negates, wrapping.
  e.code.negateRegister(Word32, pooled(destination))

proc fastToFixed(e: var Emitter, destination: int, deopt: Label)
    {.raises: [BasicError].} =
  ## Turns a whole number into Q16.16 bits, or takes the deopt path when
  ## it is outside the fixed-point range, which the interpreter refuses.
  let target = pooled(destination)
  e.code.compareImmediate(Word32, target, 32767)
  e.jumpWhen(GreaterCondition, deopt)
  e.code.compareImmediate(Word32, target, -32768)
  e.jumpWhen(LessCondition, deopt)
  e.code.shiftLeftImmediate(Word32, target, FixedShift)

proc fastCompare(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two pool registers.
  e.code.compareRegister(Word32, pooled(left), pooled(right))

proc fastCompareWide(e: var Emitter, left, right: int) {.raises: [].} =
  ## Sets flags from two widened pool registers.
  e.code.compareRegister(Word64, pooled(left), pooled(right))

proc fastCompareConstant(e: var Emitter, value: int, bits: int32)
    {.raises: [].} =
  ## Sets flags from a pool register against a constant.
  e.code.compareImmediate(Word32, pooled(value), bits)

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
  e.code.signExtendDouble(target, target)
  e.code.testRegister(Word32, pooled(tag), pooled(tag))
  e.jumpWhen(NotEqualCondition, done)
  e.code.shiftLeftImmediate(Word64, target, FixedShift)
  e.place(done)

proc fastAnswer(e: var Emitter, destination: int, check: Check)
    {.raises: [].} =
  ## Writes BASIC's -1 for true and zero for false.
  e.code.setIfCondition(pooled(destination), nativeCondition(check))
  e.code.negateRegister(Word32, pooled(destination))

proc fastJumpIfZero(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a pool register holds zero.
  e.code.testRegister(Word32, pooled(value), pooled(value))
  e.jumpWhen(EqualCondition, target)

proc fastJumpIfNotZero(e: var Emitter, value: int, target: Label)
    {.raises: [].} =
  ## Jumps when a pool register holds anything but zero.
  e.code.testRegister(Word32, pooled(value), pooled(value))
  e.jumpWhen(NotEqualCondition, target)

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
  e.code.compareImmediate(Word32, position, extent.length)
  e.jumpWhen(AboveEqualCondition, deopt)
  e.code.moveRegister(Word32, FastScratch, position)
  e.code.addImmediate(Word32, FastScratch, extent.base)
  e.code.shiftLeftImmediate(Word64, FastScratch, 4)
  e.contextField(Cell, ContextMemory)
  e.code.addRegister(Word64, Cell, FastScratch)

proc callQuery(e: var Emitter, offset: int32, keep: seq[Register],
    refused: Label) {.raises: [BasicError].} =
  ## Asks a query directly, keeping the registers that hold live values on
  ## the stack across it, since a callee is free to clobber them. Leaves
  ## for the refused path when the query answers that it did not answer.
  for index, register in keep:
    e.code.storeDouble(register, rsp, SpillOffset + index * 8)
  e.code.moveRegister(Word64, FirstArgument, Context)
  e.code.loadImmediate(Word32, SecondArgument, int64(offset))
  e.contextField(rax, ContextQueryStep)
  e.code.callRegister(rax)
  for index, register in keep:
    e.code.loadDouble(register, rsp, SpillOffset + index * 8)
  e.code.testRegister(Word32, rax, rax)
  e.jumpWhen(NotEqualCondition, refused)

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
  e.code.loadByteZeroed(start, base, offset)
  e.code.compareImmediate(Word32, start, StringTag)
  e.jumpWhen(NotEqualCondition, slow)
  e.code.loadDouble(reference, base, offset + ValuePayload)
  e.contextField(length, ContextStringOwner)
  e.code.loadWord(length, length, 0)
  e.code.testRegister(Word32, length, length)
  e.jumpWhen(EqualCondition, slow)
  e.code.moveRegister(Word64, start, reference)
  e.code.shiftRightImmediate(Word64, start, 32)
  e.code.compareRegister(Word32, start, length)
  e.jumpWhen(NotEqualCondition, slow)
  e.contextField(length, ContextStringSpans)
  e.code.loadDouble(start, length, 0)
  e.code.moveRegister(Word32, reference, reference)
  e.code.compareRegister(Word64, reference, start)
  e.jumpWhen(AboveEqualCondition, slow)
  e.code.loadDouble(length, length, 8)
  e.code.moveRegister(Word64, start, reference)
  e.code.shiftLeftImmediate(Word64, start, 3)
  e.code.addRegister(Word64, length, start)
  e.code.loadWord(start, length, 8)
  e.code.loadWord(length, length, 12)

proc chargeWork(e: var Emitter, cost: Register, slow: Label)
    {.raises: [].} =
  ## Charges work worked out at run time, or takes the slow path when it
  ## cannot be afforded, where the interpreter raises.
  e.code.compareRegister(Word64, Work, cost)
  e.jumpWhen(LessCondition, slow)
  e.code.subtractRegister(Word64, Work, cost)

proc arenaBase(e: var Emitter, destination: Register)
    {.raises: [BasicError].} =
  ## Points at the first byte of the string arena.
  e.contextField(destination, ContextStringArena)
  e.code.loadDouble(destination, destination, 8)
  e.code.addImmediate(Word64, destination, 8)

proc stringFunction(e: var Emitter, function: TextFunction, slow: Label)
    {.raises: [BasicError].} =
  ## Answers LEN or ASC of the first argument into the first working
  ## register, charging what the interpreter charges.
  e.stringSpan(argument(0), r8, rsi, rdi, slow)
  if function == CodeFunction:
    e.code.testRegister(Word32, rdi, rdi)
    e.jumpWhen(EqualCondition, slow)
  e.code.moveRegister(Word32, Spare, rdi)
  e.code.addImmediate(Word64, Spare, 1)
  e.chargeWork(Spare, slow)
  if function == LengthFunction:
    e.code.moveRegister(Word32, temp(0), rdi)
  else:
    e.arenaBase(Cell)
    e.code.addRegister(Word64, Cell, rsi)
    e.code.loadByteZeroed(temp(0), Cell, 0)

proc stringEquality(e: var Emitter, left, right: Place, equal: bool,
    slow: Label) {.raises: [BasicError].} =
  ## Answers whether two strings hold the same bytes, into the first
  ## working register, charging both lengths as the interpreter does.
  e.stringSpan(left, r8, rsi, rdi, slow)
  e.stringSpan(right, r9, r10, r14, slow)
  e.code.moveRegister(Word32, Spare, rdi)
  e.code.addRegister(Word64, Spare, r14)
  e.chargeWork(Spare, slow)
  let differ = e.label()
  let same = e.label()
  let done = e.label()
  e.code.compareRegister(Word32, rdi, r14)
  e.jumpWhen(NotEqualCondition, differ)
  e.arenaBase(Cell)
  e.code.addRegister(Word64, rsi, Cell)
  e.code.addRegister(Word64, r10, Cell)
  e.code.testRegister(Word32, rdi, rdi)
  e.jumpWhen(EqualCondition, same)
  let again = e.label()
  e.place(again)
  e.code.loadByteZeroed(rax, rsi, 0)
  e.code.loadByteZeroed(Spare, r10, 0)
  e.code.compareRegister(Word32, rax, Spare)
  e.jumpWhen(NotEqualCondition, differ)
  e.code.addImmediate(Word64, rsi, 1)
  e.code.addImmediate(Word64, r10, 1)
  e.code.subtractImmediate(Word32, rdi, 1)
  e.jumpWhen(NotEqualCondition, again)
  e.place(same)
  e.code.loadImmediate(Word32, temp(0), if equal: -1 else: 0)
  e.jump(done)
  e.place(differ)
  e.code.loadImmediate(Word32, temp(0), if equal: 0 else: -1)
  e.place(done)

proc jumpUnlessTag(e: var Emitter, tag: int, value: int, target: Label)
    {.raises: [].} =
  ## Jumps unless a working register holds one particular tag.
  e.code.compareImmediate(Word32, temp(tag), int32(value))
  e.jumpWhen(NotEqualCondition, target)

proc halt(e: var Emitter, offset: int32) {.raises: [BasicError].} =
  ## Publishes the budgets and where the program stopped, then returns.
  e.code.storeDouble(Instructions, Context, ContextInstructions)
  e.code.storeDouble(Work, Context, ContextWork)
  e.code.storeWordImmediate(Context, ContextOffset, offset)
  e.epilogue(NativeCompleted)

proc finish(e: var Emitter): seq[byte] {.raises: [BasicError].} =
  ## Resolves every branch and returns the finished bytes.
  e.code.resolve()
  e.code.code

proc offsetBytes(e: Emitter, target: Label): int {.raises: [].} =
  ## Returns where a label ended up, in bytes.
  e.code.offsetOf(target)
