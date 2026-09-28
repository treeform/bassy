# Native arrays and blobs

A contextual host callback can return a numeric array and update an opaque blob:

```basic
dim data(2)
if initialized = 0 then
  state = blobCreate()
  initialized = 1
end if
res = evaluate(state, data)
first = res(0)
alias = res
alias(0) = first + 1
blobClear(state)
```

Register `blobCreate()` and `blobClear(blob)` with `host.addBufferFunctions()`.
Each costs one work unit. Register the application callback with
`host.addFunction(name, argumentCount, callback, workUnits)` as usual.
Architectures use the existing host-call instruction.

The callback receives `Runtime` and `openArray[Value]`. Use
`runtime.arrayView(arguments[i])` for checked access to a DIM array or a returned
array. Use `runtime.putArray(values)` to return a fresh array containing only
integer or Q16.16 values. The VM copies its elements. BASIC assignment aliases
returned arrays; indexed writes are visible through all aliases. Returned arrays
are one-dimensional and zero-indexed. Their length is available to the host view.
DIM arrays retain their existing program-local integer handle representation.
Returned arrays and blobs have distinct, checked value kinds and cannot be used
as numbers or forged by passing an integer. Numeric host array arguments retain
the existing compatibility with DIM handles.

Use `getBlob`, `blobBinding`, and `putBlob` to read and replace opaque state.
The optional binding string belongs to the host, for example an architecture and
model identity. BASIC can create, pass, alias, and clear blobs, but cannot inspect
their bytes. Clearing also removes the binding while preserving the handle.
Both replacement fields are checked against the memory allowance before commit.
A host must finish validation and computation before calling `putBlob`. For a
callback returning an array and changing state, preflight the combined storage
with `checkNativeMemory` before allocating the result and committing the blob.
General callbacks are responsible for their own transactional behavior.

Buffers belong to exactly one runtime. Cross-runtime, stale, wrong-kind and
out-of-range accesses raise `BasicError`, including release builds. A process-wide
atomic generation prevents reuse of an old handle after collection or reset.
Generation exhaustion raises an error instead of wrapping. Full `reset()` frees
all buffers, invalidates their handles, and clears any buffer-valued host data.
`restart()` preserves globals, DIM arrays, host data, and their reachable buffers.
Destroying the runtime releases its buffers and host callback closures.

Before each contextual host call, collection marks values in globals, DIM arrays,
registers, argument slots and host data, then reclaims unreferenced buffers.
Temporary values in nested calls remain roots. Returning a new array on each step
does not accumulate abandoned outputs. Values retained only in a host variable
are not roots: keep them in VM globals or host data while needed. Do not manually
call `collectBuffers()` while holding newly allocated, unpublished callback
results. Borrowed views require their owning value to remain reachable.

`Limits.maxNativeMemoryBytes` defaults to 64 MiB and is separate from ordinary
`maxMemoryBytes`. Applications may set a smaller allowance. Numeric payloads,
blob bytes, bindings and conservative slot metadata are counted. The existing
array-count and array-element limits also bound native buffers. Inspect usage
with `nativeMemoryBytes()`. Hosts reserve models and scratch space with
`reserveNativeMemory(bytes)` before allocation and release it with
`releaseNativeMemory(bytes)`. Reservations persist across full resets because
immutable models in host closures can remain alive. The host must release any
reservation for storage it drops. These are logical limits, not a process RSS
limit or allocator instrumentation.

The tests cover aliasing, nested calls, reset, foreign and stale handles,
failed mutations, fixed-point-disabled runtimes, host roots and bounded churn.
