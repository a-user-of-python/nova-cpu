# NOVA v0.0.70 — Lane AGG-A: per-instruction OVERHEAD INVENTORY (Phase 1 escalation)

Date: 2026-11-04. Scope: the CURRENT `vm-app` core (V1 optimized,
golden-gated): `vm-app/NovaVM/VM/NovaCPU.swift` (520 lines) +
`vm-app/NovaVM/VM/NovaMemory.swift` (447 lines). Question: after V1
(one-comparison memory checks + single-memcpy accessors + one IUO
resolution per `step()`), what does ONE executed instruction still pay
for, end to end, through `run()` → `step()` → the giant switch →
`dpush`/`dpop` → `NovaMemory` accessors?

Method: static walk of `NovaCPU.swift:479-519` (`run()`),
`:102-476` (`step()`), `:59-87` (stack primitives) and the
`NovaMemory.swift:111-182` accessors. There is no Swift toolchain on
this VM, so NO cycle counts were measured here; every cost below is a
code-level accounting (loads / stores / calls / branches the emitted
code must perform in `-O`, as far as can be reasoned statically).
Anything quantitative is marked **[estimate]** and is relative, not
absolute: treat "≈N loads" as "the source provably performs N distinct
memory operations on the success path unless the optimizer proves
them redundant", not as a benchmark.

Line refs are to the current `vm-app` files as read today.

---

## 0. The per-instruction skeleton (paid by EVERY opcode)

Before any opcode-specific work, one iteration of `run()` + one call
of `step()` pays all of this:

| # | Item | Where | What it costs on the success path |
|---|---|---|---|
| S1 | `run()` loop bookkeeping | `NovaCPU.swift:481-483, 517` | Load `self.running` (class-property load through `self`), load `steps`, compare `steps < maxSteps`, then after the step: `steps &+= 1` (load/add/store of a stack local — cheap) and loop back. `running` is a stored property of a `final class`, so each check is a real load, not a register resident across the `step()` call (the call can mutate it — WFI does). |
| S2 | `do/catch` frame per step | `NovaCPU.swift:484-516` | `run()` wraps EVERY `step()` in `do/catch`. Swift `throws` on the success path is close to free (error is returned in a dedicated register / checked branch), but the catch must exist, so `step()` can never be a tail call and `run()`'s loop body carries the full trap-dispatch block (`:489-512`) as cold code interleaved with the hot loop. Per-trap cost (not per-step) is item T1 below. |
| S3 | `step()` call itself | `NovaCPU.swift:102` | A non-inlinable method call per instruction: `step()` is a large `throws` method on a class — dynamic dispatch is NOT used (`NovaCPU` is `final`, so the call is direct), but the call/return, argument setup (`self`), and the register spill/reload around a ~370-line function body happen per instruction. The optimizer cannot keep CPU state in registers across this call: every field `step()` touches is a memory location in the `NovaCPU` object. This is the structural reason items S5/S6 exist. |
| S4 | IUO resolution once per step | `NovaCPU.swift:110` | `let mem: NovaMemory = memory` — one load + one implicit-unwrap trap check per step. V1 already reduced this from per-access to per-step; what remains is the single load plus the fact that `mem` itself must then be retained/released or at least kept live across the whole body (ARC traffic is item A2). |
| S5 | Timer countdown work | `NovaCPU.swift:118-127` | Executed BEFORE fetch, every instruction, even when the timer is disabled: load `mem.timerInterval` (property load through the `NovaMemory` class reference), compare `> 0`; load `self.status`, test bit 0. When armed (firmware runs: interval = 100 000): additionally load `mem.timerCount`, decrement, store it back, compare to 0 — 2 more class-property accesses through `mem` per instruction. When the timer fires, `timerCount` is reset and `timerInterrupt` is thrown BEFORE `pc`/`cycle` advance (`:125`) — fault-visible ordering any replacement must mirror. Note the short-circuit: with interval 0 the countdown body is skipped, but the two loads + two tests are not. |
| S6 | `pc` / `cycle` as object properties | `NovaCPU.swift:137-139` and throughout | `pc` and `cycle` are stored `UInt64` properties of `self`. Fetch does: load `pc`, call `read8`, store `pc &+ 1` back, load `cycle`, store `cycle &+ 1` back. Every later `pc &+= 2/4/8` in operand cases is another load/add/store pair through `self`. Nothing can keep either in a register across the `step()` call (S3), and within `step()` every `dpush`/`dpop` call (also a function boundary unless inlined — they are `@inline(__always)`, see D1) can in principle clobber the caller's cached copy, so the compiler re-loads defensively around them. **[estimate]** ≈4–6 property loads/stores for `pc`+`cycle` alone on a no-operand instruction. |
| S7 | Opcode fetch | `NovaCPU.swift:137` → `NovaMemory.swift:111-114` | `read8` is `@inline(__always)`: guard `addr < sizeU64` (one load of `sizeU64` through `mem` + compare) + `bytes[Int(addr)]` — a `ContiguousArray` subscript, which carries Swift's own array bounds check + buffer-pointer load. So the fetch is ≈2 range checks (the accessor's + the array's) and ≈3 loads (size, buffer base, byte) for one byte. No fusion with the operand fetch is possible without changing fault-visible `pc`/`cycle` (V1 note §"Deliberately NOT optimized" — binding here too). |
| S8 | Switch dispatch | `NovaCPU.swift:141-474` | One `switch` over a `UInt8` with ~93 listed cases + `default`. In `-O` this typically lowers to a jump table or a small compare tree — one indirect jump **[estimate: cheapest item on this page]**. The real dispatch cost is not the jump; it is that each case body is cold-separated code that re-establishes all state from object properties (S6, D1) — an interpreter in this shape pays for state re-materialization, not for the branch. |

## 1. Operand fetch (opcodes with immediates / offsets)

| Item | Where | Cost |
|---|---|---|
| O1 | Per-operand checked accessor | e.g. PUSH16 `NovaCPU.swift:148`, JMP `:381`, CALL `:399`, PICK `:182` → `NovaMemory.swift:116-147` |

Each operand fetch is a separate throwing call chain: `read16/32/64`
does ONE range comparison (V1), then `bytes.withUnsafeBufferPointer {
buf in … memcpy(&v, base + i, n) }` — a non-escaping closure call,
a `baseAddress` optional unwrap, and a `memcpy` call (constant size,
so under `-O` it *should* lower to one unaligned load — but the
closure + buffer-pointer dance is per-fetch setup the source performs
every time: fetch buffer base, nil-check, compute `base + i`, call).
Then the CPU side does `pc &+= n` as a separate property store (S6).
A PUSH64 therefore pays S7 (opcode) + O1 (8-byte operand) + D1 (push)
= three checked memory operations with three buffer-pointer setups
for one guest instruction. Branches pay S7 + O1 and nothing else;
their `pc` target computation (`Int64(bitPattern:)` round-trips,
`:382`) is register-only and negligible.

## 2. Data-stack traffic (the dominant term for most opcodes)

| # | Item | Where | Cost |
|---|---|---|---|
| D1 | `dpush`/`dpop` per element | `NovaCPU.swift:59-73` | Both are `@inline(__always)`, so there is no call instruction — but each one performs: load `self.dsp`; wrapping subtract/add; load `self.dslim` (push) or load `memory.dataStackBase` **through the `memory` IUO property again** (pop, `:69` — note `dpop`/`cpop` do NOT use `step()`'s localized `mem`; they re-load `self.memory` and then a property of it, per pop); the limit compare; then a FULL generic checked accessor (item D2); then store `self.dsp` back. Per element: ≈4–5 object-property loads/stores + 1 accessor, before the value itself moves. |
| D2 | Generic accessor per stack element | `NovaMemory.swift:138-147` (read64) / `:174-182` (write64) | Same shape as O1: range compare against `maxStart64` (a load through `mem`), `Int(addr)` conversion, `withUnsafe(Mutable)BufferPointer` closure, `baseAddress` unwrap, `memcpy`. The stack slot is therefore checked TWICE per element against two different limits (stack limit in D1, RAM limit here) — both checks are semantically required (neither implies the other once `DSPSET` has run), but the RAM-limit check is provably redundant *for slots inside the stack region*, and the buffer-pointer setup is pure overhead repeated per element. |
| D3 | Multi-element opcodes multiply D1+D2 | e.g. DUP2 `:163-165` (2 pops + 4 pushes = 6 × (D1+D2)), ROT `:169-171` (6), PUSHALL `:230-231` (16 pushes), POPALL `:232-233` (16 pops), ENTER `:204-208` (cpush + n pushes) | Stack-shuffling opcodes are the worst per-instruction payers in the ISA: a single DUP2 performs 6 limit checks ×2, 6 buffer-pointer setups, ≈24–30 object-property loads/stores **[estimate]**, to move 48 bytes. |
| D4 | No stack-top caching anywhere | whole switch | Every value transits guest RAM on every operation: ADD (`:240-242`) is pop, pop, push = 3 × (D1+D2) plus one `&+`. There is no register-resident top-of-stack, no peephole fusion (ADD after PUSH still round-trips), nothing. The value's round trip through the `ContiguousArray` also defeats any chance the loaded value stays in a CPU register across the operation boundary. |
| D5 | Call stack = same shape | `NovaCPU.swift:75-87` | `cpush`/`cpop` replicate D1+D2 exactly (limit + generic `write64`/`read64`), paid by CALL/CALL32/CALLI/RET/ENTER/LEAVE. |

## 3. CPU-state access through the class (ARC + property traffic)

| # | Item | Where | Cost |
|---|---|---|---|
| A1 | Every state field is a heap-object property | `NovaCPU.swift:18-47` | `dsp/csp/pc/fp/status/tval/cycle/…` are stored properties of a `final class`. There is no struct/resident-state form: each read or write in a case body is a load/store to the object's storage with a `self`-relative offset. Individually one instruction each; multiplied by S6 + D1 they are the background radiation of the whole interpreter. **[estimate]** A binary ALU op touches object storage ≈10–14 times (2×dpop + 1×dpush per D1, + pc/cycle per S6). |
| A2 | ARC on class references | `step()` body, `dpush/dpop` | `self` and `mem` are strong class references. `@inline(__always)` helpers that touch `memory` (`:62, 70, 78, 84`) force the compiler to keep the reference live and correctly counted across every potentially-trapping call; the trapping accessors themselves are ARC boundaries (a throw unwinds, so retains must be balanced at each `try`). In `-O` much of this is optimized to no-ops *when provable*, but the proof burden is per-call-site and the `throws` signature (T1) is what makes it hard. No explicit retain/release instructions were counted here — flagged as a compiler-burden cost, not a measured one. |
| A3 | `regs` is a Swift `Array` | `NovaCPU.swift:47`; PUSHR `:225`, POPR `:229` | `regs[Int(n)]` is an `Array` subscript: buffer-pointer load + bounds check + uniqueness (COW) check on write. Paid only by PUSHR/POPR/PUSHALL/POPALL (and host-side snapshot reads), so it is minor for ALU-heavy code — but PUSHALL/POPALL pay it 16× on top of D3. |
| A4 | Flags are separate `Bool` properties | `NovaCPU.swift:37`; `setFlagsSub` `:91-98` | CMP/TST decode into 4 separate bool stores; BEQ/BNE each load `flagZ` from object storage (`:393, 396`). Small, but again: object round-trips for what is one register's worth of state. |
| A5 | Scratch `t0`/`t1` | `NovaCPU.swift:50-51` | Declared, never used in `step()`. Zero runtime cost; noted only so nobody "optimizes" them. |

## 4. Throws plumbing

| # | Item | Where | Cost |
|---|---|---|---|
| T1 | `step()` is `throws`; every accessor is `throws` | `NovaCPU.swift:102`; `NovaMemory.swift:111-182`; helpers `:59-87` | Success path: Swift's error return is a register + a test per `try` site — cheap per site, but there are ~90 `try` sites in `step()` and each one is a branch the optimizer must keep, plus an unwind edge that constrains code motion and register allocation across the whole 370-line body (this is the quiet cost: it is why state stays in memory — the compiler cannot freely cache `pc`/`dsp` in registers across a call that might throw and be observed by the catch in `run()`). Per trap (actual throw): error value materialization + unwinding to `run()`'s catch + the vector/handler dispatch at `:489-512` — paid once per trap, irrelevant unless the workload traps per-iteration (ECALL-heavy firmware context switches do exactly this: every ECALL/timer vector costs a full throw + catch + 2 `try? dpush` + re-entry). |
| T2 | `try? dpush` in the vector path | `NovaCPU.swift:496-497` | On a vectored trap the two pushes re-run the full D1+D2 path with a swallowed error — correct, and correctly cheap relative to the trap itself. Noted because a hot loop that exits per trap re-pays S3/T1-entry per vector; at a 100 000-cycle timeslice that is noise, at ECALL-per-syscall rates it is not. |

## 5. Individual expensive opcodes / paths

| # | Item | Where | Cost |
|---|---|---|---|
| X1 | `RDTIME` allocates | `NovaCPU.swift:452-453` | `Date()` constructs a Foundation value (current-time syscall + struct plumbing) on EVERY execution, then `dpush` pays D1+D2 to store a value that came from the host clock. By far the most expensive single opcode relative to its work; `bench` (the speed workload) executes it in its inner measurement loop, so its cost is inside the harness's headline IPS number. Any interpreter-level fix can only remove the D1+D2 part; the `Date()` itself is ISA semantics (host wall-clock µs) and stays. |
| X2 | `RDRAND` | `NovaCPU.swift:458-459` | `UInt64.random(in:)` — system RNG call per execution, plus D1+D2. Same class as X1, rarer in practice. |
| X3 | `ROLL` | `NovaCPU.swift:185-193` | Heap-allocates a `[UInt64]` temp array per execution (`var tmp = [UInt64]()` + appends, with COW/growth semantics), on top of n × (D1+D2) twice. The only allocating opcode in the hot switch. |
| X4 | `MEMCPY` | `NovaCPU.swift:375-377` → `NovaMemory.swift:184-200` | 3 pops (D1+D2 each) + one guard + one `memmove` — already bulk; the per-instruction overhead is the pops, not the copy. |
| X5 | MMIO loads/stores | `NovaCPU.swift:335-374` → `NovaMemory.swift:346-410` | The 4 routing opcodes compare against `0xFFFF_FFFF_FFFF_0000`, then call `mmioRead`/`mmioWrite`: a chain of `else if` address compares (up to ~11 compares for late entries), plus for console writes the UTF-8 assembly (`isCompleteUTF8` scan + `String` construction per character, `:349-360`) and the host closure. This is device semantics, not interpreter fat — but note every console byte ALSO pays the full S-skeleton + D1 pops to get there (`galaxy` is print-heavy precisely through this path). File/net MMIO calls run host handlers synchronously on the VM thread — unbounded host cost, by design, excluded from interpreter accounting. |
| X6 | `copyBytes` guard | `NovaMemory.swift:185-189` | Five-part guard with wrapping adds — paid once per MEMCPY, negligible next to X4's pops. Deliberately left in this exact form by V1 (zero-count edge semantics); any fast path must reproduce it verbatim, not "simplify" it. |
| X7 | Timer MMIO coupling | `NovaMemory.swift:356-358, 396-399` | Guest writes to `timerIntervalAddr` mutate `timerInterval`/`timerCount` mid-run; guest reads of `timerCountAddr` observe the live countdown. Consequence for any state-localizing loop: timer state cannot be naively cached in locals — it must be flushed before any `mmioRead` and reloaded after any `mmioWrite`, or kept in the memory object. (Design constraint, recorded here because it is invisible from `NovaCPU.swift` alone.) |
| X8 | `DEPTH` | `NovaCPU.swift:195-196` | Loads `mem.dataStackBase` through the class + a division by 8 + D1 push. Trivial; listed because it is another per-opcode class-property load of a value that is constant for the whole run. |

## 6. What is NOT costing anything (checked, so it isn't re-litigated)

- **No dynamic dispatch**: `NovaCPU`/`NovaMemory` are `final`; all
  calls are direct. The `memory` IUO costs a load + unwrap check
  (S4), not a witness table.
- **No per-instruction allocation** except X1/X2/X3: the switch itself
  allocates nothing; `String`/UTF-8 work happens only on console MMIO.
- **No redundant range checks left in the accessors**: V1 already
  reduced them to one comparison (S7/D2's "second check" is the
  `ContiguousArray` subscript's own, which is a different layer).
- **`checkPush` (`:55-57`) is dead** — declared, never called
  (`dpush` inlines its own check). Zero cost, zero value.
- **`NovaPrivilege`, `satp`, `esp`, `vsp`, `eslim`, `vslim`** are never
  touched by `step()`; they cost nothing per instruction.

---

## 7. Rankings

Costs are ranked by expected contribution to wall time for a typical
tight loop of each shape, **[all estimates]** — the ordering rests on
operation counts above (object-property round-trips and
buffer-pointer setups dominate; single compares and the ALU op
itself are noise by comparison).

### (i) ALU / stack op (e.g. ADD, DUP, SWAP, PUSH64)

1. **D1+D2 stack round-trips** — 2–3 generic checked accessors with
   buffer-pointer setup per element, each preceded/followed by
   limit checks and `dsp` property stores. The value's trip to guest
   RAM and back (D4) is the single biggest term.
2. **S3+S6 state re-materialization** — the `step()` call boundary
   forcing `pc`/`cycle`/`dsp` through object storage; nothing stays
   in registers between instructions.
3. **T1 throws plumbing** — not the per-`try` test, but the
   optimization barrier: unwind edges at ~90 sites pinning state to
   memory (enables #2 to hurt as much as it does).
4. **S5 timer pre-check** — 2–4 class-property loads before fetch,
   every instruction, even with the timer off.
5. **S1+S2 `run()` loop + do/catch frame** — small constant per step.
6. **S7 fetch + S8 dispatch** — real but smallest: ~2 checks, ~3
   loads, 1 indirect jump.
7. (PUSH64 only) **O1 operand fetch** — one more accessor +
   buffer-pointer setup; ranks ≈ #4 for that opcode.

### (ii) Load / store op (e.g. LOAD64, STORE64, LOADU8)

1. **The data access itself, twice-checked** — address pop (D1+D2)
   + the load/store accessor (O1-shaped: range compare + buffer
   setup + memcpy) + result push (D1+D2) for loads: a LOAD64 pays
   ≈3 full accessor round-trips to move 8 bytes once. The middle
   accessor's cost is inherent (it IS the instruction); the two
   stack round-trips around it are not.
2. **S3+S6 / T1** — as (i) #2/#3.
3. **MMIO range test** — one compare for the 4 routing opcodes,
   negligible; the routed MMIO work itself (X5) is device cost,
   excluded.
4. **S5, S1+S2, S7+S8** — as (i), same order, smaller share.

### (iii) Branch (JMP/BZ/CALL/RET/LOOP)

1. **S3+S6 / T1** — branches do the least real work, so the fixed
   skeleton is the largest share: call boundary + `pc` stored,
   reloaded, offset-added, stored again (≈3 `pc` round-trips for a
   taken branch: fetch increment, operand increment, target assign).
2. **O1 operand fetch** — one checked `read16/32` + buffer setup;
   the branch's only memory read besides the opcode.
3. **S5 timer pre-check** — proportionally larger here than in (i)
   because the denominator is small.
4. **Stack/condition access** — BZ/BNZ/LOOP pay one D1+D2 pop
   (LOOP: pop + push = 2); CALL pays one D5 cpush; RET one D5 cpop;
   BEQ/BNE pay only an A4 flag load. For BZ-class branches this item
   swaps places with #2.
5. **S7+S8, S1+S2** — as (i).

### Headline

The interpreter's per-instruction cost is **not** dispatch, fetch,
or the ALU — it is (1) every operand and stack element round-tripping
through generic checked accessors with per-access buffer-pointer
setup, and (2) all CPU state living behind a class + `throws`
boundary that forces it into memory between (and within)
instructions. Both are exactly what a locals-resident, non-throwing
run loop with a direct-buffer stack path removes; the timer
pre-check (S5) and the `run()`/catch skeleton (S1/S2) are the fixed
costs such a loop amortizes next. `RDTIME`'s `Date()` (X1) is the
largest single-opcode outlier and is mostly *not* removable —
it is the ISA's definition of that instruction.
