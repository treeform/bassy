import fixxy

export fixxy

type
  BasicError* = object of CatchableError

  ValueKind* = enum
    IntegerValue,
    FixedValue,
    StringValue,
    ArrayValue,
    BlobValue

  Value* = object
    ## A number or owned string reference, with an integer zero default.
    case kind: ValueKind
    of IntegerValue:
      integer: int32
    of FixedValue:
      decimal: Fixed
    of StringValue, ArrayValue, BlobValue:
      reference: uint64

proc kind*(value: Value): ValueKind {.inline, raises: [].} =
  ## Returns the stored type of a value.
  value.kind

proc stringValue*(owner: uint32, handle: int32): Value {.raises: [].} =
  ## Constructs an opaque reference for the runtime string store.
  Value(kind: StringValue, reference: (uint64(owner) shl 32) or uint32(handle))

proc stringOwner*(value: Value): uint32 {.raises: [BasicError].} =
  ## Reads the owner of a string reference after checking its type.
  if value.kind != StringValue:
    raise newException(BasicError, "BASIC value must be a string")
  uint32(value.reference shr 32)

proc stringHandle*(value: Value): int32 {.raises: [BasicError].} =
  ## Reads a string slot after checking its type.
  if value.kind != StringValue:
    raise newException(BasicError, "BASIC value must be a string")
  cast[int32](uint32(value.reference and 0xffffffff'u64))

proc bufferValue*(kind: ValueKind, owner: uint32, slot: int32): Value =
  ## Constructs a typed reference for a trusted native buffer store.
  if kind notin {ArrayValue, BlobValue}:
    raise newException(BasicError, "invalid BASIC buffer type")
  let reference = (uint64(owner) shl 32) or uint32(slot)
  case kind
  of ArrayValue:
    Value(kind: ArrayValue, reference: reference)
  of BlobValue:
    Value(kind: BlobValue, reference: reference)
  else:
    raise newException(BasicError, "invalid BASIC buffer type")

proc bufferOwner*(value: Value): uint32 =
  ## Reads the generation of an opaque array or blob reference.
  if value.kind notin {ArrayValue, BlobValue}:
    raise newException(BasicError, "BASIC value must be an array or blob")
  uint32(value.reference shr 32)

proc bufferSlot*(value: Value): int32 =
  ## Reads the slot of an opaque array or blob reference.
  if value.kind notin {ArrayValue, BlobValue}:
    raise newException(BasicError, "BASIC value must be an array or blob")
  cast[int32](uint32(value.reference))

converter toValue*(value: int32): Value {.inline, raises: [].} =
  ## Wraps an integer without changing its representation.
  Value(kind: IntegerValue, integer: value)

converter toValue*(value: bool): Value {.inline, raises: [].} =
  ## Converts a Nim Boolean to BASIC's integer -1 or zero.
  toValue(-int32(value))

converter toValue*(value: int): Value {.inline, raises: [BasicError].} =
  ## Converts a native integer after checking the portable int32 range.
  if value < int(low(int32)) or value > int(high(int32)):
    raise newException(BasicError, "BASIC integer is outside the int32 range")
  toValue(int32(value))

converter toValue*(value: Fixed): Value {.inline, raises: [].} =
  ## Wraps a Q16.16 number without changing its stored bits.
  Value(kind: FixedValue, decimal: value)

proc asFixed*(value: Value): Fixed {.inline, raises: [BasicError].} =
  ## Reads fixed-point data or converts an integer within the Q16.16 range.
  case value.kind
  of IntegerValue:
    if value.integer < -32768 or value.integer > 32767:
      raise newException(
        BasicError,
        "BASIC integer is outside the fixed-point range"
      )
    fixed(value.integer)
  of FixedValue:
    value.decimal
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc asBool*(value: Value): bool {.inline, raises: [BasicError].} =
  ## Tests a BASIC condition, where every nonzero numeric value is true.
  case value.kind
  of IntegerValue:
    value.integer != 0
  of FixedValue:
    value.decimal != FixedZero
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc asInt*(value: Value): int32 {.inline, raises: [BasicError].} =
  ## Reads an integer, rejecting fractional fixed-point values.
  case value.kind
  of IntegerValue:
    value.integer
  of FixedValue:
    if value.decimal.fraction != 0:
      raise newException(BasicError, "BASIC value must be an exact int32")
    value.decimal.toInt
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc `$`*(value: Value): string {.raises: [BasicError].} =
  ## Formats a numeric value using its stored representation.
  case value.kind
  of IntegerValue:
    $value.integer
  of FixedValue:
    $value.decimal
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

template fixedResult(expression: untyped): Value =
  ## Maps optional Fixxy overflow assertions to catchable script errors.
  try:
    toValue(expression)
  except AssertionDefect as error:
    raise newException(BasicError, error.msg)

proc `+`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Adds integers with wrapping or promotes mixed operands to Fixed.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    toValue(left.integer +% right.integer)
  else:
    fixedResult(left.asFixed + right.asFixed)

proc `-`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Subtracts integers with wrapping or promotes operands to Fixed.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    toValue(left.integer -% right.integer)
  else:
    fixedResult(left.asFixed - right.asFixed)

proc `*`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Multiplies integers with wrapping or promotes operands to Fixed.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    toValue(left.integer *% right.integer)
  else:
    fixedResult(left.asFixed * right.asFixed)

proc `-`*(value: Value): Value {.inline, raises: [BasicError].} =
  ## Negates a fixed-point value or integer with defined wrapping.
  case value.kind
  of IntegerValue:
    toValue(0'i32 -% value.integer)
  of FixedValue:
    toValue(-value.decimal)
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc `/`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Divides as Q16.16 with Fixxy rounding and rejects zero divisors.
  let divisor = right.asFixed
  if divisor == FixedZero:
    raise newException(BasicError, "division by zero")
  fixedResult(left.asFixed / divisor)

proc `div`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Divides exact int32 operands toward zero with defined overflow.
  let
    a = left.asInt
    b = right.asInt
  if b == 0:
    raise newException(BasicError, "division by zero")
  if a == low(int32) and b == -1:
    return toValue(low(int32))
  toValue(a div b)

proc `mod`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Computes the remainder of exact int32 operands with defined overflow.
  let
    a = left.asInt
    b = right.asInt
  if b == 0:
    raise newException(BasicError, "division by zero")
  if a == low(int32) and b == -1:
    return toValue(0'i32)
  toValue(a mod b)

proc bitInteger(value: Value): int32 {.inline, raises: [BasicError].} =
  ## Converts a logical operand to int32, rounding ties to the even integer.
  case value.kind
  of IntegerValue:
    result = value.integer
  of FixedValue:
    let fraction = value.decimal.fraction
    result = value.decimal.whole
    if fraction > 32768'u16 or
      (fraction == 32768'u16 and (result and 1) != 0):
        inc result
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc `not`*(value: Value): Value {.inline, raises: [BasicError].} =
  ## Complements every bit of a rounded int32 operand.
  toValue(not value.bitInteger)

proc `and`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Intersects the bits of two rounded int32 operands.
  toValue(left.bitInteger and right.bitInteger)

proc `or`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Unites the bits of two rounded int32 operands.
  toValue(left.bitInteger or right.bitInteger)

proc `xor`*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Returns the bits present in exactly one rounded int32 operand.
  toValue(left.bitInteger xor right.bitInteger)

proc eqv*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Returns the matching bits of two rounded int32 operands.
  toValue(not (left.bitInteger xor right.bitInteger))

proc imp*(left, right: Value): Value {.inline, raises: [BasicError].} =
  ## Computes bitwise implication between two rounded int32 operands.
  toValue((not left.bitInteger) or right.bitInteger)

proc scaled(value: Value): int64 {.inline, raises: [BasicError].} =
  ## Widens either numeric representation without losing integer range.
  case value.kind
  of IntegerValue:
    int64(value.integer) * FixedScale
  of FixedValue:
    int64(int32(value.decimal))
  of StringValue, ArrayValue, BlobValue:
    raise newException(BasicError, "BASIC value must be numeric")

proc `==`*(left, right: Value): bool {.inline, raises: [BasicError].} =
  ## Compares numbers exactly across the full int32 and Q16.16 ranges.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    left.integer == right.integer
  else:
    left.scaled == right.scaled

proc `<`*(left, right: Value): bool {.inline, raises: [BasicError].} =
  ## Orders numbers exactly across the full int32 and Q16.16 ranges.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    left.integer < right.integer
  else:
    left.scaled < right.scaled

proc `<=`*(left, right: Value): bool {.inline, raises: [BasicError].} =
  ## Compares numeric values inclusively without changing their types.
  if left.kind == IntegerValue and right.kind == IntegerValue:
    left.integer <= right.integer
  else:
    left.scaled <= right.scaled
