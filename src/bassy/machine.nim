## Allocates writable-then-executable pages for generated machine code.
## Each platform enforces write-xor-execute differently, so the buffer
## keeps the page writable while emitting and seals it before any call.

import numbers

type
  CodeBuffer* = object
    ## One page-aligned region holding finished machine code.
    memory: pointer
    capacity: int
    length: int
    sealed: bool

const
  PageBytes* = 4096

  ## Apple silicon is the one target that keeps pages executable while
  ## they are written, because it gates the writing per thread instead.
  AppleSilicon* = defined(macosx) and defined(arm64)

  ## Whether this target can emit and run machine code at all. Everywhere
  ## else, including WebAssembly, the interpreter is the only path and no
  ## platform-specific declaration is emitted. Define bassyNoJit to force
  ## the interpreter on a target that would otherwise qualify.
  NativeCode* =
    when defined(bassyNoJit):
      false
    elif defined(arm64) and (
      defined(macosx) or defined(linux) or defined(windows)
    ):
      true
    elif defined(amd64) and (
      defined(macosx) or defined(linux) or defined(windows)
    ):
      true
    else:
      false

when NativeCode and defined(windows):
  # These follow the Windows header types exactly: DWORD is an unsigned
  # long there, which is a different type from an unsigned int even where
  # the two are the same width.
  const
    MemCommit = 0x1000.culong
    MemReserve = 0x2000.culong
    MemRelease = 0x8000.culong
    PageReadWrite = 0x04.culong
    PageExecuteRead = 0x20.culong

  proc virtualAlloc(address: pointer, size: csize_t,
      allocation, protection: culong): pointer
    {.importc: "VirtualAlloc", header: "<windows.h>", stdcall.}

  proc virtualProtect(address: pointer, size: csize_t, protection: culong,
      previous: ptr culong): cint
    {.importc: "VirtualProtect", header: "<windows.h>", stdcall.}

  proc virtualFree(address: pointer, size: csize_t, freeType: culong): cint
    {.importc: "VirtualFree", header: "<windows.h>", stdcall.}

  proc currentProcess(): pointer
    {.importc: "GetCurrentProcess", header: "<windows.h>", stdcall.}

  proc flushInstructionCache(process, address: pointer, size: csize_t): cint
    {.importc: "FlushInstructionCache", header: "<windows.h>", stdcall.}
elif NativeCode:
  const
    ProtNone = 0x0.cint
    ProtRead = 0x1.cint
    ProtWrite = 0x2.cint
    ProtExec = 0x4.cint
    MapPrivate = 0x0002.cint
    MapFailed = -1

  when AppleSilicon:
    const
      MapAnonymous = 0x1000.cint
      MapJit = 0x0800.cint
  elif defined(macosx):
    const
      MapAnonymous = 0x1000.cint
      MapJit = 0.cint
  else:
    const
      MapAnonymous = 0x20.cint
      MapJit = 0.cint

  proc mmap(address: pointer, length: csize_t, protection, flags,
      handle: cint, offset: int): pointer
    {.importc: "mmap", header: "<sys/mman.h>".}

  proc mprotect(address: pointer, length: csize_t, protection: cint): cint
    {.importc: "mprotect", header: "<sys/mman.h>".}

  proc munmap(address: pointer, length: csize_t): cint
    {.importc: "munmap", header: "<sys/mman.h>".}

when NativeCode and AppleSilicon:
  proc jitWriteProtect(enabled: cint)
    {.importc: "pthread_jit_write_protect_np", header: "<pthread.h>".}

  proc invalidateInstructionCache(address: pointer, length: csize_t)
    {.importc: "sys_icache_invalidate",
      header: "<libkern/OSCacheControl.h>".}
elif NativeCode and defined(arm64):
  proc clearCache(start, stop: pointer)
    {.importc: "__builtin___clear_cache", nodecl.}

proc `=copy`*(destination: var CodeBuffer, source: CodeBuffer) {.error:
  "a code buffer owns its pages and cannot be copied".}

proc `=destroy`*(buffer: CodeBuffer) {.raises: [].} =
  ## Returns the pages when the last owner goes away, so a program that
  ## compiles many scripts does not accumulate executable mappings. The
  ## buffer cannot be copied, so there is exactly one owner to go away.
  if buffer.memory == nil:
    return
  when NativeCode and defined(windows):
    discard virtualFree(buffer.memory, 0.csize_t, MemRelease)
  elif NativeCode:
    discard munmap(buffer.memory, csize_t(buffer.capacity))

proc fail(message: string) {.noreturn, raises: [BasicError].} =
  ## Reports a controlled code buffer failure.
  raise newException(BasicError, "BASIC " & message)

proc jitSupported*(): bool {.inline, raises: [].} =
  ## Reports whether this build can emit and run native code.
  NativeCode

proc roundedToPage(size: int): int {.raises: [].} =
  ## Rounds a byte count up to whole pages.
  ((size + PageBytes - 1) div PageBytes) * PageBytes

proc initCodeBuffer*(capacity: int): CodeBuffer {.raises: [BasicError].} =
  ## Reserves writable pages sized to hold the requested byte count.
  if capacity <= 0:
    fail("code buffer capacity must be positive")
  let size = roundedToPage(capacity)
  when not NativeCode:
    fail("this build has no native code backend")
  elif defined(windows):
    let memory = virtualAlloc(
      nil, csize_t(size), MemCommit or MemReserve, PageReadWrite
    )
    if memory == nil:
      fail("code buffer reservation failed")
    result = CodeBuffer(
      memory: memory, capacity: size, length: 0, sealed: false
    )
  else:
    const OpenProtection =
      when AppleSilicon: ProtRead or ProtWrite or ProtExec
      else: ProtRead or ProtWrite
    let memory = mmap(
      nil,
      csize_t(size),
      OpenProtection,
      MapPrivate or MapAnonymous or MapJit,
      -1,
      0
    )
    if cast[int](memory) == MapFailed:
      fail("code buffer reservation failed")
    result = CodeBuffer(
      memory: memory, capacity: size, length: 0, sealed: false
    )

proc len*(buffer: CodeBuffer): int {.inline, raises: [].} =
  ## Returns how many bytes have been emitted so far.
  buffer.length

proc capacity*(buffer: CodeBuffer): int {.inline, raises: [].} =
  ## Returns the reserved byte count, rounded up to whole pages.
  buffer.capacity

proc beginWrite(buffer: var CodeBuffer) {.raises: [].} =
  ## Makes the pages writable on platforms that enforce write-xor-execute.
  when NativeCode and AppleSilicon:
    jitWriteProtect(0)

proc endWrite(buffer: var CodeBuffer) {.raises: [].} =
  ## Restores execute permission after a batch of writes.
  when NativeCode and AppleSilicon:
    jitWriteProtect(1)

proc write*(buffer: var CodeBuffer, source: pointer, size: int)
    {.raises: [BasicError].} =
  ## Appends raw bytes, refusing to run past the reserved pages.
  if buffer.sealed:
    fail("code buffer is already sealed")
  if size < 0 or buffer.length + size > buffer.capacity:
    fail("code buffer capacity exceeded")
  if size == 0:
    return
  buffer.beginWrite()
  copyMem(
    cast[pointer](cast[int](buffer.memory) + buffer.length), source, size
  )
  buffer.endWrite()
  buffer.length += size

proc write*(buffer: var CodeBuffer, words: openArray[uint32])
    {.raises: [BasicError].} =
  ## Appends fixed-width instruction words, as used by AArch64.
  if words.len == 0:
    return
  buffer.write(words[0].addr, words.len * sizeof(uint32))

proc write*(buffer: var CodeBuffer, bytes: openArray[byte])
    {.raises: [BasicError].} =
  ## Appends a variable-length instruction stream, as used by x86-64.
  if bytes.len == 0:
    return
  buffer.write(bytes[0].addr, bytes.len)

proc seal*(buffer: var CodeBuffer) {.raises: [BasicError].} =
  ## Publishes the emitted bytes so the processor may execute them.
  if buffer.sealed:
    return
  if buffer.length == 0:
    fail("code buffer holds no instructions")
  when not NativeCode:
    fail("this build has no native code backend")
  elif defined(windows):
    var previous = 0.culong
    if virtualProtect(
      buffer.memory, csize_t(buffer.capacity), PageExecuteRead,
      previous.addr
    ) == 0:
      fail("code buffer could not be made executable")
    discard flushInstructionCache(
      currentProcess(), buffer.memory, csize_t(buffer.length)
    )
    buffer.sealed = true
  elif AppleSilicon:
    # These pages are executable already, and writing to them is what is
    # gated, so there is nothing to drop here and only the cache to flush.
    invalidateInstructionCache(buffer.memory, csize_t(buffer.length))
    buffer.sealed = true
  else:
    # Drop write as execute is granted, so the pages are never both.
    if mprotect(
      buffer.memory, csize_t(buffer.capacity), ProtRead or ProtExec
    ) != 0:
      fail("code buffer could not be made executable")
    when defined(arm64):
      clearCache(
        buffer.memory,
        cast[pointer](cast[int](buffer.memory) + buffer.length)
      )
    buffer.sealed = true

proc entry*(buffer: CodeBuffer): pointer {.raises: [BasicError].} =
  ## Returns the address of the first instruction once sealed.
  if not buffer.sealed:
    fail("code buffer must be sealed before it is called")
  buffer.memory

proc release*(buffer: var CodeBuffer) {.raises: [].} =
  ## Returns the pages early, before the owner itself goes away.
  `=destroy`(buffer)
  buffer.memory = nil
  buffer.capacity = 0
  buffer.length = 0
  buffer.sealed = false
