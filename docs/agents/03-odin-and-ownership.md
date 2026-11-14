# Odin, ownership, and FFI

Referenced from `AGENTS.md`. Covers toolchain/API verification, style,
ownership/allocation, errors/assertions/unsafe code, and FFI.

## 8. Toolchain and API verification

Use the repository's pinned Odin version and dependency versions.

Before using an unfamiliar API:

1. Inspect the installed package source.
2. Check existing repository usage.
3. Consult official documentation.
4. Verify with a minimal compile/check if needed.

Preferred references:

- https://odin-lang.org/docs/overview/
- https://odin-lang.org/docs/testing/
- The pinned compiler's help output.
- The pinned `core`, `base`, and `vendor` package sources.
- The pinned Sokol headers and Odin bindings.

Do not invent:

- Compiler flags.
- Package paths.
- Standard-library procedures.
- Error constants.
- Attributes.
- Calling conventions.
- Collection operations.

Do not paste code from another Odin version and assume compatibility.

Do not translate Go, Rust, C++, or C syntax mechanically into Odin.

If documentation and the installed version differ, the pinned version's
actual behavior governs the implementation.

## 9. Odin style and design

### 9.1 Follow established local conventions

Use existing repository style when consistent.

For new code, prefer:

- `snake_case` for procedures, variables, and fields.
- Descriptive type names such as `Buffer`, `Buffer_ID`, and `Text_Snapshot`.
- Named enums and unions for meaningful states.
- Small, cohesive packages.
- Explicit imports.
- Consistent indentation matching the repository.

Avoid:

- Single-letter names outside short mathematical/indexing contexts.
- Unnecessary `using` that hides field origins.
- Clever operator tricks.
- Excessive overloads.
- Unnecessary polymorphism.
- Deeply nested procedures that obscure ownership.
- Giant multipurpose modules.

Do not create a package for every small struct.

### 9.2 Data-oriented, not abstraction-heavy

Prefer:

- Plain structs.
- Explicit state machines.
- Straightforward procedures.
- Tables where they clarify a finite mapping.
- Clear subsystem boundaries.

Do not simulate:

- Class hierarchies.
- Trait systems.
- Dependency-injection frameworks.
- Generic service locators.
- Elaborate exception systems.

Use abstraction when there are real implementations or a necessary boundary:
platform adapters, renderer boundaries, persistence, IPC, and text storage.

### 9.3 Make invalid states harder to represent

Prefer enums/unions over related booleans when representing exclusive states.

Bad:

- `is_running`, `is_finished`, `has_failed`, `is_canceling` with unclear combinations.

Better:

- A job-state enum and state-specific metadata.

Use distinct types where accidental interchange is dangerous, for example:

    Buffer_ID   :: distinct u64
    Window_ID   :: distinct u64
    Byte_Offset :: distinct i64

Validate conversions at boundaries.

Do not cast away type distinctions merely to silence the compiler.

## 10. Odin ownership and allocation

Odin is manually managed. Assume nothing is garbage-collected.

### 10.1 Every allocation has an owner

For every owned resource, identify:

- Who allocates it.
- Who destroys it.
- Which allocator owns it.
- Whether ownership can transfer.
- Which borrows may exist.
- What invalidates those borrows.

Document these rules at API boundaries.

Use comments such as:

- `Borrowed; valid until the next mutation.`
- `Owned by caller; destroy with ...`
- `Copied into the destination allocator.`
- `Ownership transfers on success only.`

Do not make every local variable comment-heavy.
Document the contracts that are not obvious.

### 10.2 Containers are not deep-copy magic

Assignment of slices, strings, maps, and dynamic-array-containing structs
does not imply an independent deep copy.

Be especially careful with:

- Copying an owning struct.
- Copying a dynamic-array header.
- Keeping a slice into a resizable array.
- Returning a view into local storage.
- Storing a temporary string in a long-lived map.

Do not delete both copies of the same owner.

Do not keep element pointers or slices across operations that may resize,
remove, compact, or replace backing storage.

Use stable IDs instead of container-element pointers for long-lived references.

### 10.3 Strings and slices

An Odin string is not an owning, automatically freed object.

A slice is a view; ownership is a separate contract.

Do not:

- Free string literals.
- Delete arbitrary borrowed subslices.
- Return slices of stack-local arrays.
- Return strings backed by temporary formatting storage.
- Store borrowed string keys whose backing storage may disappear.
- Assume converting bytes to a string creates an owned copy.

Copy or clone explicitly when the destination needs a longer lifetime.

Preserve the allocation base and allocator needed for correct destruction.

### 10.4 Match allocation and destruction

Use the destruction operation appropriate to the allocation/resource type.

Examples:

- Heap pointer allocations require the appropriate `free`.
- Owned slices/dynamic arrays/maps require their appropriate `delete`.
- Native handles require the native close/destroy operation.
- Library resources require the library's destructor.

Do not use one generic cleanup operation for everything.

Containers do not automatically destroy heap-owned resources nested inside
their elements.

Destroy nested resources deliberately before destroying the container.

For slices, strings, and other allocations whose owner is not carried with
the value, preserve the allocator contract explicitly.

Do not assume the current `context.allocator` still matches the allocator
used when the memory was created.

### 10.5 Context and allocator discipline

We disabled `context.allocator` by replacing it with a panic allocator.

You are recommended to use `core:mem/virtual`.

Use:

- One arena allocator to store items whose lifetime lives through the entire program.
- Persistent allocators for persistent data.
- Group allocators based on lifetime.
- Utilize alternative allocator such as `core:container/pool` based on usage.
- Frame arenas for frame-local data.
- Worker-local scratch allocators for worker-local temporary data.
- Explicit result allocators for data crossing subsystem boundaries.
- Descriptive allocator names.

Do not:

- Return scratch-backed results after resetting scratch memory.
- Put persistent buffer text in a frame arena.
- Reset a shared arena while another thread is reading it.
- Change allocator context without a clear scope and restoration policy.
- Assume an allocator is thread-safe.
- Assume ambient context is an ownership record.

Only reset an arena at a documented boundary after all borrowers are done.

Calling `free_all` on a scratch allocator is a subsystem operation, not a
convenient way to clean up unknown allocations.

However, every allocator MUST be `free_all`ed at some point.

### 10.6 `defer`

Use `defer` for local cleanup once resource acquisition has succeeded.

Remember:

- Odin defers are block-scoped.
- Cleanup order matters.
- A deferred cleanup must not destroy ownership that was returned/transferred.
- Defers are not a guarantee after process termination or power loss.
- Resource dependencies must outlive the resources using them.

Understand deferred argument and variable behavior before deferring cleanup
of a value that will later be reassigned.

Avoid ambiguous cleanup around ownership transfer. Prefer a clearly named
owner and an explicit successful-transfer path.

### 10.7 Partial initialization

Initialization can fail halfway through.

Define cleanup for:

- Zero initialized.
- Partially initialized.
- Fully initialized.
- Already destroyed, if idempotence is promised.

Do not mark a subsystem initialized before all required resources exist.

Do not leak earlier resources when a later acquisition fails.

### 10.8 Allocation failure and budgets

For user-sized inputs:

- Validate lengths.
- Check arithmetic overflow.
- Enforce documented budgets.
- Handle allocation failure where the API permits it.
- Fail without corrupting existing state.

Do not assume every allocation operation has the same failure behavior.

Inspect the actual Odin allocator/container API.

## 11. Errors, assertions, and unsafe operations

### 11.1 Recoverable errors are values

Use explicit error/result types appropriate to the subsystem.

Distinguish:

- Invalid input.
- Unsupported feature.
- I/O failure.
- Revision conflict.
- Cancellation.
- Resource limit.
- Internal invariant failure.

Check all meaningful error returns.

Do not ignore errors just to keep the happy path short.

Do not assume every Odin error is nullable or uses the same success constant.

### 11.2 Assertions

Use assertions for programmer invariants, not ordinary external input.

Do not assert that:

- A file exists.
- Clipboard access succeeds.
- A subprocess starts.
- An IPC frame is valid.
- A font loads.
- Disk writes succeed.
- A configuration value is valid.

Those are recoverable failures.

Panic/assertion paths are not substitutes for orderly save and shutdown.

### 11.3 Unsafe code

Keep these localized:

- `rawptr`.
- Pointer arithmetic.
- `transmute`.
- Manual layout assumptions.
- Foreign memory.
- Bounds-check suppression.
- Unchecked casts.

For each unsafe boundary, explain:

- Required preconditions.
- Alignment.
- Length and bounds.
- Ownership.
- Lifetime.
- Thread restrictions.
- Validation already performed.

Do not disable bounds checks globally to improve a benchmark.

Do not use `transmute` where a normal conversion or explicit serialization
is appropriate.

### 11.4 Serialization

Do not serialize raw struct memory as a persistent format.

Struct padding, native endianness, pointer fields, and platform layouts
are not stable formats.

Use:

- Fixed-width fields.
- Explicit byte order.
- Versioning.
- Length limits.
- Validation.
- Checksums where needed.

Never deserialize pointers or native handles.

## 12. FFI and native resource rules

Use the exact pinned foreign declaration.

Verify:

- Calling convention.
- Integer widths.
- Struct packing/alignment.
- Pointer nullability.
- Ownership.
- Callback lifetime.
- Thread affinity.
- Encoding.
- Null termination.

Odin `string` is not a C string.
Do not pass it as `cstring` without a valid conversion/lifetime strategy.

Do not free foreign-owned memory with an Odin allocator.

Do not hand temporary memory to an API that retains it.

For callbacks:

- Establish a valid Odin context when required.
- Do not assume foreign threads inherit the correct context.
- Do not use UI-thread arenas from a foreign callback.
- Queue work instead of mutating editor state from arbitrary callbacks.
- Ensure callback/user-data storage outlives registration.
- Unregister callbacks before destroying their state.

Use the appropriate native success/failure convention.
A nonzero integer does not mean the same thing in every API.
