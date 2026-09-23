## Checks every AArch64 encoder against the system assembler.
## Each case names the instruction in assembly text and emits it with the
## encoder, then both byte streams must agree exactly.

import
  std/[os, osproc, sequtils, strutils],
  bassy/arm64

var cases: seq[(string, seq[uint32])]

template encodes(text: string, body: untyped) =
  ## Records one assembly line beside the words the encoder produced.
  block:
    var assembler {.inject.} = Assembler()
    body
    assembler.resolve()
    cases.add((text, assembler.code))

proc assembled(lines: seq[string]): seq[seq[uint32]] =
  ## Assembles each line with clang and returns its instruction words.
  let
    directory = getTempDir() / "bassy-arm64-check"
    source = directory / "check.s"
    objectFile = directory / "check.o"
  createDir(directory)
  var text = ""
  for line in lines:
    text.add("\t" & line & "\n")
  writeFile(source, text)
  let build = execCmdEx(
    "clang -c -target arm64-apple-macos -o " & objectFile & " " & source
  )
  if build.exitCode != 0:
    quit("assembler rejected a reference line:\n" & build.output)
  let dump = execCmdEx("otool -t -X " & objectFile)
  if dump.exitCode != 0:
    quit("otool failed:\n" & dump.output)
  var words: seq[uint32]
  for line in dump.output.splitLines:
    let fields = line.splitWhitespace()
    if fields.len < 2:
      continue
    for index in 1 ..< fields.len:
      words.add(uint32(parseHexInt(fields[index])))
  # Regroup the flat word stream back into per-case instruction counts.
  var start = 0
  for (_, produced) in cases:
    var chunk: seq[uint32]
    for index in 0 ..< produced.len:
      if start >= words.len:
        quit("assembler produced fewer words than the encoder")
      chunk.add(words[start])
      inc start
    result.add(chunk)
  if start != words.len:
    quit("assembler produced more words than the encoder")

if findExe("otool") == "" or findExe("clang") == "":
  echo "skipping: needs clang and otool for the reference encoding"
  quit(0)

## Moves and immediates

encodes "mov w3, w7":
  assembler.moveRegister(Word32, x3, x7)
encodes "mov x3, x7":
  assembler.moveRegister(Word64, x3, x7)
encodes "movz x3, #4660, lsl #16":
  assembler.moveZero(Word64, x3, 4660, 16)
encodes "movk w5, #255":
  assembler.moveKeep(Word32, x5, 255)
encodes "movn x9, #1":
  assembler.moveNot(Word64, x9, 1)

## Arithmetic

encodes "add w2, w2, w1":
  assembler.addRegister(Word32, x2, x2, x1)
encodes "add x10, x11, x12, lsl #4":
  assembler.addRegister(Word64, x10, x11, x12, 4)
encodes "add w1, w1, #1":
  assembler.addImmediate(Word32, x1, x1, 1)
encodes "sub x4, x5, #4095":
  assembler.subtractImmediate(Word64, x4, x5, 4095)
encodes "sub w6, w7, w8":
  assembler.subtractRegister(Word32, x6, x7, x8)
encodes "cmp w1, w0":
  assembler.compareRegister(Word32, x1, x0)
encodes "cmp x1, #17":
  assembler.compareImmediate(Word64, x1, 17)
encodes "neg w3, w4":
  assembler.negate(Word32, x3, x4)
encodes "mul w1, w2, w3":
  assembler.multiply(Word32, x1, x2, x3)
encodes "madd x1, x2, x3, x4":
  assembler.multiplyAdd(Word64, x1, x2, x3, x4)
encodes "msub w9, w10, w11, w12":
  assembler.multiplySubtract(Word32, x9, x10, x11, x12)
encodes "sdiv w1, w2, w3":
  assembler.signedDivide(Word32, x1, x2, x3)

encodes "smull x1, w2, w3":
  assembler.signedMultiplyLong(x1, x2, x3)
encodes "asr x4, x5, #16":
  assembler.arithmeticShiftRight(Word64, x4, x5, 16)
encodes "asr w6, w7, #3":
  assembler.arithmeticShiftRight(Word32, x6, x7, 3)

## Logic

encodes "and w1, w2, w3":
  assembler.andRegister(Word32, x1, x2, x3)
encodes "orr x1, x2, x3":
  assembler.orRegister(Word64, x1, x2, x3)
encodes "eor w4, w5, w6":
  assembler.xorRegister(Word32, x4, x5, x6)
encodes "mvn w7, w8":
  assembler.notRegister(Word32, x7, x8)
encodes "csetm w1, lt":
  assembler.setOnCondition(Word32, x1, LessCondition)
encodes "csetm w2, eq":
  assembler.setOnCondition(Word32, x2, EqualCondition)
encodes "csetm x3, ge":
  assembler.setOnCondition(Word64, x3, GreaterEqualCondition)

encodes "tst w22, #1":
  assembler.testLowBits(Word32, x22, 1)
encodes "tst w3, #7":
  assembler.testLowBits(Word32, x3, 3)
encodes "tst x4, #0xffff":
  assembler.testLowBits(Word64, x4, 16)

## Memory

encodes "ldr w5, [x6, #12]":
  assembler.loadWord(x5, x6, 12)
encodes "str w7, [x8]":
  assembler.storeWord(x7, x8)
encodes "ldr x9, [x10, #4088]":
  assembler.loadDouble(x9, x10, 4088)
encodes "str x11, [x12, #16]":
  assembler.storeDouble(x11, x12, 16)
encodes "stp x29, x30, [sp, #-32]!":
  assembler.storePair(framePointer, linkRegister, stackPointer, -32, true)
encodes "ldp x29, x30, [sp], #32":
  assembler.loadPair(framePointer, linkRegister, stackPointer, 32, true)
encodes "ldp x19, x20, [sp, #16]":
  assembler.loadPair(x19, x20, stackPointer, 16)

## Branches

encodes "blr x16":
  assembler.callRegister(x16)
encodes "br x9":
  assembler.jumpRegister(x9)
encodes "ret":
  assembler.returnToCaller()

## Multi-word immediate construction

encodes "movz w0, #0":
  assembler.loadImmediate(Word32, x0, 0)
encodes "movz w0, #4660":
  assembler.loadImmediate(Word32, x0, 4660)
encodes "movn w1, #60875":
  assembler.loadImmediate(Word32, x1, 0xFFFF1234)
encodes "movn x2, #0":
  assembler.loadImmediate(Word64, x2, -1)
encodes "movz x3, #22136\n\tmovk x3, #43981, lsl #32":
  assembler.loadImmediate(Word64, x3, 0x0000ABCD_00005678'i64)

## Branch displacement resolution

block:
  var assembler = Assembler()
  let top = assembler.label()
  let done = assembler.label()
  assembler.place(top)
  assembler.compareRegister(Word32, x1, x0)
  assembler.branchIf(GreaterEqualCondition, done)
  assembler.addRegister(Word32, x2, x2, x1)
  assembler.branch(top)
  assembler.place(done)
  assembler.returnToCaller()
  assembler.resolve()
  cases.add((
    "cmp w1, w0\n\tb.ge 1f\n\tadd w2, w2, w1\n\tb . - 12\n1:\tret",
    assembler.code
  ))

block:
  var assembler = Assembler()
  let done = assembler.label()
  assembler.branchIfZero(Word32, x4, done)
  assembler.branchIfNotZero(Word64, x5, done)
  assembler.place(done)
  assembler.returnToCaller()
  assembler.resolve()
  cases.add(("cbz w4, 1f\n\tcbnz x5, 1f\n1:\tret", assembler.code))

var lines: seq[string]
for (text, _) in cases:
  lines.add(text)

let reference = assembled(lines)
var failures = 0
for index, (text, produced) in cases:
  let expected = reference[index]
  if produced != expected:
    inc failures
    echo "mismatch for: ", text.replace("\n\t", " ; ")
    echo "  encoder:   ", produced.mapIt(it.toHex(8)).join(" ")
    echo "  assembler: ", expected.mapIt(it.toHex(8)).join(" ")

if failures > 0:
  quit($failures & " of " & $cases.len & " encodings disagree")
echo "all ", cases.len, " AArch64 encodings match the system assembler"
