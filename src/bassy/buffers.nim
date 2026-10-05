import
  std/atomics,
  numbers

const BufferBytes = 96'i64

type
  Buffer = object
    owner: uint32
    kind: ValueKind
    marked: bool
    values: seq[Value]
    bytes, binding: string
  BlobView* = object
    data*: ptr UncheckedArray[byte]
    len*: int
  BufferStorage* = object
    slots: seq[Buffer]
    used: int64
    external*, maximum*: int64
    maxCount*, maxElements*: int

var nextOwner: Atomic[uint32]

proc fail(message: string) {.noreturn.} =
  ## Raises a controlled native storage error.
  raise newException(BasicError, "BASIC " & message)

proc freshOwner(): uint32 =
  ## Assigns an identity that cannot alias a recycled or foreign buffer.
  var previous = nextOwner.load
  while true:
    if previous == high(uint32):
      fail("buffer identity limit exceeded")
    if nextOwner.compareExchange(previous, previous + 1):
      return previous + 1

proc size(buffer: Buffer): int64 =
  ## Counts the payload and its owned bookkeeping.
  int64(buffer.values.len) * int64(sizeof(Value)) +
    int64(buffer.bytes.len) + int64(buffer.binding.len)

proc reserve*(storage: BufferStorage, bytes: int64) =
  ## Checks capacity before allocating or changing any owned buffer.
  if bytes < 0 or bytes > storage.maximum - storage.used -
    int64(storage.slots.len) * BufferBytes - storage.external:
    fail("native memory limit exceeded")

proc memoryBytes*(storage: BufferStorage): int64 =
  ## Returns native buffer and trusted host memory usage.
  storage.used + int64(storage.slots.len) * BufferBytes + storage.external

proc index*(storage: BufferStorage, value: Value): int =
  ## Rejects wrong types, stale generations, and another VM's references.
  result = int(value.bufferSlot)
  if result < 0 or result >= storage.slots.len or
    storage.slots[result].owner != value.bufferOwner or
    storage.slots[result].kind != value.kind or value.bufferOwner == 0:
      fail("invalid or stale buffer handle")

proc validate*(storage: BufferStorage, value: Value) =
  ## Validates a buffer at a public VM boundary.
  discard storage.index(value)

proc add(storage: var BufferStorage, buffer: sink Buffer): Value =
  ## Installs a validated payload in a free slot after reserving capacity.
  let bytes = buffer.size
  storage.reserve(bytes)
  var index = -1
  for i, slot in storage.slots:
    if slot.owner == 0:
      index = i
      break
  if index < 0:
    if storage.slots.len >= storage.maxCount:
      fail("native buffer count limit exceeded")
    storage.reserve(bytes + BufferBytes)
    index = storage.slots.len
    storage.slots.add Buffer()
  buffer.owner = freshOwner()
  result = bufferValue(buffer.kind, buffer.owner, int32(index))
  storage.slots[index] = move(buffer)
  storage.used += bytes

proc putArray*(storage: var BufferStorage, values: openArray[Value]): Value =
  ## Copies a numeric result into bounded runtime-owned storage.
  if values.len > storage.maxElements:
    fail("native array element limit exceeded")
  storage.reserve(BufferBytes + int64(values.len) * int64(sizeof(Value)))
  for value in values:
    if value.kind notin {IntegerValue, FixedValue}:
      fail("native arrays require numeric elements")
  storage.add Buffer(kind: ArrayValue, values: @values)

proc createBlob*(storage: var BufferStorage): Value =
  ## Creates an empty mutable binary buffer.
  storage.add Buffer(kind: BlobValue)

proc length*(storage: BufferStorage, value: Value): int =
  ## Returns the size of a validated numeric array.
  if value.kind != ArrayValue:
    fail("value must be an array")
  storage.slots[storage.index(value)].values.len

proc get*(storage: BufferStorage, value: Value, index: int): Value =
  ## Reads a returned array with release-build bounds checks.
  let slot = storage.index(value)
  if value.kind != ArrayValue:
    fail("value must be an array")
  if index < 0 or index >= storage.slots[slot].values.len:
    fail("native array index is outside the array")
  storage.slots[slot].values[index]

proc put*(storage: var BufferStorage, value: Value, index: int, item: Value) =
  ## Writes a numeric returned-array element after validation.
  discard storage.get(value, index)
  if item.kind notin {IntegerValue, FixedValue}:
    fail("native arrays require numeric elements")
  storage.slots[storage.index(value)].values[index] = item

proc blob*(storage: BufferStorage, value: Value): string =
  ## Copies opaque state for a trusted host without exposing VM internals.
  if value.kind != BlobValue:
    fail("value must be a blob")
  storage.slots[storage.index(value)].bytes

proc borrowBlob*(storage: BufferStorage, value: Value): BlobView =
  ## Borrows opaque bytes without copying their payload for trusted hosts.
  if value.kind != BlobValue:
    fail("value must be a blob")
  let slot = storage.index(value)
  result.len = storage.slots[slot].bytes.len
  if result.len > 0:
    result.data = cast[ptr UncheckedArray[byte]](
      unsafeAddr storage.slots[slot].bytes[0]
    )

proc binding*(storage: BufferStorage, value: Value): string =
  ## Reads the trusted host's architecture and model identity.
  if value.kind != BlobValue:
    fail("value must be a blob")
  storage.slots[storage.index(value)].binding

proc putBlob*(storage: var BufferStorage, value: Value,
    bytes, binding: string) =
  ## Commits a complete replacement after checking its final storage size.
  if value.kind != BlobValue:
    fail("value must be a blob")
  let
    slot = storage.index(value)
    previous = storage.slots[slot].size
    next = int64(bytes.len) + int64(binding.len)
  storage.reserve(max(0'i64, next - previous))
  storage.slots[slot].bytes = bytes
  storage.slots[slot].binding = binding
  storage.used += next - previous

proc mark*(storage: var BufferStorage, values: openArray[Value]) =
  ## Marks roots without following opaque bytes or numeric array elements.
  for value in values:
    if value.kind in {ArrayValue, BlobValue}:
      let i = storage.index(value)
      storage.slots[i].marked = true

proc sweep*(storage: var BufferStorage) =
  ## Reclaims unreferenced buffers while preserving stable slots and aliases.
  for slot in storage.slots.mitems:
    if slot.owner != 0 and not slot.marked:
      storage.used -= slot.size
      slot = Buffer()
    slot.marked = false

proc reset*(storage: var BufferStorage) =
  ## Invalidates every VM buffer while retaining trusted host reservations.
  storage.slots.setLen(0)
  storage.used = 0
