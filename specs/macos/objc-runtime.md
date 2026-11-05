# Spec: Ycode's Objective-C runtime (`libobjc.A.dylib`) for macOS programs

Status: **design, wave 1 implemented (1.0.0-beta.3, #86)** in
`ycode/MacUserland/objc/`; conformance tests pass on the Mac and under
`ycode-simd --macos`; benchmarks in §14. The Swift runtime's entry points
(§15) were added for stage B (#87). Ycode design, clean room.

Sources, and only these: clang's Objective-C code generation as documented
by the open LLVM project (Apache-2.0 with LLVM exception) and as observed in
object files that Ycode compiles itself with clang; the public macOS SDK
headers `objc/runtime.h`, `objc/message.h`, `objc/objc.h`, `objc/NSObject.h`,
`objc/objc-sync.h`, `objc/objc-exception.h` and `Block.h` (declarations,
constants and layouts are interoperability facts); the public Mach-O headers
(`mach-o/loader.h`); Apple's public *Objective-C Runtime Programming Guide*
and *Advanced Memory Management Programming Guide*; the Ycode specs
`dyld.md` and `libsystem.md`. **No Objective-C runtime source was read**
(not Apple's objc4, not GNUstep's libobjc2, not the GNU runtime). Upstream
objc4 is at most a benchmark baseline (§12).

Context: `macos-apps.md` §6 (the owner's decision 2: Ycode writes its own
runtime in Rust; objc4 ships instead only if Ycode's runtime cannot match
it on the benchmarks).

## 1. Scope

The runtime is `/usr/lib/libobjc.A.dylib` in the macOS userland root. A
program built against the macOS SDK with `-lobjc` (or any framework that
pulls in libobjc) binds to it by two-level namespace, so it must export the
symbols the SDK's link stub names, with the SDK headers' signatures.

| Part | Language | Wave |
|---|---|---|
| Image loading (`__objc_*` sections), selectors, classes, categories, protocols, `+load` | Rust | 1 |
| `objc_msgSend`, `objc_msgSendSuper`, `objc_msgSendSuper2`, the nil and forwarding paths, the method cache probe | arm64 assembly (in the Rust crate) | 1 |
| Class realization, method lookup, `+initialize`, `+resolveInstanceMethod:` | Rust | 1 |
| `retain`/`release`/`autorelease`, inline and side-table counts, `dealloc` | Rust | 1 |
| `@autoreleasepool`, the return-value hand-off | Rust (+ two asm entry shims) | 1 |
| Weak references, associated objects, `@synchronized`, property accessors | Rust | 1 |
| `NSObject` and `Protocol` root classes | Rust statics in the compiler's layout | 1 |
| Runtime introspection and class construction (`objc/runtime.h`) | Rust | 1 (core), 2 (rest) |
| Exceptions (`objc_exception_throw` with unwinding), `imp_implementationWithBlock`, tagged-pointer classes, `objc_msgSend` debug/`stret` variants | — | 2+ (§13) |

The crate is `no_std`, uses `alloc` over the libSystem `malloc`, links no
Rust standard library, and builds as a `staticlib` that `MacUserland/build.sh`
links into the dylib (§11).

## 2. Compiler ABI: what clang emits (interop facts)

All structures are little-endian, pointer-sized fields 8 bytes. Names in
this table are descriptive; field order and sizes are what matter.

### 2.1 Sections

| Section (segment as linked) | Content |
|---|---|
| `__objc_imageinfo` (`__DATA_CONST`) | `{ u32 version = 0, u32 flags }`. Flag `1<<6`: categories carry a class-properties field |
| `__objc_classlist` (`__DATA_CONST`) | Pointers to every class defined in the image |
| `__objc_nlclslist` (`__DATA_CONST`) | Pointers to classes with their own `+load` |
| `__objc_catlist`, `__objc_nlcatlist` (`__DATA_CONST`) | Pointers to categories; `nl` = categories with `+load` (also in `catlist`) |
| `__objc_protolist` (`__DATA_CONST`) | Pointers to the protocols the image defines |
| `__objc_selrefs` (`__DATA`) | One pointer per selector the code uses, initially to its name string. **The runtime rewrites each to the unique `SEL`** |
| `__objc_classrefs`, `__objc_superrefs` (`__DATA`) | Pointers to class objects (bound by the dynamic linker) |
| `__objc_protorefs` (`__DATA`) | Pointers to protocols; the runtime rewrites each to the canonical protocol |
| `__objc_data` (`__DATA`) | Class and metaclass objects (writable) |
| `__objc_const` (`__DATA`) | `class_ro`, ivar lists, property lists, protocol lists, classic method lists |
| `__objc_ivar` (`__DATA`) | One `u32` offset variable per ivar (`_OBJC_IVAR_$_Class.ivar`); written by the runtime when ivars slide |
| `__objc_methlist` (`__TEXT`) | Relative method lists (§2.4), read-only |
| `__objc_methname`, `__objc_methtype`, `__objc_classname` (`__TEXT`) | Strings |

Apple's current linker also merges a category into its class when both are
in the same image, and turns method lists into relative lists; both forms
must be accepted.

### 2.2 Class object (5 words)

| Word | Compiler writes | Ycode runtime use |
|---|---|---|
| 0 `isa` | Metaclass | Same |
| 1 `superclass` | Superclass or 0 for a root | Same |
| 2 `cache` | `&_objc_empty_cache` | Pointer to the class's method cache (§5) |
| 3 `vtable` | 0 | **Fast flags and instance size** (§4.1) |
| 4 `data` | `class_ro *` (bits 0–1: Swift flags) | After realization: `ClassRW *`, Swift bits kept |

### 2.3 `class_ro`

`u32 flags; u32 instanceStart; u32 instanceSize; u32 reserved;
ivarLayout; name; baseMethods; baseProtocols; ivars; weakIvarLayout;
baseProperties` (pointers). Flags: `1<<0` metaclass, `1<<1` root,
`1<<2` has C++ structors (`.cxx_construct`/`.cxx_destruct`), `1<<5`
exception, `1<<7` ARC, `1<<8` C++ destructor only.

### 2.4 Method lists

Header `{ u32 entsizeAndFlags; u32 count }`, then `count` entries.

- **Classic** (entsize 24): `{ SEL name; const char *types; IMP imp }`;
  `name` points at the name string (not yet unique).
- **Relative** (flag `0x8000_0000`, entsize 12): three signed 32-bit
  offsets, each from the address of the field itself: `name` → a selector
  reference slot (an 8-byte `SEL` in `__objc_selrefs`), `types` → string,
  `imp` → code (0 in protocol method lists).
- Bits `0x7FFF_0000` other than the relative flag are not used by clang.

### 2.5 Other structures

| Structure | Layout |
|---|---|
| ivar list | `{ u32 entsize (32); u32 count }` + `{ u32 *offset; name; type; u32 alignment (log2); u32 size }` |
| property list | `{ u32 entsize (16); u32 count }` + `{ name; attributes }` |
| protocol list | `{ u64 count }` + `count` protocol pointers |
| protocol | `isa (0); name; protocols; instanceMethods; classMethods; optionalInstanceMethods; optionalClassMethods; instanceProperties; u32 size; u32 flags; extendedMethodTypes; demangledName; classProperties` |
| category | `name; cls; instanceMethods; classMethods; protocols; instanceProperties; classProperties` (the last only when the image-info flag `1<<6` is set) |
| `struct objc_super` (`objc/message.h`) | `{ id receiver; Class super_class }` |

### 2.6 Calls clang emits

`objc_msgSend` (via linker stubs `objc_msgSend$<selector>`), `objc_msgSendSuper2`
(`super_class` = the *current* class; the runtime starts at its
superclass), `objc_alloc`, `objc_alloc_init`, `objc_allocWithZone`,
`objc_opt_new`, `objc_opt_self`, `objc_opt_class`,
`objc_opt_isKindOfClass`, `objc_opt_respondsToSelector`, and under ARC
`objc_retain`, `objc_release`, `objc_autorelease`, `objc_storeStrong`,
`objc_retainAutoreleasedReturnValue`, `objc_claimAutoreleasedReturnValue`,
`objc_unsafeClaimAutoreleasedReturnValue`, `objc_autoreleaseReturnValue`,
`objc_retainAutoreleaseReturnValue`, `objc_retainAutorelease`,
`objc_retainBlock`, the weak family (`objc_initWeak`, `objc_storeWeak`,
`objc_loadWeakRetained`, `objc_loadWeak`, `objc_destroyWeak`,
`objc_copyWeak`, `objc_moveWeak`), `objc_autoreleasePoolPush/Pop`,
`objc_getProperty`, `objc_setProperty*`, `objc_copyStruct`,
`objc_sync_enter/exit`, `objc_enumerationMutation`, and the personality
`__objc_personality_v0`.

ARC's return-value hand-off: on arm64 clang puts the marker instruction
`mov x29, x29` (`0xAA1D03FD`) directly after a call whose result it passes
to `objc_retainAutoreleasedReturnValue` (§8.3).

## 3. Objects and the `isa` word

An object starts with its `isa` word. Ycode uses a **packed isa** for
objects it allocates and accepts a **plain isa** (a bare class pointer,
bit 0 clear) for everything else (class objects, static objects):

| Bits | Field |
|---|---|
| 0 | `PACKED` (1 = this layout) |
| 1 | `HAS_ASSOC`: associated objects were set |
| 2 | reserved (0) |
| 3–46 | Class pointer: `isa & 0x0000_7FFF_FFFF_FFF8` |
| 47 | `WEAKLY_REFERENCED` |
| 48 | `DEALLOCATING` |
| 49 | `HAS_SIDETABLE_RC`: part of the count is in the side table |
| 50–63 | `EXTRA_RC`: retain count − 1 (14 bits) |

`objc_msgSend` masks with the same constant for both layouts, so it never
tests the layout. The mask is exported as `objc_debug_isa_class_mask` for
code that inspects isa words. A class whose address does not fit the mask
(never seen on arm64 Linux or macOS user space) gets plain-isa instances.

Retain count = 1 + `EXTRA_RC` + side-table count. Plain-isa objects keep
their whole extra count in the side table (§7.2).

## 4. Classes

### 4.1 Fast flags (word 3)

| Bits | Meaning |
|---|---|
| 0 | `REALIZED` |
| 1 | `INITIALIZED` (`+initialize` done) |
| 2 | `INITIALIZING` |
| 3 | `META` |
| 4 | `CUSTOM_RR`: instances override a retain/release-family method; ARC entry points message them |
| 5 | `CUSTOM_AWZ`: the class overrides `+alloc`/`+allocWithZone:`; `objc_alloc` messages it |
| 6 | `CUSTOM_CORE`: overrides one of `+new`, `-self`, `-class`, `-isKindOfClass:`, `-respondsToSelector:` (and class-side versions); the `objc_opt_*` entry points message it |
| 7 | `HAS_CXX_DTOR` (`.cxx_destruct` in the hierarchy) |
| 8 | `HAS_CXX_CTOR` (`.cxx_construct` in the hierarchy) |
| 9 | `ROOT` |
| 10 | `PLAIN_ISA_INSTANCES` |
| 11 | `CONSTRUCTING` (between `objc_allocateClassPair` and `objc_registerClassPair`) |
| 12 | `CUSTOM_INIT`: the class overrides `-init` (else `objc_alloc_init` and `objc_opt_new` skip the message) |
| 13 | `CUSTOM_DEALLOC`: the class overrides `-dealloc` (else the last release calls `_objc_rootDealloc` directly) |
| 32–63 | Instance size in bytes (word-aligned, minimum 16) |

The retain/release and allocation fast paths read only this word after the
`isa`.

### 4.2 Realization

A class is realized on first need (first message, `objc_getClass`,
introspection, a subclass's realization). Under the runtime lock:

1. Realize the superclass.
2. If `instanceStart` < the superclass's instance size, **slide** the
   ivars: copy `class_ro` into writable memory, add the difference (rounded
   up to the largest ivar alignment) to each ivar offset variable,
   `instanceStart` and `instanceSize`.
3. Build `ClassRW`: the method table (§4.3) from the base list and the
   categories waiting for this class (§4.4); protocols; properties; the
   subclass link.
4. Store `ClassRW` in word 4 and the fast flags in word 3 (store-release:
   readers that see `REALIZED` see the rest).
5. Realize the metaclass (word 0) the same way. The root metaclass's
   superclass is the root class itself, which is already realized at this
   point, so recursion ends.
6. Compute the `CUSTOM_*` and `HAS_CXX_*` flags by method lookup (§4.3) of
   the relevant selectors, comparing the result with `NSObject`'s own IMP.
   A subclass of a custom class is custom.

### 4.3 Method table and lookup

Each realized class owns its methods as Ycode `MethodEntry { SEL name;
const char *types; IMP imp }` records (the `Method` type of the API, taken
from a bump arena: classes are never unloaded), in priority order:
categories, last attached first, then the base list. A
second array of `(SEL, MethodEntry *)` pairs, sorted by `SEL` with
duplicates removed (the first in priority order wins), is searched by
binary search. Lookup walks the superclass chain. Changing a class's
methods (category, `class_addMethod`, `class_replaceMethod`) rebuilds its
arrays and flushes the caches of the class and its subclasses (§5.3);
`method_setImplementation` and `method_exchangeImplementations` flush every
cache.

### 4.4 Categories

For each category in `__objc_catlist`: if its class is realized, attach
now (instance methods to the class, class methods to the metaclass,
protocols and properties likewise); otherwise keep it in the pending map
under the class pointer and attach during realization. A category whose
class is 0 (weak-linked and missing) is skipped.

Attaching to a realized class merges the category's records into the
sorted table in place (binary search per method: an equal SEL is replaced,
the category wins; the rest go in with one backward merge; the table keeps
headroom so successive categories do not reallocate). Caches are flushed
only where needed: in the class's subtree, a cache that holds none of the
new selectors cannot return a stale IMP and is kept. The fast flags are
recomputed only when a new selector is one that affects them (a one-word
filter rejects the others).

### 4.5 `+initialize`

The first message to a class (instance or class side) that reaches the
lookup slow path initializes the class: the superclass first, then
`objc_msgSend(cls, @selector(initialize))` (so an inherited `+initialize`
runs again for the subclass, as documented). A per-class `INITIALIZING`
state with the owning thread lets that thread message the class while
other threads wait on a condition variable. Caches are filled only for
initialized classes, so messages sent during `+initialize` take the slow
path.

### 4.6 Selectors

A `SEL` is the address of the first registered copy of the name string.
The selector table is a hash set of name pointers keyed by content
(64-bit FNV-1a). Each image's `__objc_selrefs` slots are rewritten to the
unique `SEL` before its classes are read. `sel_registerName` copies names
that are not in an image.

### 4.7 Protocols

Protocols are registered by name (first wins); `__objc_protorefs` slots
are rewritten to the canonical protocol; a protocol whose `isa` is 0 gets
the `Protocol` class. Conformance walks the protocol lists of the class,
its categories and its superclasses, and each protocol's own list.

## 5. The method cache and `objc_msgSend`

### 5.1 Cache layout

```
struct Cache { u64 mask; u32 occupied; u32 reserved; Bucket buckets[mask + 1]; }
struct Bucket { SEL sel; IMP imp; }        // 16 bytes
```

`_objc_empty_cache` is a `Cache` with mask 0 and one empty bucket; every
unrealized or flushed class points at it. The bucket index is
`(sel ^ (sel >> 7)) & mask`; collisions probe the next bucket, wrapping.

### 5.2 `objc_msgSend` (arm64)

```
x0 ≤ 0 (signed)?          → nil / tagged path
x16 = [x0] & ISA_MASK      ; class
x10 = [x16 + 16]           ; cache
x11 = [x10]                ; mask
x12 = (x1 ^ x1>>7) & x11
loop: x9, x17 = bucket[x12]
      x9 == x1 && x17 != 0 → br x17
      x9 == 0              → slow path
      x12 = (x12 + 1) & x11
```

The nil path returns 0 in `x0`, `x1` and `d0`–`d3`. `objc_msgSendSuper`
loads `receiver` and `super_class` from the `objc_super`;
`objc_msgSendSuper2` loads the superclass of `super_class` and then
searches it. The slow path saves `x0`–`x8` and `q0`–`q7`, calls the Rust
lookup with `(receiver, sel, class)`, restores, and branches to the IMP.

### 5.3 Concurrency

Readers take no lock. Writers hold the runtime lock and:

- Fill an empty bucket by storing the IMP, then the SEL with
  store-release. A reader whose `ldp` sees the new SEL with a stale (zero)
  IMP falls through to the slow path (the `x17 != 0` test).
- Never change a filled bucket. Growth (at three quarters full, doubling,
  up to 2¹⁶ buckets, then reset) and flushes publish a **new** cache with a
  store-release of the pointer in word 2. Address dependency orders the
  reader's loads from the new cache after its load of the pointer.
- Each probe sequence ends in its own local branch to the slow path, so
  that `-dead_strip` (which treats every global label as an atom) sees the
  reference.
- Do not free a replaced cache while a reader might still probe it. Wave 1
  keeps replaced caches on a garbage list (bounded by about twice the
  final cache size per class, because growth doubles); reclaiming them
  with a quiescence check is wave 2.

### 5.4 Forwarding

Lookup failure: send `+resolveInstanceMethod:` (or `+resolveClassMethod:`
for metaclasses) once; if the method still does not exist, the cache gets
`_objc_msgForward`. `_objc_msgForward` saves the arguments, asks
`-forwardingTargetForSelector:` while the default forward handler is
installed, and re-sends to a different non-nil target with the original
arguments; otherwise it jumps to the forward handler
(`objc_setForwardHandler`), whose default prints
`+[C sel]: unrecognized selector sent to class 0x…` (or `-[C sel]: …
instance 0x…`) and aborts.

## 6. Allocation and deallocation

- `_objc_rootAllocWithZone`/`class_createInstance`: `calloc` of the instance
  size, packed isa, then `.cxx_construct` (superclass first) when the class
  has one.
- `objc_alloc(cls)`: if the class is realized, initialized and not
  `CUSTOM_AWZ`, allocate directly; otherwise `[cls alloc]`.
  `objc_alloc_init` adds `[obj init]`; `objc_opt_new` uses the direct path
  plus `-init` unless `CUSTOM_CORE`.
- `-[NSObject dealloc]` → `object_dispose`: fast path `free` when the isa is
  packed and has no weak, associated or side-table state and the class has
  no `.cxx_destruct`; otherwise `objc_destructInstance` (C++/ARC ivar
  destructors subclass-first, associated objects, weak clearing, side-table
  entry) then `free`.

## 7. Reference counting

### 7.1 Packed-isa fast paths

Both fast paths are arm64 assembly leaf functions (no frame); every other
case branches to the Rust slow path, which rechecks from the start.

- `objc_retain(obj)`: return for nil or tagged; load the isa; plain isa →
  §7.2; `CUSTOM_RR` → `[obj retain]`; else CAS `isa + (1<<50)`. A carry out
  of bit 63 (`EXTRA_RC` full) moves half of the inline count to the side
  table and sets `HAS_SIDETABLE_RC`.
- `objc_release(obj)`: if `EXTRA_RC` > 0, CAS-subtract with release
  ordering. If it is 0: with `HAS_SIDETABLE_RC`, borrow up to half the
  inline capacity from the side table; else set `DEALLOCATING` (acquire
  and release) and send `-dealloc`.
- `retainCount` = 1 + `EXTRA_RC` + side count. `_tryRetain` fails on
  `DEALLOCATING`.

### 7.2 Side table

64 stripes, each a lock (§10.3) and a hash map from object address to
`{ extra count; deallocating; weak referrer list }`. The stripe is chosen by
`(addr >> 4) ^ (addr >> 9)`. Plain-isa objects count only here. Class
objects (whose class is a metaclass) are never counted: retain and release
of a class do nothing.

### 7.3 Blocks

`libSystem`'s `_NSConcreteStackBlock`, `_NSConcreteMallocBlock` and
`_NSConcreteGlobalBlock` are 32-word arrays. At start-up the runtime turns
the first five words of each into a class object (`__NSStackBlock__`,
`__NSMallocBlock__`, `__NSGlobalBlock__`, subclasses of `NSObject`, with
metaclasses it allocates) whose `retain`/`copy` call `_Block_copy` and
whose `release` calls `_Block_release`, so blocks are objects for ARC and
messaging. `objc_retainBlock` is `_Block_copy`.

## 8. Autorelease pools

### 8.1 Pages

Per thread, a doubly linked list of 4 KB pages: header `{ next free slot,
parent, child, thread, depth }`, then object slots. The hot page is in a
thread-specific-data slot read inline from `TPIDRRO_EL0` (§10.2).

- `objc_autoreleasePoolPush` stores a 0 boundary and returns its slot
  address as the token.
- `objc_autorelease(obj)` stores `obj` in the next slot (new page when
  full).
- `objc_autoreleasePoolPop(token)` releases slots from the top down to
  the token, crossing pages, and keeps one empty child page for reuse.
- A thread-exit destructor pops everything.

### 8.2 `_objc_autoreleasePoolPrint`

Prints the pool stack to standard error.

### 8.3 Return-value hand-off

`objc_autoreleaseReturnValue(obj)` reads the instruction at its return
address. If it is the marker `mov x29, x29`, or a `bl` whose target is
`objc_claimAutoreleasedReturnValue`, `objc_retainAutoreleasedReturnValue`
or `objc_unsafeClaimAutoreleasedReturnValue` (directly, or through a
linker stub `adrp x16, slot@PAGE; ldr x16, [x16, slot@PAGEOFF]; br x16`
whose slot holds one of them: current Apple linkers drop the marker and
emit this form), it sets the thread's hand-off flag and returns `obj`
without autoreleasing (a 256-entry memo of return addresses keeps the
decoding off the common path);
`objc_retainAutoreleasedReturnValue` and
`objc_claimAutoreleasedReturnValue` then take the flag instead of
retaining (`objc_unsafeClaimAutoreleasedReturnValue` releases instead).
Without the marker both sides do the plain autorelease and retain.
`objc_getProperty` enters through an assembly shim that passes its return
address, so an atomic getter that tail-calls it hands off too.

## 9. Weak references, associated objects, `@synchronized`

- **Weak:** the side-table entry of the referent holds the addresses of
  its weak variables. `objc_storeWeak` locks the stripes of the old and
  new referents (address order), re-checks the variable, unregisters,
  registers (unless the new referent is deallocating; a `CUSTOM_RR` class
  is asked `-allowsWeakReference` first) and sets `WEAKLY_REFERENCED`.
  `objc_loadWeakRetained` locks the referent's stripe, re-checks the
  variable and try-retains. Deallocation clears every registered variable
  that still points at the object.
- **Associated objects:** one lock and a map object → `(key, policy,
  value)` list. Policies (`objc/runtime.h`): assign 0, retain-nonatomic 1,
  copy-nonatomic 3, retain 01401, copy 01403. Values are released after
  the lock is dropped. `HAS_ASSOC` tells deallocation to look.
- **`@synchronized`:** `objc_sync_enter/exit` use a recursive lock per
  object (owner thread, depth, `os_unfair_lock`), taken from 64 striped
  lists; entries are reused once unused. Return `OBJC_SYNC_SUCCESS` 0, or
  `OBJC_SYNC_NOT_OWNING_THREAD_ERROR` −1 from an exit by a non-owner.

## 10. Process integration

### 10.1 Loading

libobjc depends on libSystem only. Its initializer (a `__mod_init_func`
entry) registers the built-in selectors and classes, then calls
`_dyld_register_func_for_add_image`; Ycode's dyld calls back for every
image already loaded and for each image `dlopen` adds later
(`dyld.md` §7.2). For each image with `__objc_imageinfo`, under the
runtime lock: selector references, protocols, protocol references,
classes into the name map, categories; then, outside the lock, `+load`
for the classes in `__objc_nlclslist` (superclasses first, each class
once) and then for the categories in `__objc_nlcatlist`. Because dyld
runs libobjc's initializer before those of the images that depend on
it, `+load` runs before their C++ static initializers, as on a Mac.

Writes into a read-only segment (should a linker ever put selector
references there) are preceded by `mprotect` to read-write and followed
by restoring the protection.

### 10.2 Thread-specific data

The runtime creates two `pthread` keys: the autorelease hot page (with a
destructor) and the hand-off flag. On Darwin a key's value is the word
at `TPIDRRO_EL0 + 8 × key` (`libsystem.md`, `host-library-init.md` §3);
the runtime reads and writes it inline after checking at start-up that
the inline slot and `pthread_getspecific` agree (else it uses the
functions).

### 10.3 Locks

An inline lock for the runtime lock and the side-table stripes: one
32-bit word (0 free, 1 held, 2 held with waiters), an inline
compare-and-swap to take it, a short spin, then the kernel's
compare-and-wait (`__ulock_wait`/`__ulock_wake` with `UL_COMPARE_AND_WAIT`
1, which both Darwin and Ycode's libsystem_kernel export).
`os_unfair_lock` (libsystem_platform) for the selector table,
associations and `@synchronized`; a `pthread_mutex_t` and `pthread_cond_t`
for `+initialize` waits.

## 11. Build

- Crate `ycode/MacUserland/objc/` (`ycode-objc`): `no_std`,
  `crate-type = ["staticlib"]`, `panic = "abort"`, fat LTO, one codegen
  unit, target `aarch64-apple-darwin`.
- `MacUserland/build.sh` (step `build_objc`): `cargo build --release`,
  extract the archive members, strip their platform tags (as for the C
  objects), link with `ld64.lld` as `/usr/lib/libobjc.A.dylib`
  (`-dylib`, chained fixups) against libSystem's `.tbd`, exporting only
  the names in `objc/exports.txt`. Skipped with a message when `cargo` is
  missing (`CARGO=` overrides).
- Linux needs a Rust toolchain with the `aarch64-apple-darwin` standard
  library (`rustup target add aarch64-apple-darwin`); no Apple tools.
- For benchmarking on a Mac, `objc/bench/build-mac.sh` links the same
  static library into a native dylib against the Mac's libSystem.

## 12. Benchmarks

`objc/bench/bench.m` (generated classes from `gen.py`, built by
`bench/build.sh`, compared by `bench/compare.py`) measures, each as the
median of 5–7 in-process trials in nanoseconds per operation; the tables
take the median over alternating process runs:

| Benchmark | Operation |
|---|---|
| send, cached | `[obj nop]` |
| send, uncached | first send of each of 200 selectors to each of 50 fresh classes |
| send, super | `objc_msgSendSuper2` to an inherited method |
| send, nil | `objc_msgSend(nil, sel)` |
| class realization | first message to each of 1,000 classes (realize + initialize + fill) |
| class creation | `objc_allocateClassPair` + `objc_registerClassPair` |
| method lookup | `class_getInstanceMethod` of a method 5 levels up; `class_getMethodImplementation` (cached) |
| retain/release | `objc_retain` + `objc_release` |
| alloc/init/release | `objc_alloc_init` + `objc_release` |
| autorelease pool | push, one autorelease, pop; and per object for 1,000 objects |
| weak | `objc_storeWeak` alternating referents; `objc_loadWeakRetained` + release |
| category attachment | `dlopen` of a bundle with 1,000 categories × 4 methods on realized classes, minus `dlopen` of the same bundle with its sections renamed so that no runtime reads them (identical mapping and binding); per category, 5 bundles |
| category first send | afterwards, the first send of a category method to each of the 1,000 classes |

Baselines: the same binary run natively on the Mac against the Mac's
shipped `libobjc` (built by Apple from objc4) and against Ycode's runtime
loaded natively on the Mac (the benchmark's `__objc_*` sections renamed to
`__ycob_*` so the Mac's own runtime ignores them, which the bench build of
Ycode's runtime accepts); and Ycode's runtime under `ycode-simd --macos` on
the arm64 Linux host. Results: §14.

## 13. Not yet implemented

Exceptions beyond printing and aborting (`objc_exception_throw` needs an
unwinder in libSystem; `__objc_personality_v0` is present so binaries
load); `imp_implementationWithBlock`; tagged-pointer class registration
(tagged receivers behave as nil); `objc_setHook_*`; `objc_copyImageNames`
and `class_getImageName`; ivar layouts for scanning; `class_setIvarLayout`;
`objc_duplicateClass`; protocol construction (`objc_allocateProtocol`);
reclaiming replaced caches (§5.3); Swift classes whose `class_ro` has a
Swift metadata initializer (§15); the Rust toolchain in the Flatpak build (the build skips libobjc without cargo);
`_Block_object_assign` in libSystem does not yet retain captured objects
through `objc_retain` (blocks that capture objects under ARC need it).

## 14. Results (wave 1, 2026-11-05)

Conformance: `run-tests.sh` — the five programs print exactly what they
print with the Mac's own runtime: 10/10 on the Mac (Mac runtime and
Ycode's, native), 5/5 under `ycode-simd --macos` on the arm64 Linux host.

Benchmarks. Mac: Apple M3 Max, macOS 27.2; "Mac runtime" is the
`libobjc.A.dylib` the Mac ships (Apple's build of objc4), **not** objc4
built from source; both columns run the same benchmark object code on the
same machine, median of 7 alternating process runs. The Mac was shared
with other build jobs (load average 9–30), which mostly affects the
millisecond-scale category measurements. Linux: the arm64 host (Neoverse
V3AE) under `ycode-simd --macos`, shared (load average 8–23), median of 3
runs; it has no objc4 baseline.

| Benchmark | Mac runtime (ns) | Ycode, Mac native (ns) | Ycode / Mac | Ycode, ycode-simd (ns) |
|---|---:|---:|---:|---:|
| send, cached | 1.67 | 1.40 | 0.84 | 1.63 |
| send, nil | 1.67 | 1.40 | 0.84 | 1.55 |
| send, super | 1.67 | 1.41 | 0.84 | 1.48 |
| send, uncached (first send of a selector) | 85.00 | 55.50 | 0.65 | 81.98 |
| class realization (first message) | 385.00 | 290.00 | 0.75 | 857.71 |
| class creation and registration | 415.00 | 325.00 | 0.78 | 672.71 |
| `class_getInstanceMethod`, 5 levels up | 49.61 | 4.45 | 0.09 | 16.05 |
| `class_getMethodImplementation` (cached) | 3.10 | 1.40 | 0.45 | 1.54 |
| `objc_retain` + `objc_release` | 4.25 | 4.29 | 1.01 | 21.03 |
| `objc_alloc_init` + `objc_release` | 22.35 | 19.71 | 0.88 | 61.92 |
| pool push, one autorelease, pop | 8.39 | 7.74 | 0.92 | 38.69 |
| autorelease, per object (1,000 per pool) | 8.17 | 4.65 | 0.57 | 26.85 |
| `objc_storeWeak` × 2 | 33.12 | 13.45 | 0.41 | 74.30 |
| `objc_loadWeakRetained` + release | 5.43 | 5.05 | 0.93 | 30.12 |
| category attachment, per category | 106.00 | 117.00 | 1.10 | 216.29 |
| first send after attachment, per class | 40.00 | 36.00 | 0.90 | 74.92 |

Category attachment, measured separately over 20 alternating runs (only
that benchmark): Mac runtime median 103 ns (quartiles 98–115), Ycode 94 ns
(74–108); first send after attachment 40 ns (40–42) and 35 ns (34–36).
Across all measurement sets the attachment ratio ranged from 0.9 to 1.25:
call it a tie within the noise of a shared machine.

Reading the table: retain/release is a tie (1.01 is within run-to-run
noise): both runtimes are bound by the latency of one atomic
read-modify-write each (an LL/SC variant measured the same on both
machines, so the CAS form stays). Everything else is faster. The Linux
column is slower for memory-heavy cases because the guest's allocation
and locking go through Ycode's libSystem (which maps memory with VM exits
and has one allocator lock) and because atomics cost more on that core
(about 10 ns per read-modify-write), not because of the runtime's own
code: cached sends cost the same as on the Mac.

## 15. The Swift runtime's entry points (stage B)

With Objective-C interop, the Swift runtime (`swift-runtime.md` §2) makes
every Swift class an Objective-C class and calls these functions. Their
names and C signatures are the ones the open Swift runtime declares;
their behavior here is Ycode's, from how that runtime uses them
(`ycode/MacUserland/objc/src/swift.rs`):

| Function | Ycode's behavior |
|---|---|
| `objc_addLoadImageFunc(fn)` | Calls `fn(header)` at once for every image the runtime has seen (with or without Objective-C metadata), then for each image added later, after the runtime has read its classes. The Swift runtime scans each image's Swift sections from here |
| `objc_readClassPair(cls, info)` | Registers (by name, when it has one) and realizes, in place, a class pair the Swift runtime built at run time (a generic class instance); returns `cls` |
| `_objc_realizeClassFromSwift(cls, previously)` | Moves the categories waiting for `previously` (a class stub) to `cls`, then registers and realizes `cls`; returns it |
| `class_setSuperclass(cls, super)` | Re-parents the class and its metaclass, fixes the subclass lists, flushes every cache; returns the old superclass |
| `objc_setHook_getClass(new, &old)` | `objc_getClass`, `objc_lookUpClass`, `objc_getRequiredClass` and `objc_getMetaClass` ask the hook for names the name map lacks (Swift's mangled class names); a class it returns is realized. The first `old` is a hook that answers "not found" |
| `objc_setHook_lazyClassNamer(new, &old)` | `class_getName` of a class whose `class_ro` has no name (a generic instance) asks the hook once and stores the answer in the `class_ro` (compare-and-swap) |
| `objc_setHook_getImageName(new, &old)`, `class_getImageName(cls)` | `class_getImageName` asks the hook; the first `old` answers from `dladdr` of the class |

Two details of the Swift class layout matter and need no change: the
Swift bits in the low two bits of word 4 are kept across realization
(§2.2), and word 3 (the fast flags here) is a word the Swift runtime
leaves to the Objective-C runtime. A Swift class name may be absent at
registration; such a class is not entered in the name map (§4.6) and is
found through the get-class hook.

Not done: a class whose `class_ro` carries the Swift metadata-initializer
flag (classes with resilient ancestry) would need its initializer called
before realization, and that initializer calls back into
`_objc_realizeClassFromSwift`, which takes the runtime lock the caller
holds. None of the stage-B programs has such a class.

## Evidence

| Claim | Level (AGENTS.md rule 4) |
|---|---|
| §2 section names, structure layouts, method-list formats, emitted calls, ARC marker | 1 (open-source clang's Objective-C code generation) and 2 (Ycode's own object files compiled with clang and inspected with `otool`) |
| Public function signatures, policy constants, `objc_super`, `OBJC_SYNC_*` | 1 (macOS SDK public headers) |
| Message, `+initialize`, `+load`, forwarding and memory-management semantics | 1 (Apple's public programming guides and header comments) |
| Mach-O load commands, `_dyld_register_func_for_add_image`, TSD at `TPIDRRO_EL0` | 1 (public headers; `dyld.md`, `host-library-init.md`) |
| The linker-stub form of the return-value hand-off (`bl` to a stub of `objc_claimAutoreleasedReturnValue`, no marker) | 2 (Ycode's own test programs, linked by the Mac's linker, disassembled with `otool`) |
| Expected outputs of the conformance tests | 3 (Ycode's own programs run against the Mac's runtime) |
| `__ulock_wait`/`__ulock_wake`, `UL_COMPARE_AND_WAIT` | 1 (xnu's public `sys/ulock.h`; Ycode's `syscalls-map.tsv`) |
| §15 function names and signatures; how the Swift runtime uses them | 1 (the open Swift runtime source, Apache-2.0) |
| Everything else (isa layout, cache, side tables, flags, page layout, locks) | Ycode design |
