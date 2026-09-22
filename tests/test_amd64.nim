## Checks every x86-64 encoder against the system assembler.
## Each case names the instruction in Intel syntax and emits it with the
## encoder, then both byte streams must agree exactly.

import
  std/[os, osproc, sequtils, strutils],
  bassy/amd64

var cases: seq[(string, seq[byte])]

template encodes(text: string, body: untyped) =
  ## Records one assembly line beside the bytes the encoder produced.
  block:
    var assembler {.inject.} = Assembler()
    body
    assembler.resolve()
    cases.add((text, assembler.code))

proc disassemble(body: string, name: string): seq[string] =
  ## Assembles a fragment and returns its disassembled instruction text.
  ## Both the encoder's bytes and the reference line go through this same
  ## path, so a shorter but equivalent encoding still compares equal.
  let
    directory = getTempDir() / "bassy-amd64-check"
    source = directory / name & ".s"
    objectFile = directory / name & ".o"
  createDir(directory)
  writeFile(source, ".intel_syntax noprefix\n" & body)
  let build = execCmdEx(
    "clang -c -target x86_64-apple-macos -o " & objectFile & " " & source
  )
  if build.exitCode != 0:
    quit("assembler rejected " & name & ":\n" & build.output & body)
  let dump = execCmdEx("otool -tV -X -arch x86_64 " & objectFile)
  if dump.exitCode != 0:
    quit("otool failed:\n" & dump.output)
  for line in dump.output.splitLines:
    let fields = line.splitWhitespace()
    if fields.len < 2 or not fields[0].endsWith(":"):
      continue
    result.add(fields[1 .. ^1].join(" "))

proc byteLines(bytes: seq[byte]): string =
  ## Renders encoder output as assembler byte directives.
  for value in bytes:
    result.add("\t.byte 0x" & value.toHex(2) & "\n")

if findExe("otool") == "" or findExe("clang") == "":
  echo "skipping: needs clang and otool for the reference encoding"
  quit(0)

## Moves

encodes "mov ebx, esi":
  assembler.moveRegister(Word32, rbx, rsi)
encodes "mov rbx, r14":
  assembler.moveRegister(Word64, rbx, r14)
encodes "mov r15, rdi":
  assembler.moveRegister(Word64, r15, rdi)
encodes "mov ecx, 4660":
  assembler.loadImmediate(Word32, rcx, 4660)
encodes "mov r9d, -1":
  assembler.loadImmediate(Word32, r9, -1)
encodes "movabs r10, 4294967296":
  assembler.loadImmediate(Word64, r10, 4294967296'i64)

## Memory

encodes "mov esi, dword ptr [rbx + 24]":
  assembler.loadWord(rsi, rbx, 24)
encodes "mov dword ptr [rbx + 4104], r14d":
  assembler.storeWord(r14, rbx, 4104)
encodes "mov rbx, qword ptr [rdi]":
  assembler.loadDouble(rbx, rdi, 0)
encodes "mov r12, qword ptr [rdi + 8]":
  assembler.loadDouble(r12, rdi, 8)
encodes "mov qword ptr [rdi + 16], r13":
  assembler.storeDouble(r13, rdi, 16)
encodes "movzx eax, byte ptr [rbx + 32]":
  assembler.loadByteZeroed(rax, rbx, 32)
encodes "movzx r11d, byte ptr [rbx]":
  assembler.loadByteZeroed(r11, rbx, 0)
encodes "mov byte ptr [rbx + 48], 0":
  assembler.storeByteImmediate(rbx, 48, 0)

## Arithmetic

encodes "add esi, ecx":
  assembler.addRegister(Word32, rsi, rcx)
encodes "add r14d, r15d":
  assembler.addRegister(Word32, r14, r15)
encodes "sub r12, rax":
  assembler.subtractRegister(Word64, r12, rax)
encodes "add ecx, 1":
  assembler.addImmediate(Word32, rcx, 1)
encodes "add r8d, -3":
  assembler.addImmediate(Word32, r8, -3)
encodes "sub esi, 100":
  assembler.subtractImmediate(Word32, rsi, 100)
encodes "cmp r14d, 1000000":
  assembler.compareImmediate(Word32, r14, 1000000)
encodes "cmp esi, ecx":
  assembler.compareRegister(Word32, rsi, rcx)
encodes "cmp r12, rax":
  assembler.compareRegister(Word64, r12, rax)
encodes "test edx, edx":
  assembler.testRegister(Word32, rdx, rdx)
encodes "imul ecx, esi":
  assembler.multiplyRegister(Word32, rcx, rsi)
encodes "cdq":
  assembler.signExtendToPair(Word32)
encodes "cqo":
  assembler.signExtendToPair(Word64)
encodes "idiv r11d":
  assembler.signedDivide(Word32, r11)
encodes "idiv ecx":
  assembler.signedDivide(Word32, rcx)

## Stack and control flow

encodes "push rbx":
  assembler.push(rbx)
encodes "push r15":
  assembler.push(r15)
encodes "pop r12":
  assembler.pop(r12)
encodes "pop rbp":
  assembler.pop(rbp)
encodes "ret":
  assembler.returnToCaller()

## Branch displacement resolution

block:
  var assembler = Assembler()
  let top = assembler.label()
  let done = assembler.label()
  assembler.place(top)
  assembler.compareImmediate(Word32, rsi, 10)
  assembler.branchIf(GreaterEqualCondition, done)
  assembler.addRegister(Word32, rcx, rsi)
  assembler.branch(top)
  assembler.place(done)
  assembler.returnToCaller()
  assembler.resolve()
  cases.add((
    "1:\tcmp esi, 10\n\tjge 2f\n\tadd ecx, esi\n\tjmp 1b\n2:\tret",
    assembler.code
  ))

var failures = 0
for index, (expected, produced) in cases:
  let wanted = disassemble("\t" & expected & "\n", "wanted" & $index)
  let got = disassemble(produced.byteLines, "got" & $index)
  if wanted != got:
    inc failures
    echo "mismatch for: ", expected.replace("\n\t", " ; ")
    echo "  encoder bytes: ", produced.mapIt(it.toHex(2)).join(" ")
    echo "  encoder means: ", got.join(" ; ")
    echo "  reference:     ", wanted.join(" ; ")

if failures > 0:
  quit($failures & " of " & $cases.len & " encodings disagree")
echo "all ", cases.len, " x86-64 encodings decode to the intended instruction"
