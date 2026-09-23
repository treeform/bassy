## Encodes the AArch64 subset the BASIC compiler needs.
## Every instruction is one 32-bit word, so labels patch in place.
## Encodings follow the Arm Architecture Reference Manual field layouts.

import numbers

type
  Register* = distinct uint32

  Width* = enum
    ## Selects the 32-bit W or 64-bit X view of a register.
    Word32,
    Word64

  Condition* = enum
    ## Branch and select conditions, in architectural encoding order.
    EqualCondition,
    NotEqualCondition,
    CarrySetCondition,
    CarryClearCondition,
    NegativeCondition,
    PositiveCondition,
    OverflowCondition,
    NoOverflowCondition,
    UnsignedGreaterCondition,
    UnsignedLessEqualCondition,
    GreaterEqualCondition,
    LessCondition,
    GreaterCondition,
    LessEqualCondition,
    AlwaysCondition

  Label* = distinct int

  FixupKind = enum
    Branch26Fixup,
    Branch19Fixup

  Fixup = object
    kind: FixupKind
    at: int
    label: int

  Assembler* = object
    ## Collects instruction words plus unresolved label references.
    code*: seq[uint32]
    targets: seq[int]
    fixups: seq[Fixup]

const
  x0* = Register(0)
  x1* = Register(1)
  x2* = Register(2)
  x3* = Register(3)
  x4* = Register(4)
  x5* = Register(5)
  x6* = Register(6)
  x7* = Register(7)
  x8* = Register(8)
  x9* = Register(9)
  x10* = Register(10)
  x11* = Register(11)
  x12* = Register(12)
  x13* = Register(13)
  x14* = Register(14)
  x15* = Register(15)
  x16* = Register(16)
  x17* = Register(17)
  x19* = Register(19)
  x20* = Register(20)
  x21* = Register(21)
  x22* = Register(22)
  x23* = Register(23)
  x24* = Register(24)
  x25* = Register(25)
  x26* = Register(26)
  x27* = Register(27)
  x28* = Register(28)
  framePointer* = Register(29)
  linkRegister* = Register(30)
  zeroRegister* = Register(31)
  stackPointer* = Register(31)

proc number(register: Register): uint32 {.inline, raises: [].} =
  ## Returns the five-bit encoding of a register.
  uint32(register) and 31'u32

proc sizeBit(width: Width): uint32 {.inline, raises: [].} =
  ## Returns the sf field that selects the 64-bit form.
  if width == Word64: 1'u32 shl 31 else: 0'u32

proc fail(message: string) {.noreturn, raises: [BasicError].} =
  ## Reports a controlled encoding failure.
  raise newException(BasicError, "BASIC " & message)

proc emit(assembler: var Assembler, word: uint32) {.inline, raises: [].} =
  ## Appends one encoded instruction.
  assembler.code.add(word)

proc position*(assembler: Assembler): int {.inline, raises: [].} =
  ## Returns the index of the next instruction word.
  assembler.code.len

## Labels

proc label*(assembler: var Assembler): Label {.raises: [].} =
  ## Reserves an unplaced branch target.
  assembler.targets.add(-1)
  Label(assembler.targets.len - 1)

proc place*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Fixes a label at the current instruction position.
  assembler.targets[int(target)] = assembler.code.len

proc resolve*(assembler: var Assembler) {.raises: [BasicError].} =
  ## Patches every recorded branch once all labels are placed.
  for fixup in assembler.fixups:
    let destination = assembler.targets[fixup.label]
    if destination < 0:
      fail("assembler label was never placed")
    let distance = destination - fixup.at
    case fixup.kind
    of Branch26Fixup:
      if distance < -(1 shl 25) or distance >= (1 shl 25):
        fail("assembler branch is out of range")
      assembler.code[fixup.at] = assembler.code[fixup.at] or
        (uint32(distance) and 0x03FFFFFF'u32)
    of Branch19Fixup:
      if distance < -(1 shl 18) or distance >= (1 shl 18):
        fail("assembler branch is out of range")
      assembler.code[fixup.at] = assembler.code[fixup.at] or
        ((uint32(distance) and 0x0007FFFF'u32) shl 5)
  assembler.fixups.setLen(0)

## Moves and immediates

proc moveZero*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Writes a 16-bit field and zeroes the rest of the register.
  let base = if width == Word64: 0xD2800000'u32 else: 0x52800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc moveNot*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Writes the inverse of a 16-bit field into a cleared register.
  let base = if width == Word64: 0x92800000'u32 else: 0x12800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc moveKeep*(assembler: var Assembler, width: Width, destination: Register,
    value: uint16, shift = 0) {.raises: [].} =
  ## Overwrites one 16-bit field and keeps the others.
  let base = if width == Word64: 0xF2800000'u32 else: 0x72800000'u32
  assembler.emit(
    base or (uint32(shift div 16) shl 21) or (uint32(value) shl 5) or
      destination.number
  )

proc logical(assembler: var Assembler, base: uint32, width: Width,
    destination, left, right: Register, shift: int) {.inline, raises: [].} =
  ## Encodes one shifted-register logical instruction.
  assembler.emit(
    base or width.sizeBit or (right.number shl 16) or
      (uint32(shift) shl 10) or (left.number shl 5) or destination.number
  )

proc moveRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Copies one register into another through ORR with the zero register.
  assembler.logical(
    0x2A000000'u32, width, destination, zeroRegister, source, 0
  )

proc loadImmediate*(assembler: var Assembler, width: Width,
    destination: Register, value: int64) {.raises: [].} =
  ## Materializes any constant using the fewest wide moves.
  let bits =
    if width == Word64: cast[uint64](value)
    else: cast[uint64](value) and 0xFFFFFFFF'u64
  let fields = if width == Word64: 4 else: 2
  var negated = not bits
  if width == Word32:
    negated = negated and 0xFFFFFFFF'u64
  var zeroCount = 0
  var onesCount = 0
  for index in 0 ..< fields:
    let field = uint16((bits shr (index * 16)) and 0xFFFF'u64)
    if field == 0:
      inc zeroCount
    if field == 0xFFFF'u16:
      inc onesCount
  if onesCount > zeroCount:
    var first = true
    for index in 0 ..< fields:
      let field = uint16((negated shr (index * 16)) and 0xFFFF'u64)
      if first:
        assembler.moveNot(width, destination, field, index * 16)
        first = false
      elif field != 0:
        let keep = uint16((bits shr (index * 16)) and 0xFFFF'u64)
        assembler.moveKeep(width, destination, keep, index * 16)
  else:
    var first = true
    for index in 0 ..< fields:
      let field = uint16((bits shr (index * 16)) and 0xFFFF'u64)
      if field == 0 and not first:
        continue
      if first:
        assembler.moveZero(width, destination, field, index * 16)
        first = false
      else:
        assembler.moveKeep(width, destination, field, index * 16)

## Arithmetic

proc arithmeticImmediate(assembler: var Assembler, base: uint32, width: Width,
    destination, source: Register, value: int) {.raises: [BasicError].} =
  ## Encodes an add or subtract with a 12-bit unsigned immediate.
  if value < 0 or value > 4095:
    fail("assembler immediate is out of range")
  assembler.emit(
    base or width.sizeBit or (uint32(value) shl 10) or
      (source.number shl 5) or destination.number
  )

proc addImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, value: int) {.raises: [BasicError].} =
  ## Adds a small unsigned constant.
  assembler.arithmeticImmediate(
    0x11000000'u32, width, destination, source, value
  )

proc subtractImmediate*(assembler: var Assembler, width: Width,
    destination, source: Register, value: int) {.raises: [BasicError].} =
  ## Subtracts a small unsigned constant.
  assembler.arithmeticImmediate(
    0x51000000'u32, width, destination, source, value
  )

proc compareImmediate*(assembler: var Assembler, width: Width,
    source: Register, value: int) {.raises: [BasicError].} =
  ## Sets flags from a subtraction, discarding the difference.
  assembler.arithmeticImmediate(
    0x71000000'u32, width, zeroRegister, source, value
  )

proc arithmeticRegister(assembler: var Assembler, base: uint32, width: Width,
    destination, left, right: Register, shift: int) {.inline, raises: [].} =
  ## Encodes an add or subtract of an optionally shifted register.
  assembler.emit(
    base or width.sizeBit or (right.number shl 16) or
      (uint32(shift) shl 10) or (left.number shl 5) or destination.number
  )

proc addRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Adds two registers, optionally shifting the second left.
  assembler.arithmeticRegister(
    0x0B000000'u32, width, destination, left, right, shift
  )

proc subtractRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Subtracts the second register from the first.
  assembler.arithmeticRegister(
    0x4B000000'u32, width, destination, left, right, shift
  )

proc compareRegister*(assembler: var Assembler, width: Width,
    left, right: Register) {.raises: [].} =
  ## Sets flags from the difference of two registers.
  assembler.arithmeticRegister(
    0x6B000000'u32, width, zeroRegister, left, right, 0
  )

proc negate*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Writes the two's complement negation of a register.
  assembler.arithmeticRegister(
    0x4B000000'u32, width, destination, zeroRegister, source, 0
  )

proc multiplyAdd*(assembler: var Assembler, width: Width,
    destination, left, right, addend: Register) {.raises: [].} =
  ## Computes addend plus the product of two registers.
  assembler.emit(
    0x1B000000'u32 or width.sizeBit or (right.number shl 16) or
      (addend.number shl 10) or (left.number shl 5) or destination.number
  )

proc multiplySubtract*(assembler: var Assembler, width: Width,
    destination, left, right, minuend: Register) {.raises: [].} =
  ## Subtracts the product of two registers from a third.
  assembler.emit(
    0x1B008000'u32 or width.sizeBit or (right.number shl 16) or
      (minuend.number shl 10) or (left.number shl 5) or destination.number
  )

proc multiply*(assembler: var Assembler, width: Width,
    destination, left, right: Register) {.raises: [].} =
  ## Multiplies two registers.
  assembler.multiplyAdd(width, destination, left, right, zeroRegister)

proc signedDivide*(assembler: var Assembler, width: Width,
    destination, left, right: Register) {.raises: [].} =
  ## Divides with truncation toward zero, yielding zero on a zero divisor.
  assembler.emit(
    0x1AC00C00'u32 or width.sizeBit or (right.number shl 16) or
      (left.number shl 5) or destination.number
  )

## Logic

proc andRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise conjunction.
  assembler.logical(0x0A000000'u32, width, destination, left, right, shift)

proc orRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise disjunction.
  assembler.logical(0x2A000000'u32, width, destination, left, right, shift)

proc xorRegister*(assembler: var Assembler, width: Width,
    destination, left, right: Register, shift = 0) {.raises: [].} =
  ## Computes a bitwise exclusive disjunction.
  assembler.logical(0x4A000000'u32, width, destination, left, right, shift)

proc notRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Writes the bitwise complement of a register.
  assembler.logical(
    0x2A200000'u32, width, destination, zeroRegister, source, 0
  )

proc setOnCondition*(assembler: var Assembler, width: Width,
    destination: Register, condition: Condition) {.raises: [].} =
  ## Writes BASIC's -1 when the condition holds and zero otherwise.
  let inverted = uint32(ord(condition)) xor 1'u32
  assembler.emit(
    0x5A800000'u32 or width.sizeBit or (zeroRegister.number shl 16) or
      (inverted shl 12) or (zeroRegister.number shl 5) or destination.number
  )

## Memory

proc scaledOffset(offset, scale: int): uint32 {.raises: [BasicError].} =
  ## Converts a byte offset into the scaled 12-bit immediate field.
  if offset < 0 or offset mod scale != 0 or (offset div scale) > 4095:
    fail("assembler memory offset is out of range")
  uint32(offset div scale)

proc loadByte*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads one byte, zero-extending into the destination.
  assembler.emit(
    0x39400000'u32 or (scaledOffset(offset, 1) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeByte*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Stores the low byte of a register.
  assembler.emit(
    0x39000000'u32 or (scaledOffset(offset, 1) shl 10) or
      (base.number shl 5) or source.number
  )

proc loadWord*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads 32 bits, zero-extending into the destination.
  assembler.emit(
    0xB9400000'u32 or (scaledOffset(offset, 4) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeWord*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Stores the low 32 bits of a register.
  assembler.emit(
    0xB9000000'u32 or (scaledOffset(offset, 4) shl 10) or
      (base.number shl 5) or source.number
  )

proc loadDouble*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads 64 bits.
  assembler.emit(
    0xF9400000'u32 or (scaledOffset(offset, 8) shl 10) or
      (base.number shl 5) or destination.number
  )

proc storeDouble*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Stores 64 bits.
  assembler.emit(
    0xF9000000'u32 or (scaledOffset(offset, 8) shl 10) or
      (base.number shl 5) or source.number
  )

proc storePair*(assembler: var Assembler, first, second, base: Register,
    offset: int, preIndex = false) {.raises: [BasicError].} =
  ## Stores two 64-bit registers, optionally updating the base first.
  if offset mod 8 != 0 or offset div 8 < -64 or offset div 8 > 63:
    fail("assembler memory offset is out of range")
  let base32 = if preIndex: 0xA9800000'u32 else: 0xA9000000'u32
  assembler.emit(
    base32 or ((uint32(offset div 8) and 0x7F'u32) shl 15) or
      (second.number shl 10) or (base.number shl 5) or first.number
  )

proc loadPair*(assembler: var Assembler, first, second, base: Register,
    offset: int, postIndex = false) {.raises: [BasicError].} =
  ## Loads two 64-bit registers, optionally updating the base afterward.
  if offset mod 8 != 0 or offset div 8 < -64 or offset div 8 > 63:
    fail("assembler memory offset is out of range")
  let base32 = if postIndex: 0xA8C00000'u32 else: 0xA9400000'u32
  assembler.emit(
    base32 or ((uint32(offset div 8) and 0x7F'u32) shl 15) or
      (second.number shl 10) or (base.number shl 5) or first.number
  )

## Branches

proc branch*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Jumps unconditionally to a label.
  assembler.fixups.add(
    Fixup(kind: Branch26Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x14000000'u32)

proc branchIf*(assembler: var Assembler, condition: Condition,
    target: Label) {.raises: [].} =
  ## Jumps to a label when the condition holds.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x54000000'u32 or uint32(ord(condition)))

proc branchIfZero*(assembler: var Assembler, width: Width, source: Register,
    target: Label) {.raises: [].} =
  ## Jumps to a label when a register holds zero.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x34000000'u32 or width.sizeBit or source.number)

proc branchIfNotZero*(assembler: var Assembler, width: Width,
    source: Register, target: Label) {.raises: [].} =
  ## Jumps to a label when a register holds anything but zero.
  assembler.fixups.add(
    Fixup(kind: Branch19Fixup, at: assembler.code.len, label: int(target))
  )
  assembler.emit(0x35000000'u32 or width.sizeBit or source.number)

proc callRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Calls the address held in a register, setting the link register.
  assembler.emit(0xD63F0000'u32 or (target.number shl 5))

proc jumpRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Jumps to the address held in a register without linking.
  assembler.emit(0xD61F0000'u32 or (target.number shl 5))

proc returnToCaller*(assembler: var Assembler) {.raises: [].} =
  ## Returns through the link register.
  assembler.emit(0xD65F03C0'u32)

proc testLowBits*(assembler: var Assembler, width: Width, source: Register,
    count: int) {.raises: [BasicError].} =
  ## Sets flags from the lowest bits of a register, leaving the result
  ## nowhere. The logical immediate for a run of ones starting at bit zero
  ## is simply its length minus one.
  if count < 1 or count > (if width == Word64: 63 else: 31):
    fail("assembler bit count is out of range")
  assembler.emit(
    0x72000000'u32 or width.sizeBit or
      (if width == Word64: 1'u32 shl 22 else: 0'u32) or
      (uint32(count - 1) shl 10) or (source.number shl 5) or 31'u32
  )
