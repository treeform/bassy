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
    ## Why compiled code returned to its caller.
    NativeCompleted,
    NativeFailed

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
  FixedShift = 16
  FixedRounding = 1'i64 shl (FixedShift - 1)

  ## Fixed-point values are only modelled inline when overflow is allowed
  ## to wrap. Under fixedChecks the interpreter asserts instead, so that
  ## build hands every fixed-point operation to the interpreter's code.
  ModelsFixed* = not defined(fixedChecks)

  MaxProgramBytes = 64 * 1024 * 1024
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
  if image[ValueStride] != byte(FixedTag) or ord(FixedValue) != FixedTag:
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
    at(step) == ContextStep

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

proc takenOn(op: Op): Check {.raises: [].} =
  ## Returns the outcome on which a fused test takes its branch.
  case op
  of JumpUnlessGlobalEqualImmediateOp: NotEqualCheck
  of JumpUnlessGlobalNotEqualImmediateOp: EqualCheck
  of JumpUnlessGlobalLessImmediateOp: GreaterEqualCheck
  of JumpUnlessGlobalLessEqualImmediateOp: GreaterCheck
  of JumpUnlessGlobalGreaterImmediateOp: LessEqualCheck
  else: LessCheck

when NativeArm64:
  ## AArch64 code generation
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
    FrameBytes = 96
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

  proc meter(e: var Emitter, instructions, work: int32, slow: Label)
      {.raises: [BasicError].} =
    ## Checks both budgets before charging either, as the interpreter does.
    if instructions <= 4095:
      e.code.compareImmediate(Word64, Instructions, int(instructions))
    else:
      e.code.loadImmediate(Word64, temp(5), int64(instructions))
      e.code.compareRegister(Word64, Instructions, temp(5))
    e.jumpWhen(LessCondition, slow)
    if work <= 4095:
      e.code.compareImmediate(Word64, Work, int(work))
    else:
      e.code.loadImmediate(Word64, temp(6), int64(work))
      e.code.compareRegister(Word64, Work, temp(6))
    e.jumpWhen(LessCondition, slow)
    if instructions <= 4095:
      e.code.subtractImmediate(Word64, Instructions, Instructions,
        int(instructions))
    else:
      e.code.subtractRegister(Word64, Instructions, Instructions, temp(5))
    if work <= 4095:
      e.code.subtractImmediate(Word64, Work, Work, int(work))
    else:
      e.code.subtractRegister(Word64, Work, Work, temp(6))

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
    ## Nothing is written until both refusals have been passed.
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
    e.code.storeWord(depth, Context, ContextDepth)
    e.code.loadWord(base, frame, FrameBase)
    if parameters > 0:
      let plain = e.label()
      e.code.loadByte(temp(4), frame, FrameTag)
      e.code.compareImmediate(Word32, temp(4), 1)
      e.code.branchIf(NotEqualCondition, plain)
      e.frameOf(Far, base)
      e.copyValues(Far, RegistersBase, int(parameters))
      e.place(plain)
    e.code.storeWord(base, Context, ContextBase)
    e.code.loadWord(temp(4), frame, FrameRoutine)
    e.code.storeWord(temp(4), Context, ContextRoutine)
    e.code.loadWord(resume, frame, FrameReturn)
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

  proc slowRoutine(e: var Emitter, failed: Label)
      {.raises: [BasicError].} =
    ## The one place compiled code calls out. The budgets go into the
    ## context for the interpreter's code to charge, and come back from it
    ## along with the frame, since a call or a return may have moved it.
    e.code.storePair(framePointer, linkRegister, stackPointer, -16, true)
    e.code.storeDouble(Instructions, Context, ContextInstructions)
    e.code.storeDouble(Work, Context, ContextWork)
    e.code.moveRegister(Word64, x0, Context)
    e.code.loadDouble(temp(0), Context, ContextStep)
    e.code.callRegister(temp(0))
    e.code.moveRegister(Word32, temp(0), x0)
    e.code.loadDouble(Instructions, Context, ContextInstructions)
    e.code.loadDouble(Work, Context, ContextWork)
    e.code.loadWord(temp(1), Context, ContextBase)
    e.frameOf(RegistersBase, temp(1))
    e.code.loadPair(framePointer, linkRegister, stackPointer, 16, true)
    e.code.branchIfNotZero(Word32, temp(0), failed)
    e.code.returnToCaller()

  proc dispatch(e: var Emitter) {.raises: [BasicError].} =
    ## Jumps to the block for whatever offset the context names.
    e.code.loadWord(temp(0), Context, ContextOffset)
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

  proc epilogue(e: var Emitter, status: NativeStatus)
      {.raises: [BasicError].} =
    ## Restores what the platform says to keep and returns a status.
    e.code.loadImmediate(Word32, x0, int64(ord(status)))
    e.code.loadPair(x19, x20, stackPointer, 16)
    e.code.loadPair(x21, x22, stackPointer, 32)
    e.code.loadPair(x23, x24, stackPointer, 48)
    e.code.loadPair(x25, x26, stackPointer, 64)
    e.code.loadPair(x27, x28, stackPointer, 80)
    e.code.loadPair(framePointer, linkRegister, stackPointer, FrameBytes,
      true)
    e.code.returnToCaller()

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

  proc compareHoisted(e: var Emitter, slot: int, bits: int32)
      {.raises: [BasicError].} =
    ## Sets flags from a hoisted global against a constant.
    if bits >= 0 and bits <= 4095:
      e.code.compareImmediate(Word32, hoisted(slot), int(bits))
    else:
      e.code.loadImmediate(Word32, temp(6), int64(bits))
      e.code.compareRegister(Word32, hoisted(slot), temp(6))

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

elif NativeAmd64:
  ## x86-64 code generation
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
      ## Four shadow slots for the callee, plus eight to realign.
      Padding = 40
  else:
    const
      FirstArgument = rdi
      SecondArgument = rsi
      Saved = [rbx, rbp, r12, r13, r14, r15]
      Padding = 8

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

  proc meter(e: var Emitter, instructions, work: int32, slow: Label)
      {.raises: [].} =
    ## Checks both budgets before charging either, as the interpreter does.
    e.code.compareImmediate(Word64, Instructions, instructions)
    e.jumpWhen(LessCondition, slow)
    e.code.compareImmediate(Word64, Work, work)
    e.jumpWhen(LessCondition, slow)
    e.code.subtractImmediate(Word64, Instructions, instructions)
    e.code.subtractImmediate(Word64, Work, work)

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
    ## Nothing is written until both refusals have been passed.
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

  proc slowRoutine(e: var Emitter, failed: Label)
      {.raises: [BasicError].} =
    ## The one place compiled code calls out. The budgets go into the
    ## context for the interpreter's code to charge, and come back from it
    ## along with the frame, since a call or a return may have moved it.
    ## A failure leaves through the shared exit, dropping the return
    ## address this routine was called with on the way.
    let refused = e.label()
    e.code.storeDouble(Instructions, Context, ContextInstructions)
    e.code.storeDouble(Work, Context, ContextWork)
    e.code.moveRegister(Word64, FirstArgument, Context)
    e.code.subtractImmediate(Word64, rsp, Padding)
    e.contextField(rax, ContextStep)
    e.code.callRegister(rax)
    e.code.addImmediate(Word64, rsp, Padding)
    e.code.moveRegister(Word32, r10, rax)
    e.code.loadDouble(Instructions, Context, ContextInstructions)
    e.code.loadDouble(Work, Context, ContextWork)
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

  proc epilogue(e: var Emitter, status: NativeStatus)
      {.raises: [].} =
    ## Restores what the platform says to keep and returns a status.
    e.code.loadImmediate(Word32, rax, int64(ord(status)))
    e.code.addImmediate(Word64, rsp, Padding)
    for index in countdown(Saved.len - 1, 0):
      e.code.pop(Saved[index])
    e.code.returnToCaller()

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

  proc compareHoisted(e: var Emitter, slot: int, bits: int32)
      {.raises: [].} =
    ## Sets flags from a hoisted global against a constant.
    e.code.compareImmediate(Word32, hoisted(slot), bits)

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

proc invoke*(machine: Machine, context: var NativeContext): NativeStatus
    {.raises: [].} =
  ## Runs the compiled program from the offset the context names.
  NativeStatus(machine.call(context.addr))

type
  Loop = object
    ## A loop whose globals can live in registers while it runs.
    start: int
    stop: int
    globals: seq[int32]

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

proc fitsLoop(item: Instruction): bool {.raises: [].} =
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
  of ModuloGlobalImmediateOp:
    item.c != 0
  of JumpUnlessGlobalModuloEqualZeroOp:
    item.b != 0
  else:
    false

proc findLoops(code: seq[Instruction], capacity: int): seq[Loop]
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
      if covered[index] or not code[index].fitsLoop:
        fits = false
        break
      code[index].loopGlobals(globals)
    if not fits or globals.len == 0 or globals.len > capacity:
      continue
    for index in start ..< stop:
      covered[index] = true
    result.add(Loop(start: start, stop: stop, globals: globals))

proc emitProgram(code: seq[Instruction], routines: seq[RoutineExtent],
    ownerOf: seq[int32], extents: seq[ArrayExtent], constants: seq[int32],
    limits: CallLimits, far: bool): (seq[byte], seq[int])
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
    let dispatchLabel = e.label()
    let slowLabel = e.label()
    let failedLabel = e.label()

    let loops = findLoops(code, Hoisting.len)
    var loopAt = newSeq[int](code.len)
    for index in 0 ..< code.len:
      loopAt[index] = -1
    for number, loop in loops:
      loopAt[loop.start] = number
      general[loop.start] = e.label()

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
        e.readValue(0, 2, slot(item.b))
        e.readValue(1, 3, slot(item.c))
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
      of LoadStringOp, TextCallOp, HostCallOp, PrintTextOp, PrintValueOp,
          PrintNewlineOp:
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

    for index in 0 ..< code.len:
      e.place(blocks[index])
      let number = loopAt[index]
      if number >= 0:
        # Entering a loop's head: prove its globals whole numbers and move
        # them into registers, or run it in general code if any is not.
        # Every tag is looked at before any register is filled, because
        # one of those registers may be what general code reads through.
        let loop = loops[number]
        e.beginHoisting()
        for which in loop.globals:
          e.guardHoisted(which, general[loop.start])
        for position, which in loop.globals:
          e.loadHoisted(position, which)
        e.jump(loopCopies[number][0])
        e.place(general[index])
      emitInstruction(index, false, Loop(), @[], noExits)

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
    e.slowRoutine(failedLabel)
    e.place(failedLabel)
    e.epilogue(NativeFailed)

    let bytes = e.finish()
    var starts = newSeq[int](code.len + 1)
    for index in 0 .. code.len:
      starts[index] = e.offsetBytes(blocks[index])
    (bytes, starts)

proc compileProgram*(code: seq[Instruction], routines: seq[RoutineExtent],
    extents: seq[ArrayExtent], constants: seq[int32], globals, hostData,
    arguments: int, limits: CallLimits): Machine {.raises: [BasicError].} =
  ## Compiles every offset of a program to machine code, or returns nil
  ## when this target has no backend or the program is outside what the
  ## generator is sure of. Generated code indexes storage without
  ## checking, so every index it will use is proved in range here first.
  when not (NativeArm64 or NativeAmd64):
    return nil
  else:
    if not layoutMatches() or code.len == 0 or routines.len == 0:
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
        limits, false)
    except BasicError:
      # Some branch could not reach; every branch then goes the long way.
      emitted = emitProgram(code, routines, ownerOf, extents, constants,
        limits, true)
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
