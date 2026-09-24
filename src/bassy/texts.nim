import
  std/[atomics, strutils],
  numbers

type
  TextFunction* = enum
    NoTextFunction,
    LengthFunction,
    LeftFunction,
    RightFunction,
    MidFunction,
    UpperFunction,
    LowerFunction,
    TrimFunction,
    LeftTrimFunction,
    RightTrimFunction,
    CharacterFunction,
    CodeFunction,
    SpaceFunction,
    RepeatFunction,
    FindFunction,
    FormatFunction

  TextSpan = object
    start: int32
    length: int32

  TextStorage* = object
    owner: uint32
    maxCount: int
    maxBytes: int
    maxLength: int
    arena: string
    scratch: string
    spans: seq[TextSpan]
    scratchSpans: seq[TextSpan]
    remap: seq[int32]
    positions: seq[int32]

var nextOwner: Atomic[uint32]

proc fail(message: string) {.noreturn, raises: [BasicError].} =
  ## Reports a controlled string storage failure.
  raise newException(BasicError, "BASIC " & message)

proc freshOwner(): uint32 =
  ## Assigns a non-repeating owner to each storage generation.
  var previous = nextOwner.load
  while true:
    if previous == high(uint32):
      fail("string storage identity limit exceeded")
    if nextOwner.compareExchange(previous, previous + 1):
      return previous + 1

proc textFunction*(name: string): TextFunction {.raises: [].} =
  ## Resolves one built-in string function by its normalized name.
  case name
  of "len": LengthFunction
  of "left$": LeftFunction
  of "right$": RightFunction
  of "mid$": MidFunction
  of "ucase$": UpperFunction
  of "lcase$": LowerFunction
  of "trim$": TrimFunction
  of "ltrim$": LeftTrimFunction
  of "rtrim$": RightTrimFunction
  of "chr$": CharacterFunction
  of "asc": CodeFunction
  of "space$": SpaceFunction
  of "string$": RepeatFunction
  of "instr": FindFunction
  of "str$": FormatFunction
  else: NoTextFunction

proc storageBytes*(count, bytes: int): int64 {.raises: [].} =
  ## Counts both arenas, span buffers, and the reset remapping table.
  int64(bytes) * 6 + int64(count) * 20

proc initTextStorage*(count, bytes, length: int): TextStorage =
  ## Preallocates all storage used by strings and reset compaction.
  result = TextStorage(
    owner: freshOwner(),
    maxCount: count,
    maxBytes: bytes,
    maxLength: length,
    arena: newStringOfCap(bytes),
    scratch: newStringOfCap(bytes),
    spans: newSeqOfCap[TextSpan](count),
    scratchSpans: newSeqOfCap[TextSpan](count),
    remap: newSeq[int32](count),
    positions: newSeq[int32](bytes)
  )
  result.spans.add TextSpan()

proc empty*(storage: TextStorage): Value {.raises: [].} =
  ## Returns the shared empty string in this generation.
  stringValue(storage.owner, 0)

proc span(storage: TextStorage, value: Value): TextSpan =
  ## Rejects non-string, foreign, stale, and out-of-range references.
  let handle = value.stringHandle
  if storage.owner == 0 or value.stringOwner != storage.owner or
    handle < 0 or int(handle) >= storage.spans.len:
      fail("invalid or stale string value")
  storage.spans[int(handle)]

proc length*(storage: TextStorage, value: Value): int =
  ## Returns a string's byte length after validating ownership.
  int(storage.span(value).length)

proc get*(storage: TextStorage, value: Value): string =
  ## Copies a stored string for trusted host access or output.
  let view = storage.span(value)
  if view.length > 0:
    result = storage.arena[int(view.start) ..< int(view.start + view.length)]

template withText*(
  storage: var TextStorage, value: Value, text, body: untyped
) =
  ## Borrows validated bytes until the storage is next modified.
  block:
    let
      source = addr storage
      view = source[].span(value)
    template text: untyped =
      source[].arena.toOpenArray(
        int(view.start), int(view.start + view.length) - 1
      )
    body

proc count*(storage: TextStorage): int {.raises: [].} =
  ## Returns the number of occupied string slots including the empty string.
  storage.spans.len

proc bytesUsed*(storage: TextStorage): int {.raises: [].} =
  ## Returns the number of occupied arena bytes.
  storage.arena.len

proc reserve(storage: TextStorage, length: int, bytes: int) =
  ## Checks every string limit before allocating a slot or writing bytes.
  if storage.owner == 0:
    fail("program has no string storage")
  if length < 0 or length > storage.maxLength:
    fail("string length limit exceeded")
  if storage.spans.len >= storage.maxCount:
    fail("string count limit exceeded")
  if bytes > storage.maxBytes - storage.arena.len:
    fail("string byte limit exceeded")

proc put*(storage: var TextStorage, text: string): Value =
  ## Copies host text without truncating or exceeding configured limits.
  if text.len == 0:
    if storage.owner == 0:
      fail("program has no string storage")
    return storage.empty
  storage.reserve(text.len, text.len)
  result = stringValue(storage.owner, int32(storage.spans.len))
  storage.spans.add TextSpan(
    start: int32(storage.arena.len),
    length: int32(text.len)
  )
  storage.arena.add text

proc concat*(storage: var TextStorage, left, right: Value): Value =
  ## Concatenates two owned strings after reserving their complete result.
  let
    a = storage.span(left)
    b = storage.span(right)
    total = int64(a.length) + int64(b.length)
  if total > int64(storage.maxLength):
    fail("string length limit exceeded")
  let length = int(total)
  if a.length == 0:
    return right
  if b.length == 0:
    return left
  storage.reserve(length, length)
  result = stringValue(storage.owner, int32(storage.spans.len))
  storage.spans.add TextSpan(
    start: int32(storage.arena.len),
    length: int32(length)
  )
  for view in [a, b]:
    for i in int(view.start) ..< int(view.start + view.length):
      storage.arena.add storage.arena[i]

proc compare*(storage: TextStorage, left, right: Value): int =
  ## Compares byte contents case-sensitively without allocating strings.
  let
    a = storage.span(left)
    b = storage.span(right)
  for i in 0 ..< min(int(a.length), int(b.length)):
    result = cmp(
      storage.arena[int(a.start) + i],
      storage.arena[int(b.start) + i]
    )
    if result != 0:
      return
  result = cmp(a.length, b.length)

proc slice*(storage: var TextStorage, value: Value, start, length: int): Value =
  ## Returns a clamped zero-based view without copying arena bytes.
  let
    view = storage.span(value)
    first = min(max(start, 0), int(view.length))
    size = min(max(length, 0), int(view.length) - first)
  if size == 0:
    return storage.empty
  if first == 0 and size == int(view.length):
    return value
  storage.reserve(size, 0)
  result = stringValue(storage.owner, int32(storage.spans.len))
  storage.spans.add TextSpan(
    start: view.start + int32(first),
    length: int32(size)
  )

proc repeated*(storage: var TextStorage, count: int, character: char): Value =
  ## Builds a repeated byte after checking its total length and capacity.
  if count < 0:
    fail("string repeat count must be non-negative")
  if count == 0:
    return storage.empty
  storage.reserve(count, count)
  result = stringValue(storage.owner, int32(storage.spans.len))
  storage.spans.add TextSpan(
    start: int32(storage.arena.len),
    length: int32(count)
  )
  for i in 0 ..< count:
    storage.arena.add character

proc character*(storage: TextStorage, value: Value): char =
  ## Reads the first byte, rejecting empty strings.
  let view = storage.span(value)
  if view.length == 0:
    fail("ASC requires a non-empty string")
  storage.arena[int(view.start)]

proc mapped*(storage: var TextStorage, value: Value, upper: bool): Value =
  ## Maps ASCII letter case into a bounded result.
  let view = storage.span(value)
  if view.length == 0:
    return value
  storage.reserve(int(view.length), int(view.length))
  result = stringValue(storage.owner, int32(storage.spans.len))
  storage.spans.add TextSpan(
    start: int32(storage.arena.len),
    length: view.length
  )
  for i in int(view.start) ..< int(view.start + view.length):
    storage.arena.add(
      if upper:
        storage.arena[i].toUpperAscii
      else:
        storage.arena[i].toLowerAscii
    )

proc trimmed*(
    storage: var TextStorage,
    value: Value,
    left, right: bool
): Value =
  ## Trims ASCII spaces from either edge using an arena view.
  let view = storage.span(value)
  var
    first = 0
    last = int(view.length)
  if left:
    while first < last and storage.arena[int(view.start) + first] == ' ':
      inc first
  if right:
    while last > first and storage.arena[int(view.start) + last - 1] == ' ':
      dec last
  storage.slice(value, first, last - first)

proc find*(storage: TextStorage, haystack, needle: Value, start: int): int =
  ## Finds a byte substring and returns its BASIC one-based position.
  let
    a = storage.span(haystack)
    b = storage.span(needle)
  if start < 1:
    fail("INSTR start must be positive")
  if start > int(a.length):
    return 0
  if b.length == 0:
    return start
  for i in start - 1 .. int(a.length) - int(b.length):
    var matches = true
    for j in 0 ..< int(b.length):
      if storage.arena[int(a.start) + i + j] != storage.arena[int(b.start) + j]:
        matches = false
        break
    if matches:
      return i + 1

proc reset*(storage: var TextStorage, roots: var seq[Value]) =
  ## Reclaims strings while preserving and remapping bound host data.
  if storage.owner == 0:
    return
  let owner = freshOwner()
  storage.scratch.setLen(0)
  storage.scratchSpans.setLen(0)
  storage.scratchSpans.add TextSpan()
  for entry in storage.remap.mitems:
    entry = -1
  storage.remap[0] = 0
  for i in 0 ..< storage.arena.len:
    storage.positions[i] = -1
  for value in roots:
    if value.kind == StringValue:
      let view = storage.span(value)
      for i in int(view.start) ..< int(view.start + view.length):
        storage.positions[i] = 0
  for i in 0 ..< storage.arena.len:
    if storage.positions[i] == 0:
      storage.positions[i] = int32(storage.scratch.len)
      storage.scratch.add storage.arena[i]
  for value in roots.mitems:
    if value.kind != StringValue:
      continue
    let
      view = storage.span(value)
      old = int(value.stringHandle)
    var handle = storage.remap[old]
    if handle < 0:
      handle = int32(storage.scratchSpans.len)
      storage.remap[old] = handle
      storage.scratchSpans.add TextSpan(
        start: storage.positions[int(view.start)], length: view.length
      )
    value = stringValue(owner, handle)
  swap(storage.arena, storage.scratch)
  swap(storage.spans, storage.scratchSpans)
  storage.owner = owner
