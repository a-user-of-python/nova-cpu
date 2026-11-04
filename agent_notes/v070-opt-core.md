# NOVA v0.0.70 — Lane OPT-CORE: VM core optimization (Phase 2)

Date: 2026-11-04. Files edited (only these two, in place, no commits):
`vm-app/NovaVM/VM/NovaMemory.swift`, `vm-app/NovaVM/VM/NovaCPU.swift`.
Verified against the pre-optimization snapshot in `tools/harness/baseline/`
(`diff -u` shows exactly the changes below and nothing else). No Swift
toolchain on this VM — the CI harness gate (`swiftc -O`, goldens) is the
compile + behaviour check.

**Endianness (verified from the original code):** the original
read16/32/64 loops assemble `byte[addr+0]` as the least significant byte
and the write loops store LSB first — guest memory is **little-endian
(LSB-first)**. The new memcpy-based accessors copy the host representation
of the value, which is the same byte order because every supported host
(arm64, x86_64) is little-endian too.

---

## Changes

### 1. NovaMemory.swift:42–50, 67–69 — precomputed range limits

Added three private stored properties `maxStart16/32/64 = totalSize - 2/4/8`,
set in `init` from the already-clamped size. The init clamp guarantees
`totalSize ∈ [64 MB, 1 GB]`, so the subtractions can never underflow.

*Semantics:* none — pure precomputation of constants the checks below use.

### 2. NovaMemory.swift:81–182 — memory fast path (task item a)

`read16/32/64` and `write16/32/64` (and the guards in `read8/write8`):

- **Before:** `checkRead/checkWrite` ran a three-part guard
  (`addr < S`, `size <= S`, `addr &+ size <= S`), then the value was
  assembled/disassembled byte-by-byte (up to 8 subscripted accesses, each
  with Swift's own bounds check).
- **After:** ONE comparison per access — `addr <= maxStartN` for
  multi-byte, `addr < sizeU64` for single-byte — then a single
  constant-size `memcpy` of the value's bytes (2/4/8) through
  `bytes.withUnsafeBufferPointer` / `withUnsafeMutableBufferPointer`,
  fetched fresh per access and never stored across calls. Under `-O` the
  constant-size memcpy lowers to one unaligned load/store. All accessors
  keep `@inline(__always)`, their exact signatures, and their throw types
  (`loadAccessFault` / `storeAccessFault`).
- The private helpers `checkRead/checkWrite` were removed: they were
  `private` (file-scoped), used only by these accessors — `grep` confirms
  zero remaining references in the repo. No public/internal entry point
  changed signature (verified by signature diff against the baseline:
  the only deltas are these two private removals and the three added
  helpers in §4; NovaCPU's signatures are identical).

*Why semantics are preserved:*

- **Range equivalence:** for access size n ∈ {2,4,8} and RAM size S,
  `addr <= S − n` ⟺ `addr < S && addr + n <= S`, because `addr + n`
  cannot wrap in the passing case (addr ≤ S ≤ 1 GB). That is exactly the
  old guard for these sizes. Model-checked exhaustively over boundary
  addresses (0, S−9…S+1, the MMIO base, 2⁶⁴−16…2⁶⁴−1) plus 200 k random
  64-bit addresses per size: old and new guards agree on every input.
  So an access faults iff any of its bytes is out of bounds — including
  accesses spanning the RAM/MMIO boundary or partially out of RAM.
- **MMIO routing unchanged:** MMIO-page addresses
  (≥ `0xFFFF_FFFF_FFFF_0000`) fail the new check exactly as they failed
  the old one, so plain accessors still fault on that page and routing
  stays solely in NovaCPU's LOAD64/LOADU8/STORE8/STORE64 cases (untouched
  conditions, see §3). Unlisted-MMIO read-0 / write-ignore behaviour
  lives in `mmioRead/mmioWrite`, which were not touched at all.
- **Atomicity:** the check still runs before any byte is touched — a
  faulting access modifies nothing, a passing access transfers all its
  bytes, exactly as the checked byte-wise code.
- **Endianness:** LSB-first, per the header above.

*Fast-path fallback conditions:* there is no separate slow path inside
these accessors and none is needed — the old code's only "path" was
check-then-bytes; the new code is check-then-memcpy, and the check's
failure branch is the identical throw. Addresses outside RAM (including
the whole MMIO page) take the throw branch, as before.

### 3. NovaCPU.swift:102–~470 (`step()`) — fetch/dispatch (task item b)

- **`let mem: NovaMemory = memory` at the top of `step()`** (line 110):
  the timer check, opcode fetch and all 51 `memory.` accesses inside
  `step()` now go through one resolved reference instead of re-unwrapping
  the implicitly-unwrapped `memory` property per access. Pure reference
  localization: the memory object cannot be swapped mid-instruction
  (run() and the MMIO handlers operate on the same instance), and every
  access still lands on the same object in the same order. The timer
  model at the top of `step()` — countdown per instruction, throw
  `timerInterrupt` when it reaches 0, before opcode fetch — is byte-for-
  byte the same logic, only `mem.` instead of `memory.`.
  `dpush/dpop/cpush/cpop` and `run()` were NOT localized (outside
  `step()`; they are separate call sites and `run()`'s trap/vector logic
  is untouched).
- **Opcode fetch** (line 137) stays `try mem.read8(pc); pc &+= 1;
  cycle &+= 1` — but `read8` is now the single-comparison fast path, and
  every operand fetch (`read16/read32/read64` in PUSH/JMP/CALL/branch/
  CSR cases, `read64/write64` in LOADL/STORL/LOADARG and the LOAD/STORE
  opcodes) gets the same one-check + single-memcpy path from §2. That
  removes the old per-operand cost of 3 guard comparisons plus up to 8
  individually bounds-checked byte accesses. `cycle` still increments by
  exactly 1 per executed instruction, in the same place; RDCYCLE/RDTIME
  untouched.
- The giant switch, per-case `pc &+=` amounts, `tval` assignments, trap
  vectors and the MMIO range tests (`addr >= 0xFFFF_FFFF_FFFF_0000`) are
  all unchanged — the diff inside `step()` is only `memory.` → `mem.`
  plus comments.

### 4. NovaMemory.swift:216–282 — bulk host↔guest helpers (task item c)

**Finding:** the file/net MMIO payload copying does NOT live in
NovaMemory.swift. It lives in `NovaVMEngine.swift` (`handleNetGet`,
`handleFileCommand` — byte-at-a-time `read8`/`write8` + `try?` loops),
mirrored in `tools/harness/main.swift`. Those files are outside this
lane, so the handlers were not edited; instead NovaMemory exposes the
bulk helper for the app lane to adopt. Exact API (all internal, i.e.
same-module, matching the rest of NovaMemory):

```swift
@discardableResult
func storeHostBytes(_ hostBytes: [UInt8], at addr: UInt64) -> Int

@discardableResult
func storeHostBytes(_ data: Data, at addr: UInt64) -> Int

func loadHostBytes(from addr: UInt64, count: Int) -> [UInt8]
```

Semantics, chosen to reproduce the existing byte loops exactly:

- `storeHostBytes` — one memcpy of the payload prefix that lies inside
  RAM; returns the number of bytes actually written. Matches the loops'
  `try? write8` behaviour: in-RAM bytes written, out-of-RAM bytes
  (including any MMIO-page addresses — plain `write8` faults there)
  silently dropped, never routed to `mmioWrite`. Handlers that report
  the full *requested* count (the current file READ / net GET do) keep
  reporting it from their own bookkeeping; the return value is available
  but discardable.
- `loadHostBytes` — one memcpy out of RAM; returns the in-RAM prefix
  starting at `addr` (empty if `addr` is out of RAM or `count <= 0`).
  Matches the loops' stop-at-first-fault (`guard let … else break`)
  behaviour, since the valid range from any start address is contiguous.

Adoption sketch for the app lane (not done here): in `handleNetGet` /
file READ, replace the per-byte write loop with
`_ = memory.storeHostBytes(data, at: bufAddr)` (keeping the existing
`return Int64(n)`); in file LIST, `storeHostBytes(Array(name.utf8) + [0],
at: …)`; in file WRITE, replace the read loop with
`let bytes = memory.loadHostBytes(from: bufAddr, count: count)`. The
NUL-terminated path/URL readers were deliberately left byte-wise in that
sketch: they stop at the first NUL, which a blind bulk copy cannot know
in advance (a bulk read of the max length + scan in the returned array
would also work, but it changes the read pattern for a ≤2 KB string —
not worth it).

### 5. Micro (task item d)

`@inline(__always)` is on all hot accessors (kept from the original) and
the new checks are inlined with them. The §4 bulk helpers are plain
functions on purpose: they run once per MMIO command, not per
instruction, and inlining a two-closure memcpy body buys nothing.

---

## Deliberately NOT optimized

- **Opcode+operand fetch fusion** (one wide checked read for a whole
  instruction): in the original code the opcode is fetched and
  `pc`/`cycle` advance *before* the operand is read, so an operand fault
  leaves fault-visible `pc`/`cycle` past the opcode byte (the harness
  meta records both). Fusing would throw before that advance and change
  observable trap state. Also, a fused fetch sized to the longest
  instruction would fault on trailing bytes a short instruction near the
  end of RAM never touches.
- **`copyBytes` (NovaMemory.swift:184, the MEMCPY opcode):** already a
  single `memmove`. Its guard was left exactly as-is on purpose: its
  zero-count edge semantics (`count == 0` with `src`/`dst == totalSize`
  still throws, because the guard requires `src < sizeU64` etc.) differ
  from the simple range-check form, and rewriting it risks changing a
  guest-visible fault for zero benefit.
- **`loadBytes`:** already a single memcpy with its own truncating
  semantics (`min(data.count, size − address)`); untouched.
- **`dpush/dpop/cpush/cpop` stack-limit checks:** kept separate from the
  RAM range check — they test a different condition (stack limit vs RAM
  bounds) and both must run; neither is redundant.
- **Console/keyboard/MMIO device code, `mmioRead/mmioWrite`, UTF-8
  assembly:** untouched (console batching is the engine lane's target
  per the Phase-1 recon, and it lives outside these two files).
- **The dead `max_steps` config key:** not wired up, per instructions.
  No ISA changes, no JIT, no cycle-semantics changes.

## Risks / what the gate should confirm

- No local Swift toolchain: the memcpy pointer conversions
  (`memcpy(&v, base + i, n)` / `memcpy(base + i, &tmp, n)`) follow the
  same typed-pointer → raw-pointer pattern the file already uses in
  `loadBytes`/`copyBytes` (`memcpy(dp + …, sp, n)`), and the
  `data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in … }` form is
  copied verbatim from `loadBytes`. If swiftc objects to any conversion,
  it will be at those lines (NovaMemory.swift:116–182, 239–282).
- Guest-visible behaviour is expected to be identical on every golden:
  same console bytes, same cycle counts, same halt reasons, including
  the budget-prefix programs (any timing/ordering slip in `step()`
  shows up there first).
