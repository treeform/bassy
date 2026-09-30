# BASIC language reference

This is a small structured BASIC dialect for embedded scripts.

## Values and expressions

Identifiers and keywords are case-insensitive. Identifiers start with a
letter or underscore, followed by letters, digits, or underscores, with an
optional trailing `$` for strings. Scalar variables are implicitly declared.
Numeric variables begin as integer zero and hold an `int32` or Fixxy's
Q16.16 `Fixed`. Fixed-point values are enabled by default. String variables
begin as `""`. Arrays and parameters use the same suffix rule. `name` and
`name$` are distinct variables.

Integer literals retain their int32 range. Decimal points or exponents make
fixed-point literals, such as `1.5`, `.25`, `2.`, `1e-3`, or `2.5D+2`.
Both `E` and `D` select fixed-point numbers. A literal is limited to 128 bytes
and an exponent magnitude of 512. Exponents are expanded using integer
arithmetic and parsed by Fixxy. Out-of-range literals raise `BasicError`.
Very small values round to zero.

`Fixed` ranges from -32768 to just under 32768, with a step size of about
0.00001526 (exactly 1/65536). Text output rounds values to five decimal places.
Arithmetic and decimal parsing use the same rules as
[Fixxy](https://github.com/treeform/fixxy). Multiplication and division round
to nearest with ties toward positive infinity. Decimal input uses Fixxy's
parser, which retains up to nine fractional decimal digits before rounding
its magnitude to the nearest step. Decimal values have no NaN, infinity,
or distinct negative zero.

Integer addition, subtraction, multiplication, and negation wrap in two's
complement. If either operand is fixed-point, arithmetic converts the integer
operand to `Fixed`. That conversion requires an integer from -32768 to
32767 and raises `BasicError` outside this range. Comparisons instead widen
to int64 and remain exact over both representations' full ranges.

`/` performs fixed-point division, including `3 / 2 = 1.5`, and requires both
operands to fit `Fixed`. Use `\` for integer division toward zero over the
full int32 range. `mod` computes an integer remainder. Both integer operators
require exact int32 operands, accepting `3.0` and rejecting `3.5`. Division
by zero raises `BasicError`, including a divisor that rounded to zero.
Integer division of the minimum int32 by -1 returns the minimum int32, and
the corresponding remainder is zero.

Fixed-point results wrap according to Fixxy, so `32767.0 + 1.0` becomes
`-32768.0`. Builds with `-d:fixedChecks` report checked intermediate overflow
as `BasicError`. Negating the minimum fixed-point value still returns itself.
The same program, build options, host inputs, and deterministic callbacks
produce the same numeric results across supported native platforms. The
compiler, constant folding, interpreter, and numeric formatting do not use
floating-point operations.

### Integer-only execution

Set `limits.disableFixed = true` before compiling integer-only scripts:

```nim
var limits = defaultLimits()
limits.disableFixed = true
let program = compile("answer = 3 / 2", limits)
var runtime = initRuntime(program, limits)
discard runtime.run
doAssert runtime.getGlobal("answer") == 1
```

In this mode, decimal literals are rejected and `/` uses integer division.
Globals, arrays, host data, and callback results cannot receive fixed-point
values, including whole-valued numbers such as `1.0`.

The restriction is stored in the compiled program and persists through
`initRuntime`, `restart`, and `reset`. Creating a runtime with default limits
does not enable fixed-point values for an integer-only program. Recompile
with `disableFixed` before requesting integer-only runtime limits, because
constant folding already used the selected division semantics.

### Numeric values in Nim

`getGlobal`, `getArray`, and `getData` return exact int32 values and raise
`BasicError` for fractional values. Use `getGlobalValue`, `getArrayValue`,
and `getDataValue` to read either numeric kind, then inspect `.kind`,
`.asFixed`, or `.asInt`. `.asFixed` checks integer promotion against the
Q16.16 range. `.asInt` requires an exact integer.

Setters and `addData` accept integers or `Fixed` through `toValue` converters.
`bassy` exports Fixxy, so host code can use `0.25'fx`, `fixed(3)`, and
`parseFixed("1.5")`. There is no implicit conversion from native floats to
BASIC values. Any deliberate float conversion belongs in the host's input
or output boundary, outside deterministic simulation code.

`NumericHostProc` accepts `openArray[Value]` and returns `Value`. Register it
with `addFunction`, just like an existing `HostProc`. Integer callbacks
remain available. All their arguments must convert exactly to int32 before
the callback runs, which also protects string handles from silent truncation.
A replacement host must match the compiled callback kind, argument count,
and work cost.

Numeric cells occupy 16 logical bytes in both modes. Host callback slots
occupy 32 bytes, and each argument scratch slot also reserves 4 bytes for
integer callback conversion. These preallocated buffers count toward
`maxMemoryBytes`. Arithmetic does not grow runtime storage. Compiled fixed
constants belong to the shared program, outside the runtime memory budget.
Instruction, work, call-depth, and output limits apply in both modes.
See [the numeric host example](../examples/fixed.nim).

Migration from the former floating-point API:

| Previous API | Fixed-point API |
| --- | --- |
| `FloatValue` | `FixedValue` |
| `.asFloat` | `.asFixed` |
| Native float inputs such as `0.25` | Fixxy inputs such as `0.25'fx` |
| `FloatPrint` and `event.floatValue` | `FixedPrint` and `event.fixedValue` |
| `limits.disableFloats` | `limits.disableFixed` |

### Booleans and bitwise operators

Comparisons use `=`, `<>`, `<`, `<=`, `>`, and `>=`. They return integer -1
for true and 0 for false. The `true` and `false` constants use the same
representation. Conditions in `if`, `while`, and `until` consider every
nonzero value true, including fractional values such as `0.5`.

Logical operators work on all 32 bits of their integer operands:

| Operator | Operation | Example | Result |
| --- | --- | --- | --- |
| `not` | Complement every bit. | `not 1` | -2 |
| `and` | Keep bits present in both operands. | `6 and 3` | 2 |
| `or` | Keep bits present in either operand. | `6 or 3` | 7 |
| `xor` | Keep bits present in exactly one operand. | `6 xor 3` | 5 |
| `eqv` | Complement XOR. | `6 eqv 3` | -6 |
| `imp` | Complement the left operand, then OR. | `6 imp 3` | -5 |

With operands of -1 and 0, these operations also produce Boolean results.
Use `flags and mask` to test a bit mask. For other nonzero values, `not`
complements the bits instead of testing whether the value is zero. For
example, `not 1` is -2, which is still true in a condition. Use `value = 0`
to test falseness and `value <> 0` to normalize a value to -1 or 0.

Arithmetic binds more tightly than comparisons. Comparisons bind more
tightly than `not`, followed by `and`, `or`, `xor`, `eqv`, and `imp`, in that
order. Thus `not x = 1` means `not (x = 1)`, and `1 xor 1 or 1` is 0.
Parentheses override precedence. Binary logical operators evaluate both
operands, including host function calls. Use nested `if` statements when
evaluating the right operand would be unsafe or perform an unwanted action.

Fixed-point operands of logical operators are rounded to the nearest integer,
with exact halves rounded to the even integer. For example, `1.5 and -1`
is 2, `2.5 and -1` is 2, and `0.5 and -1` is 0. Operands outside the int32
range raise `BasicError`. Rounding applies only to logical operators.
Array indices, string handles, integer division, and integer host callbacks
continue to require exact int32 values. When fixed-point values are disabled, logical
operations use only integers.

In Nim, `toValue(true)` produces integer -1 and `toValue(false)` produces
zero. Setters and `NumericHostProc` results accept Nim Booleans through this
converter. Use `value.asBool` to test a numeric value as a condition without
rounding. Integer host callbacks that represent Boolean predicates should
return -1 or 0. The built-in `strEq` follows this convention. Ordinary numeric
callback results are preserved, including 1.

This changes earlier versions that returned 1 for true and treated logical
operators as truth tests. Update scripts that explicitly compare a Boolean
to 1, and use `value = 0` when you need a truth test instead of bitwise NOT.
`eqv` and `imp` are now reserved keywords.

The logical rules follow the [QuickBASIC language reference][logical-reference]
and its [documented rounding convention][rounding-reference]. The VM uses
32-bit integers for all bit operations.

[logical-reference]: https://www.pcjs.org/documents/books/mspl13/basic/qblang/
[rounding-reference]: https://jeffpar.github.io/kbarchive/kb/023/Q23389/

## Statements

Separate statements with newlines or `:`. Comments start with an apostrophe
or `rem` and continue to the end of the line. `let` is optional in assignments.

```basic
rem Fill five elements, indexed from 0 through 4.
dim scores(4)
i = 0
while i <= 4
  scores(i) = i * 10
  i = i + 1
wend

if scores(4) >= 40 then
  print "passed", scores(4)
else
  print "failed"
end if
```

`dim name(n)` declares a global one-dimensional array with an inclusive
integer upper bound. Indices run from 0 through n and require exact int32
values. Fractional indices are rejected. Array bounds are checked
explicitly, including in release builds. Arrays and scalars occupy the shared
global namespace.

`end` and `stop` finish the whole program.

## Records

`type ... end type` defines a record layout. Declare a scalar record with
`dim name as TypeName` or an array of records with `dim name(n) as TypeName`.
Read and write fields with a dot:

```basic
type Position
  x as fixed
  y as fixed
end type

type PlayerState
  hp as integer
  position as Position
  name as string
end type

dim player as PlayerState
dim players(9) as PlayerState

player.hp = 100
player.position.x = 12.5
player.name = "Ada"
players(3).hp = player.hp - 10
players(3).position.x = player.position.x
print player.name, players(3).hp
```

Field types select storage and assignment rules:

| Type | Behavior |
| --- | --- |
| `integer`, `long`, `int32` | Signed int32. Assignments accept exact integers, including `3.0`, and reject fractions and out-of-range values. |
| `fixed`, `fixed32` | Q16.16 fixed point. Integer assignments convert within the fixed-point range. |
| `single`, `double` | Compatibility aliases for `fixed`, using Q16.16 rather than floating point. |
| `number` | The same flexible int32 or fixed-point values as ordinary numeric variables. |
| `string` | Variable-length text in the existing bounded string pool. The field name does not need `$`. |
| Previously defined record type | An embedded record, accessed as `player.position.x`. |

Record type names, variable names, and field names are case-insensitive.
Definitions and declarations must be at top level. Define types before using
them in another type or a `dim` declaration. Scalar record fields are global,
so subroutines can access them directly. Array indices use the existing
zero-based, inclusive bounds and exact integer checks. An index expression
is evaluated once per field access, before the assigned value expression.

Fields begin as zero or empty text. Fixed fields begin as fixed-point zero.
`restart` preserves their values and `reset` restores their defaults.
Integer-only programs reject fixed fields, including `single` and `double`.
`number` fields follow the program's integer-only policy.

Nested layouts are flattened into scalar slots or one array per leaf field.
Scalar leaves count against `maxGlobals`. Array leaves count against
`maxArrays`, and all their cells count against `maxArrayElements` and the
runtime memory budget. Type count and leaf count per type are bounded by
`maxGlobals`, and record nesting is bounded by `maxSyntaxDepth`.
Expanded field path bytes across layouts and declarations are bounded by
`maxSourceBytes`, so nested types cannot expand compile-time names without
a limit.

The existing Nim API accepts dotted field paths:

```nim
runtime.setGlobal("player.hp", 100)
runtime.setGlobal("player.name", "Ada")
runtime.setArray("players.hp", 3, 90)
echo runtime.getGlobal("player.hp")
echo runtime.getStringGlobal("player.name")
echo runtime.getArray("players.hp", 3)
```

Host setters enforce the same field types. Whole-record assignment,
record-valued parameters, arrays inside a type, and fixed-length string
fields are not supported. Pass individual fields to subroutines instead.

## Conditions

Block `if ... then` ends with `end if`. It accepts any number of `elseif`
branches and an optional final `else`. Conditions are checked in order until
one succeeds, and only that branch runs.

```basic
if health <= 0 then
  action = 0
elseif health < 20 then
  action = 1
else
  action = 2
end if

if action = 1 then retreat = 1: speed = 2 else speed = 1
```

A single-line `if` extends through the physical end of its line, including
colon-separated statements. It has no `end if`. Nested single-line `if`
statements associate `else` with the nearest unmatched `if`. Block statements
such as `for`, `do`, and `select case` belong outside single-line branches.
A trailing `rem` or apostrophe comment after a block header is allowed.

`select case` evaluates its selector once and runs the first matching case.
Cases accept individual values, comma-separated alternatives, inclusive
ranges with `to`, and comparisons with `is`. `case else` is optional and must
be last. Case expressions are checked in order and stop after a match.

```basic
select case health
case 0
  action = 0
case 1 to 20, 25
  action = 1
case is >= 80
  action = 2
case else
  action = 3
end select
```

## Loops

`while ... wend` tests its condition before each iteration.

`for counter = start to finish step increment` evaluates the start, finish,
and increment once on entry. The increment defaults to 1. Positive increments
continue while the counter is at most the finish value, and negative
increments continue while it is at least the finish value. A range facing the
wrong direction is skipped.

```basic
for player = 0 to 3
  scores(player) = scores(player) + 1
next player

for player = 3 to 0 step -1
  if scores(player) > 10 then exit for
next
```

`next` optionally names its counter. `next inner, outer` closes nested loops
in that order. Nested `for` loops must use different counter names. Counters
may be globals or `sub` parameters. `exit for` leaves the nearest enclosing
`for`, even when another kind of loop is nested inside it.

Counters use the VM's numeric arithmetic and accept fractional steps. A zero
step, integer wraparound, or a fixed-point step rounded to zero can
keep a loop running until an execution budget stops it. Choose bounds and
increments that let the counter reach the end of the range.

`do ... loop` can test a `while` or `until` condition at either the beginning
or the end, or omit the condition. A condition at the end allows the body to
run at least once. Using both an entry and an exit condition is an error.

```basic
do until target = 0
  target = target - 1
loop

do
  attempts = attempts + 1
  if attempts = 3 then exit do
loop while attempts < 10
```

`exit do` leaves the nearest enclosing `do`. Every loop remains subject to
the runtime budgets, including an empty unconditional `do ... loop`.

## Labels and jumps

Named labels end in `:` and are case-insensitive. Decimal line numbers at the
start of a physical line also define labels. Line numbers are non-negative
int32 values and do not change source execution order. Multiple labels may
refer to the same statement.

```basic
10 attempts = 0
again:
attempts = attempts + 1
if attempts < 3 then goto again
goto finished
finished:
end
```

`goto` accepts a label name or line number. Forward and backward jumps work.
Single-line `if` also accepts shorthand targets, such as
`if ready then 100 else waitHere`.

`gosub` saves a return address before jumping. `return` resumes after that
call, and `return target` consumes the saved return address and jumps to the
specified label instead.

```basic
gosub award
goto finished
award:
score = score + 10
return
finished:
end
```

Labels are local to the main program or their containing `sub`. Jumps and
`gosub` cannot cross those boundaries. Undefined and duplicate labels are
compile errors. Returning without a matching call raises `BasicError`.

`on expression goto first, second` and `on expression gosub first, second`
evaluate the expression once and select a target by its one-based index.
Values outside the target list, including zero and negative values, fall
through to the next statement.

All jump targets enter metered bytecode blocks. `gosub` and ordinary `sub`
calls share the configured call-depth and register-memory limits. `gosub`
preserves the caller's loop and selector registers while sharing globals and
propagating changes to `sub` parameters on return.

A jump into a block bypasses that block's initialization. Enter `for` and
`select case` through their headers to initialize their captured values.
These values occupy dedicated registers, included in the runtime memory
limit and the compiler's register limit.

## Subroutines

```basic
sub addScore(amount)
  if amount <= 0 then
    exit sub
  end if
  score = score + amount
end sub

addScore(7)
call addScore(3)
```

Parameters are local values passed by value. Use a `$` suffix for string
parameters, such as `sub greet(name$)`. Argument types must match. Other scalar variables
are global. Subroutines can call each other and recurse within the configured
call depth. `exit sub` and `end sub` exit the entire procedure, including any
pending `gosub` calls inside it. For compatibility with earlier versions of
this library, a bare `return` also exits a `sub` when there is no pending
`gosub` in that call. Native host functions can return numbers or strings and appear
in expressions. String-returning host functions require a `$` suffix.

## Output and literals

`print` emits text, integer, fixed-point, and newline events to the host's
callback. A `FixedPrint` event provides `fixedValue` and its formatted `text`.
Write that text to preserve the VM's output accounting. Integer output uses
`ValuePrint` and `event.value`. Fixxy formats decimals with five fractional
digits using integer arithmetic, so `print 1.25` writes `1.25000`. `str$`
uses the same numeric format and its existing leading-space convention.

Quoted literals are string expressions and can appear in assignments,
comparisons, calls, and output. String output uses `TextPrint`. A literal
printed on its own can be emitted directly from the compiled program.

For compatibility, a standalone quoted argument to an integer `HostProc`
still becomes a compiled literal ID, resolved with `program.literal(id)`.
This preserves existing calls such as `strNew("text")`. Calls to SUBs,
built-in string functions, and `NumericHostProc` receive actual string
values. Literal IDs, legacy pool handles, and native strings are distinct.

## Native strings

String syntax works without registering any host functions:

```basic
name$ = "Ada"
greeting$ = "Hello, " + name$ + "!"
dim names$(3)
names$(0) = name$
if names$(0) = "Ada" then print greeting$
```

`+` concatenates strings. `=`, `<>`, `<`, `<=`, `>`, and `>=` compare their
contents case-sensitively and return -1 or 0. String selectors also work in
`select case`, including ranges and `case is` comparisons. Assignment and
SUB arguments copy a string reference by value. Strings are immutable.
Numeric and string operands cannot be mixed, and strings cannot be used as
Boolean conditions. Use `LEN(text$) > 0` to test for nonempty text.

| Built-in function | Result |
| --- | --- |
| `LEN(s$)` | Byte length. |
| `LEFT$(s$, n)` / `RIGHT$(s$, n)` | Up to `n` bytes from either edge. |
| `MID$(s$, start[, n])` | Up to `n` bytes, or the remaining suffix. |
| `INSTR([start,] s$, needle$)` | One-based match position, or 0. |
| `UCASE$(s$)` / `LCASE$(s$)` | ASCII letter case conversion. |
| `TRIM$(s$)` / `LTRIM$(s$)` / `RTRIM$(s$)` | Remove ASCII spaces at either edge. |
| `CHR$(n)` | One byte with a code from 0 through 255. |
| `ASC(s$)` | First byte's code. Empty input is an error. |
| `SPACE$(n)` | `n` spaces. |
| `STRING$(n, code)` / `STRING$(n, s$)` | Repeat a byte code or the first byte of nonempty text. |
| `STR$(n)` | Numeric text, with a leading space for nonnegative values. |

Positions are one-based and must be positive. Lengths must be nonnegative.
Substring lengths clamp to the available bytes, and a start past the end
produces an empty substring or an unsuccessful search. An empty INSTR needle
matches at the start position if it is within the input string. Integer
arguments require exact int32 values, including when fixed-point values are enabled.
Strings hold bytes, including NUL and UTF-8, but indexing and case conversion
are not Unicode character operations. Numeric formatting uses the VM's
existing decimal formatter rather than reproducing every QBasic format.
Native strings also work with `disableFixed = true`.

### String limits and lifetime

`Limits.maxStrings`, `maxStringBytes`, and `maxStringLength` bound native
string storage. Defaults are 256 slots, 64 KiB of stored bytes, and 1024 bytes
per string. Slot zero holds the shared empty string and counts toward the
slot limit. Exceeding any limit raises `BasicError`, without truncation.

Each runtime owns its string storage. Literals are copied once per reset,
assignments share immutable references, and substrings use views without
copying bytes. New strings and substring views consume slots until `reset`.
Overwriting a variable does not immediately reclaim its old string. String
churn can therefore exhaust the limits even if only a few variables remain.

`restart` preserves globals, arrays, strings, and bound host data while
restarting execution budgets. `reset` empties globals and arrays and reclaims
string storage, preserving the current bound host data. References retained
by Nim code across `reset` become invalid. Foreign runtime references and
stale references raise `BasicError`. Use `getString` to copy text into Nim
before reset if the host needs to retain it.

Storage is allocated up front only when the program uses native strings.
The runtime memory budget includes both byte arenas, span tables, reset
scratch buffers, and the literal cache. Their logical capacity is
`6 * maxStringBytes + 20 * maxStrings + 4 * program.literalCount` bytes.
Value cells remain 16 bytes. Compiled source/literals, allocator overhead,
and memory allocated by trusted callbacks remain outside that budget.
`runtime.stringCount` and `runtime.stringBytes` report occupied storage.

String copying, concatenation, comparison, transformation, search, and native
string output charge size-dependent work to `maxWorkUnits`. Search charges
its worst-case comparison count before scanning. Output also counts actual
text bytes against `maxPrintBytes` before invoking the callback. Hosts must
still bound their own callbacks and any work performed outside the VM.

### Strings in Nim

```nim
var host = initHost()
discard host.addData("message$", "attack")
let program = compile("reply$ = UCASE$(message$)", host)
var runtime = initRuntime(program, host)
discard runtime.run
doAssert runtime.getStringGlobal("reply$") == "ATTACK"
runtime.setGlobal("reply$", "hold")
runtime.setData("message$", "defend")
```

`setGlobal`, `setArray`, and `setData` accept Nim strings for `$` names.
Read them with `getStringGlobal`, `getStringArray`, and `getStringData`.
`getGlobalValue`, `getArrayValue`, and runtime `getDataValue` also return
`StringValue` references. Resolve those with `runtime.getString(value)`.
Numeric accessors and operators on `Value` reject strings because they lack
the owning runtime needed to read their contents.

`NumericHostProc` accepts `Value` arguments of either type despite its
historical name. A function registered with a `$` suffix must return a
string reference owned by the calling runtime, created with
`runtime.putString(text)` or taken from an existing argument. Functions
without that suffix must return a number. Result types are checked even
when the caller discards the result. Bind callbacks to the runtime whose
storage they use. See [the native string example](../examples/natural_strings.nim).

## Optional handle-based string functions

These functions are available only after the host registers
`addStringFunctions`. All string offsets and lengths are byte-based.

| Function | Result |
| --- | --- |
| `strNew("text")` | Handle for a compiled literal, interned per pool reset. |
| `strLen(s)` | Byte length. |
| `strByte(s, i)` | Byte value at a zero-based index. |
| `strAsc(s)` | First byte, or -1 for an empty string. |
| `strChr(n)` | One-byte string for a value from 0 through 255. |
| `strFromInt(n)` | Decimal integer text. |
| `strVal(s)` | Leading integer, or 0 without digits, saturating on overflow. |
| `strCat(a, b)` | Concatenated strings. |
| `strCatInt(s, n)` | String followed by decimal integer text. |
| `strMid(s, start, length)` | Substring with clamped start and length. |
| `strFind(s, needle, start)` | Match offset from a clamped start, or -1. |
| `strEq(a, b)` | -1 if the string contents are equal, otherwise 0. |
| `strCmp(a, b)` | Lexical comparison as -1, 0, or 1. |
| `strWord(s, i)` | Zero-based whitespace-separated word, or an empty string. |
| `strWordCount(s)` | Number of whitespace-separated words. |
| `strUpper(s)` | ASCII uppercase text. |
| `strLower(s)` | ASCII lowercase text. |
| `strTrim(s)` | Text with surrounding whitespace removed. |

`strVal` accepts leading whitespace, an optional minus, and digits. It stops
at the first non-digit. A leading plus is not recognized.

String count, total stored bytes, single-string length, execution work, and
substring search comparisons are bounded. Handle 0 is the empty string and
counts toward the string limit. Compare string contents with `strEq`, since
equal text can have different handles.

## Unsupported features

There are no multidimensional arrays, fixed-length strings, `MID$` assignment,
`VAL`, script-defined value-returning functions, `on error` handlers, or
built-in file, network, or console input operations. The host chooses the
native capabilities exposed to scripts.
