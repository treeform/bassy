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

encodes "mov byte ptr [rbp + 16], r11b":
  assembler.storeByteLow(rbp, 16, r11)
encodes "mov byte ptr [rbx], al":
  assembler.storeByteLow(rbx, 0, rax)

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

encodes "neg eax":
  assembler.negateRegister(Word32, rax)
encodes "neg r11d":
  assembler.negateRegister(Word32, r11)
encodes "setl al\n\tmovzx eax, al":
  assembler.setIfCondition(rax, LessCondition)
encodes "sete dl\n\tmovzx edx, dl":
  assembler.setIfCondition(rdx, EqualCondition)

encodes "shl rax, 4":
  assembler.shiftLeftImmediate(Word64, rax, 4)
encodes "shl r11d, 1":
  assembler.shiftLeftImmediate(Word32, r11, 1)

encodes "movsxd rax, ecx":
  assembler.signExtendDouble(rax, rcx)
encodes "movsxd r11, edx":
  assembler.signExtendDouble(r11, rdx)
encodes "sar rax, 16":
  assembler.shiftRightImmediate(Word64, rax, 16)

## Stack and control flow

encodes "push rbx":
  assembler.push(rbx)
encodes "push r15":
  assembler.push(r15)
encodes "pop r12":
  assembler.pop(r12)
encodes "pop rbp":
  assembler.pop(rbp)
encodes "and eax, ecx":
  assembler.andRegister(Word32, rax, rcx)
encodes "and r9d, esi":
  assembler.andRegister(Word32, r9, rsi)
encodes "or edi, r10d":
  assembler.orRegister(Word32, rdi, r10)
encodes "xor r8d, r9d":
  assembler.xorRegister(Word32, r8, r9)
encodes "xor rax, rdx":
  assembler.xorRegister(Word64, rax, rdx)
encodes "not ecx":
  assembler.notRegister(Word32, rcx)
encodes "not r10d":
  assembler.notRegister(Word32, r10)
encodes "call rax":
  assembler.callRegister(rax)
encodes "call r11":
  assembler.callRegister(r11)
encodes "jmp rcx":
  assembler.jumpRegister(rcx)
encodes "jmp r11":
  assembler.jumpRegister(r11)
block:
  var assembler = Assembler()
  let target = assembler.label()
  assembler.callLabel(target)
  assembler.place(target)
  assembler.returnToCaller()
  assembler.resolve()
  cases.add(("call 1f\n1:\tret", assembler.code))
encodes "test eax, 7":
  assembler.testImmediate(Word32, rax, 7)
encodes "test r14d, 1023":
  assembler.testImmediate(Word32, r14, 1023)
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
