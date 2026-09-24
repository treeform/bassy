## Encodes the x86-64 subset the BASIC compiler needs.
## Instructions vary in length, so labels record the displacement field
## and patch it once every target is placed.

import numbers

type
  Register* = distinct uint32

  Width* = enum
    ## Selects the 32-bit or 64-bit operand size.
    Word32,
    Word64

  Condition* = enum
    ## Branch conditions, in architectural encoding order.
    OverflowCondition,
    NoOverflowCondition,
    BelowCondition,
    AboveEqualCondition,
    EqualCondition,
    NotEqualCondition,
    BelowEqualCondition,
    AboveCondition,
    SignCondition,
    NoSignCondition,
    ParityCondition,
    NoParityCondition,
    LessCondition,
    GreaterEqualCondition,
    LessEqualCondition,
    GreaterCondition

  Label* = distinct int

  Fixup = object
    at: int
    next: int
    label: int

  Assembler* = object
    ## Collects encoded bytes plus unresolved label references.
    code*: seq[byte]
    targets: seq[int]
    fixups: seq[Fixup]

const
  rax* = Register(0)
  rcx* = Register(1)
  rdx* = Register(2)
  rbx* = Register(3)
  rsp* = Register(4)
  rbp* = Register(5)
  rsi* = Register(6)
  rdi* = Register(7)
  r8* = Register(8)
  r9* = Register(9)
  r10* = Register(10)
  r11* = Register(11)
  r12* = Register(12)
  r13* = Register(13)
  r14* = Register(14)
  r15* = Register(15)

proc number(register: Register): uint32 {.inline, raises: [].} =
  ## Returns the four-bit encoding of a register.
  uint32(register) and 15'u32

proc fail(message: string) {.noreturn, raises: [BasicError].} =
  ## Reports a controlled encoding failure.
  raise newException(BasicError, "BASIC " & message)

proc emit(assembler: var Assembler, value: byte) {.inline, raises: [].} =
  ## Appends one encoded byte.
  assembler.code.add(value)

proc emitDouble(assembler: var Assembler, value: int32) {.raises: [].} =
  ## Appends a little-endian 32-bit field.
  let bits = cast[uint32](value)
  for shift in [0, 8, 16, 24]:
    assembler.emit(byte((bits shr shift) and 0xFF'u32))

proc emitQuad(assembler: var Assembler, value: int64) {.raises: [].} =
  ## Appends a little-endian 64-bit field.
  let bits = cast[uint64](value)
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    assembler.emit(byte((bits shr shift) and 0xFF'u64))

proc position*(assembler: Assembler): int {.inline, raises: [].} =
  ## Returns the offset of the next byte.
  assembler.code.len

## Prefixes and operand encoding

proc prefix(assembler: var Assembler, width: Width, reg, rm: Register)
    {.raises: [].} =
  ## Emits a REX prefix when the operands or the width require one.
  var value = 0x40'u32
  if width == Word64:
    value = value or 0x08'u32
  if reg.number >= 8:
    value = value or 0x04'u32
  if rm.number >= 8:
    value = value or 0x01'u32
  if value != 0x40'u32:
    assembler.emit(byte(value))

proc directOperand(assembler: var Assembler, reg, rm: Register)
    {.raises: [].} =
  ## Encodes a register-to-register operand pair.
  assembler.emit(
    byte(0xC0'u32 or ((reg.number and 7'u32) shl 3) or (rm.number and 7'u32))
  )

proc memoryOperand(assembler: var Assembler, reg, base: Register,
    displacement: int) {.raises: [BasicError].} =
  ## Encodes a register plus a base register with a displacement.
  if base.number == 4 or base.number == 12:
    fail("assembler cannot address through this base register")
  let low = (reg.number and 7'u32) shl 3
  let rm = base.number and 7'u32
  # An r13 base always needs an explicit displacement byte.
  if displacement == 0 and rm != 5:
    assembler.emit(byte(0x00'u32 or low or rm))
  elif displacement >= -128 and displacement <= 127:
    assembler.emit(byte(0x40'u32 or low or rm))
    assembler.emit(byte(cast[uint8](int8(displacement))))
  else:
    assembler.emit(byte(0x80'u32 or low or rm))
    assembler.emitDouble(int32(displacement))

## Labels

proc label*(assembler: var Assembler): Label {.raises: [].} =
  ## Reserves an unplaced branch target.
  assembler.targets.add(-1)
  Label(assembler.targets.len - 1)

proc place*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Fixes a label at the current byte offset.
  assembler.targets[int(target)] = assembler.code.len

proc resolve*(assembler: var Assembler) {.raises: [BasicError].} =
  ## Patches every recorded displacement once all labels are placed.
  for fixup in assembler.fixups:
    let destination = assembler.targets[fixup.label]
    if destination < 0:
      fail("assembler label was never placed")
    let distance = destination - fixup.next
    if distance < low(int32) or distance > high(int32):
      fail("assembler branch is out of range")
    let bits = cast[uint32](int32(distance))
    for index in 0 ..< 4:
      assembler.code[fixup.at + index] =
        byte((bits shr (index * 8)) and 0xFF'u32)
  assembler.fixups.setLen(0)

## Moves

proc moveRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Copies one register into another.
  assembler.prefix(width, source, destination)
  assembler.emit(0x89)
  assembler.directOperand(source, destination)

proc loadImmediate*(assembler: var Assembler, width: Width,
    destination: Register, value: int64) {.raises: [].} =
  ## Materializes a constant, using the shortest form that holds it.
  if width == Word32 or (value >= 0 and value <= high(int32)):
    if destination.number >= 8:
      assembler.emit(0x41)
    assembler.emit(byte(0xB8'u32 + (destination.number and 7'u32)))
    assembler.emitDouble(int32(value))
  else:
    assembler.prefix(Word64, Register(0), destination)
    assembler.emit(byte(0xB8'u32 + (destination.number and 7'u32)))
    assembler.emitQuad(value)

## Memory

proc loadWord*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads 32 bits into the destination.
  assembler.prefix(Word32, destination, base)
  assembler.emit(0x8B)
  assembler.memoryOperand(destination, base, offset)

proc storeWord*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Stores the low 32 bits of a register.
  assembler.prefix(Word32, source, base)
  assembler.emit(0x89)
  assembler.memoryOperand(source, base, offset)

proc loadDouble*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads 64 bits into the destination.
  assembler.prefix(Word64, destination, base)
  assembler.emit(0x8B)
  assembler.memoryOperand(destination, base, offset)

proc storeDouble*(assembler: var Assembler, source, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Stores 64 bits from a register.
  assembler.prefix(Word64, source, base)
  assembler.emit(0x89)
  assembler.memoryOperand(source, base, offset)

proc loadByteZeroed*(assembler: var Assembler, destination, base: Register,
    offset = 0) {.raises: [BasicError].} =
  ## Loads one byte, zero-extending it into the destination.
  assembler.prefix(Word32, destination, base)
  assembler.emit(0x0F)
  assembler.emit(0xB6)
  assembler.memoryOperand(destination, base, offset)

proc storeByteImmediate*(assembler: var Assembler, base: Register,
    offset: int, value: byte) {.raises: [BasicError].} =
  ## Stores a constant byte through a base register.
  assembler.prefix(Word32, Register(0), base)
  assembler.emit(0xC6)
  assembler.memoryOperand(Register(0), base, offset)
  assembler.emit(value)

## Arithmetic

proc addRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Adds the source into the destination.
  assembler.prefix(width, source, destination)
  assembler.emit(0x01)
  assembler.directOperand(source, destination)

proc subtractRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Subtracts the source from the destination.
  assembler.prefix(width, source, destination)
  assembler.emit(0x29)
  assembler.directOperand(source, destination)

proc groupImmediate(assembler: var Assembler, width: Width,
    extension: uint32, target: Register, value: int32) {.raises: [].} =
  ## Encodes one of the immediate arithmetic forms by its opcode extension.
  assembler.prefix(width, Register(extension), target)
  assembler.emit(0x81)
  assembler.directOperand(Register(extension), target)
  assembler.emitDouble(value)

proc addImmediate*(assembler: var Assembler, width: Width,
    target: Register, value: int32) {.raises: [].} =
  ## Adds a constant to a register.
  assembler.groupImmediate(width, 0, target, value)

proc subtractImmediate*(assembler: var Assembler, width: Width,
    target: Register, value: int32) {.raises: [].} =
  ## Subtracts a constant from a register.
  assembler.groupImmediate(width, 5, target, value)

proc compareImmediate*(assembler: var Assembler, width: Width,
    target: Register, value: int32) {.raises: [].} =
  ## Sets flags from a register against a constant.
  assembler.groupImmediate(width, 7, target, value)

proc compareRegister*(assembler: var Assembler, width: Width,
    left, right: Register) {.raises: [].} =
  ## Sets flags from the difference of two registers.
  assembler.prefix(width, right, left)
  assembler.emit(0x39)
  assembler.directOperand(right, left)

proc testRegister*(assembler: var Assembler, width: Width,
    left, right: Register) {.raises: [].} =
  ## Sets flags from the conjunction of two registers.
  assembler.prefix(width, right, left)
  assembler.emit(0x85)
  assembler.directOperand(right, left)

proc multiplyRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Multiplies the destination by the source.
  assembler.prefix(width, destination, source)
  assembler.emit(0x0F)
  assembler.emit(0xAF)
  assembler.directOperand(destination, source)

proc signExtendToPair*(assembler: var Assembler, width: Width)
    {.raises: [].} =
  ## Widens the accumulator into the high half before a signed divide.
  if width == Word64:
    assembler.emit(0x48)
  assembler.emit(0x99)

proc signedDivide*(assembler: var Assembler, width: Width,
    divisor: Register) {.raises: [].} =
  ## Divides the widened accumulator, leaving the remainder in rdx.
  assembler.prefix(width, Register(7), divisor)
  assembler.emit(0xF7)
  assembler.directOperand(Register(7), divisor)

## Stack and control flow

proc push*(assembler: var Assembler, source: Register) {.raises: [].} =
  ## Pushes a 64-bit register.
  if source.number >= 8:
    assembler.emit(0x41)
  assembler.emit(byte(0x50'u32 + (source.number and 7'u32)))

proc pop*(assembler: var Assembler, destination: Register) {.raises: [].} =
  ## Pops a 64-bit register.
  if destination.number >= 8:
    assembler.emit(0x41)
  assembler.emit(byte(0x58'u32 + (destination.number and 7'u32)))

proc branch*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Jumps unconditionally to a label.
  assembler.emit(0xE9)
  assembler.fixups.add(
    Fixup(at: assembler.code.len, next: assembler.code.len + 4,
      label: int(target))
  )
  assembler.emitDouble(0)

proc branchIf*(assembler: var Assembler, condition: Condition,
    target: Label) {.raises: [].} =
  ## Jumps to a label when the condition holds.
  assembler.emit(0x0F)
  assembler.emit(byte(0x80'u32 + uint32(ord(condition))))
  assembler.fixups.add(
    Fixup(at: assembler.code.len, next: assembler.code.len + 4,
      label: int(target))
  )
  assembler.emitDouble(0)

proc returnToCaller*(assembler: var Assembler) {.raises: [].} =
  ## Returns to the caller.
  assembler.emit(0xC3)

proc storeWordImmediate*(assembler: var Assembler, base: Register,
    offset: int, value: int32) {.raises: [BasicError].} =
  ## Stores a 32-bit constant through a base register.
  assembler.prefix(Word32, Register(0), base)
  assembler.emit(0xC7)
  assembler.memoryOperand(Register(0), base, offset)
  assembler.emitDouble(value)

proc negateRegister*(assembler: var Assembler, width: Width,
    target: Register) {.raises: [].} =
  ## Replaces a register with its two's complement negation.
  assembler.prefix(width, Register(3), target)
  assembler.emit(0xF7)
  assembler.directOperand(Register(3), target)

proc setIfCondition*(assembler: var Assembler, target: Register,
    condition: Condition) {.raises: [].} =
  ## Writes one when the condition holds and zero otherwise.
  ## The low byte is set, so the register is cleared first; xor would
  ## disturb the flags, and movzx afterwards would need a second register.
  ## A REX prefix is forced for the byte form, so rsp, rbp, rsi and rdi
  ## name their low bytes rather than ah, ch, dh and bh.
  let rex = byte(0x40'u32 or (target.number shr 3))
  assembler.emit(rex)
  assembler.emit(0x0F)
  assembler.emit(byte(0x90'u32 + uint32(ord(condition))))
  assembler.directOperand(Register(0), target)
  assembler.emit(byte(0x40'u32 or ((target.number shr 3) shl 2) or
    (target.number shr 3)))
  assembler.emit(0x0F)
  assembler.emit(0xB6)
  assembler.directOperand(target, target)

proc shiftLeftImmediate*(assembler: var Assembler, width: Width,
    target: Register, count: int) {.raises: [BasicError].} =
  ## Shifts a register left by a constant.
  if count < 0 or count > 63:
    fail("assembler shift count is out of range")
  assembler.prefix(width, Register(4), target)
  assembler.emit(0xC1)
  assembler.directOperand(Register(4), target)
  assembler.emit(byte(count))

proc signExtendDouble*(assembler: var Assembler,
    destination, source: Register) {.raises: [].} =
  ## Widens a 32-bit register into a 64-bit one, keeping the sign.
  assembler.prefix(Word64, destination, source)
  assembler.emit(0x63)
  assembler.directOperand(destination, source)

proc shiftRightImmediate*(assembler: var Assembler, width: Width,
    target: Register, count: int) {.raises: [BasicError].} =
  ## Shifts right, keeping the sign, by a constant.
  if count < 0 or count > 63:
    fail("assembler shift count is out of range")
  assembler.prefix(width, Register(7), target)
  assembler.emit(0xC1)
  assembler.directOperand(Register(7), target)
  assembler.emit(byte(count))

proc storeByteLow*(assembler: var Assembler, base: Register, offset: int,
    source: Register) {.raises: [BasicError].} =
  ## Stores the low byte of a register through a base register.
  ## The REX prefix is forced so the low byte is named, not the high one.
  assembler.emit(byte(0x40'u32 or ((source.number shr 3) shl 2) or
    (base.number shr 3)))
  assembler.emit(0x88)
  assembler.memoryOperand(source, base, offset)

proc offsetOf*(assembler: Assembler, target: Label): int {.raises: [].} =
  ## Returns where a label ended up, in bytes.
  assembler.targets[int(target)]

## Logic and indirect control flow

proc logical(assembler: var Assembler, opcode: byte, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Encodes one register-to-register logical instruction.
  assembler.prefix(width, source, destination)
  assembler.emit(opcode)
  assembler.directOperand(source, destination)

proc andRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Keeps the bits both registers hold.
  assembler.logical(0x21, width, destination, source)

proc orRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Keeps the bits either register holds.
  assembler.logical(0x09, width, destination, source)

proc xorRegister*(assembler: var Assembler, width: Width,
    destination, source: Register) {.raises: [].} =
  ## Keeps the bits exactly one register holds.
  assembler.logical(0x31, width, destination, source)

proc notRegister*(assembler: var Assembler, width: Width,
    target: Register) {.raises: [].} =
  ## Flips every bit of a register.
  assembler.prefix(width, Register(2), target)
  assembler.emit(0xF7)
  assembler.directOperand(Register(2), target)

proc callLabel*(assembler: var Assembler, target: Label) {.raises: [].} =
  ## Calls a label, pushing the return address.
  assembler.emit(0xE8)
  assembler.fixups.add(
    Fixup(at: assembler.code.len, next: assembler.code.len + 4,
      label: int(target))
  )
  assembler.emitDouble(0)

proc callRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Calls the address held in a register.
  assembler.prefix(Word32, Register(2), target)
  assembler.emit(0xFF)
  assembler.directOperand(Register(2), target)

proc jumpRegister*(assembler: var Assembler, target: Register)
    {.raises: [].} =
  ## Jumps to the address held in a register.
  assembler.prefix(Word32, Register(4), target)
  assembler.emit(0xFF)
  assembler.directOperand(Register(4), target)

proc testImmediate*(assembler: var Assembler, width: Width,
    target: Register, value: int32) {.raises: [].} =
  ## Sets flags from a register masked by a constant, keeping neither.
  assembler.prefix(width, Register(0), target)
  assembler.emit(0xF7)
  assembler.directOperand(Register(0), target)
  assembler.emitDouble(value)
