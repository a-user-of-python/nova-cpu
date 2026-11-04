# NOVA v0.0.71 — Phase 2 JIT design (Lane JIT-DESIGN)

Date: 2026-11-04. Status: DESIGN + FEASIBILITY SPIKE. No shipping-core
changes in this lane: nothing under `vm-app/` was touched, the shipped
hotloop interpreter (`vm-app/NovaVM/VM/NovaCPU.swift`, v0.0.70) is the
permanent fallback engine and remains the semantics contract for
everything below. Sources this design is grounded in:

- `agent_notes/v070-summary.md` — what Phase 1 shipped (hotloop
  promoted; bench 252,384,105 ips / galaxy 9,307,316 ips, run
  41873106273; all 9 goldens pass incl. `selfmod`).
- `agent_notes/v070-agg-b.md` — the predecode variant's block
  boundaries and invalidation rule set (a)/(a′)/(a′′)/(b)/(b′)/(c),
  adapted for native code in §4 below.
- `vm-app/NovaVM/VM/NovaCPU.swift` — the contract: 93 implemented
  opcodes (§6), trap kinds/vectors/`tval` discipline, `cycle += 1`
  per instruction at fetch, the pre-fetch timer check, MMIO routing
  for exactly four opcodes (`LOAD64`/`LOADU8`/`STORE8`/`STORE64`),
  and `handleTrapAfterStep` (V1 `run()`'s catch block, factored out
  verbatim by hotloop) as the one trap-handling path.
- `vm-app/NovaVM/VM/NovaMemory.swift` — bounds discipline (one
  comparison per access: `addr <= totalSize - n`), MMIO map
  `0xFFFF_FFFF_FFFF_0000…0078`, `withHotBuffer` (the whole-run guest
  RAM pointer the hot loop already relies on).
- `tools/harness/fixtures/selfmod.nova` — the self-modifying test
  (61 cycles, console `SCBDEK\n`, WFI at `pc = 0x6E`) the JIT must
  pass; its three phases map 1:1 onto invalidation rules J1/J2 below.

---

## 1. Feasibility spike (Deliverable 1 — done FIRST, it gates the design)

Artifact: `tools/jitspike/main.swift` (canonical workflow copy:
`tools/jitspike/jitspike.yml`, copied verbatim to
`.github/workflows/jitspike.yml`). A minimal Swift CLI, no
entitlements, ad-hoc `swiftc` signature only. It probes, in order,
with stdout flushed before every risky call (so a crash mid-probe
still leaves a complete log of what had already succeeded):

1. **plain RWX** — `mmap(PROT_READ|PROT_WRITE|PROT_EXEC,
   MAP_PRIVATE|MAP_ANON)`; write code while RWX; execute.
2. **W^X transition** — `mmap(PROT_READ|PROT_WRITE)`; write;
   `mprotect(PROT_READ|PROT_EXEC)`; execute; flip back to RW to
   rewrite; flip to RX again; execute. Never RWX at execute time.
3. **MAP_JIT** — `mmap(…, MAP_JIT)` (RWX first, RW second), with
   `pthread_jit_write_protect_np(0/1)` toggling write vs. execute
   mode around each phase.

Each probe writes two trivial native functions and calls them through
an `UnsafeRawPointer` → `@convention(c)` function-pointer cast
(`unsafeBitCast`): `const42()` (`mov w0,#42; ret` on arm64 /
`mov eax,42; ret` on x86_64) and `add(a,b)` (`add w0,w0,w1; ret` /
`mov eax,edi; add eax,esi; ret`), checking `const42() == 42`,
`add(20,22) == 42`, `add(-5,5) == 0`, with
`sys_icache_invalidate` after every write.

**Runs.** Dispatch attempt 1, run **41889320180** (2026-11-04
18:39:34Z), never started: the job was cancelled while queued at
18:54:37Z when the workflow's original 15-minute job timeout
elapsed in the queue — a spike-workflow bug, not a spike result
(the timeout has since been raised to 90 minutes in
`jitspike.yml`). Dispatch attempt 2, run **41892040339**, job
126791692285: **success**, every step green. Environment (from the
run log): runner image `macos-26-arm64` (macOS 26.6.2, Darwin
25.6.0 `RELEASE_ARM64_VMAPPLE`), `Apple M1 (Virtual)`, Apple Swift
6.3.3, target `arm64-apple-macosx26.0`. The spike binary's
signature, from the codesign step: `Format=Mach-O thin (arm64)`,
`flags=0x20002(adhoc,linker-signed)`, `Signature=adhoc`,
`TeamIdentifier=not set`, entitlements **empty** — i.e. every
result below was obtained with no JIT entitlement and no special
signing, exactly the conditions the design must assume.

**Spike stdout, verbatim** (log timestamps stripped; the full log
is in run 41892040339 and the `jitspike-log` artifact,
ID 13354846482):

```
=== NOVA JIT SPIKE ===
arch=arm64
code sizes: const=8 bytes, add=8 bytes
PROBE plain-rwx: mmap(PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON)
  plain-rwx: mmap FAILED errno=13 (Permission denied)
PROBE wx-transition: mmap(PROT_READ|PROT_WRITE) -> write -> mprotect(PROT_READ|PROT_EXEC) -> execute
  wx-transition: mmap RW OK at 0x00000001046ec000
  wx-transition: mprotect(RW->RX) rc=0 errno=0
  [wx-transition] calling const42 ...
  [wx-transition] const42() = 42 (expected 42) OK
  wx-transition: mprotect(RX->RW) rc=0
  wx-transition: mprotect(RW->RX) rc=0 errno=0
  [wx-transition] calling add(20, 22) ...
  [wx-transition] add(20, 22) = 42 (expected 42) OK
  [wx-transition] calling add(-5, 5) ...
  [wx-transition] add(-5, 5) = 0 (expected 0) OK
  wx-transition: RESULT OK (write RW, execute RX, never RWX while executing)
PROBE map-jit: mmap(PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON|MAP_JIT)
  map-jit: mmap OK at 0x00000001046ec000
  [map-jit] calling const42 ...
  [map-jit] const42() = 42 (expected 42) OK
  [map-jit] calling add(20, 22) ...
  [map-jit] add(20, 22) = 42 (expected 42) OK
  [map-jit] calling add(-5, 5) ...
  [map-jit] add(-5, 5) = 0 (expected 0) OK
  map-jit: RESULT OK (MAP_JIT allocation + execute worked)
SPIKE-SUMMARY plainRWX=false wxTransition=true mapJIT=true
SPIKE WINNING-PATH: mmap RW + mprotect RW->RX (W^X)
SPIKE DONE
SPIKE_EXIT_CODE=0
```

**Reading of the results (this changes the design's emphasis):**

- **Plain RWX anonymous mmap is REFUSED on current macOS**
  (`errno 13`, EPERM) even for an ad-hoc-signed CLI with no
  hardened-runtime claims. "Try RWX first" is dead as a primary
  strategy on Apple platforms generally, not just iOS: the JIT
  must be built W^X-first (§2.2). Plain RWX remains in the probe
  order only as a last-resort path for hypothetical environments
  that allow nothing else.
- **The W^X path works completely**: RW allocation, write,
  `mprotect` to RX, execute, flip back to RW, rewrite, flip to
  RX, execute again — the full code-pool lifecycle the JIT needs
  (§3/§4 J7), with zero entitlements.
- **MAP_JIT also works completely** on this runner, including
  executing RWX+MAP_JIT mappings under
  `pthread_jit_write_protect_np` toggling. Two independent viable
  allocation paths on macOS means the §2.2 probe has real
  redundancy there.
- Net: **nothing about executable memory blocks the JIT on
  macOS**, so the harness gate strategy in §7 stands as designed
  (the gate exercises the real JIT, not a stub). The design's
  gate strategy would only have changed if *nothing* had worked;
  that branch is now closed for macOS and remains open only for
  iOS (§1, final subsection; §8 D1).

### What the spike does and does not prove

The macOS CI runner is not iOS. A path working there proves the
*mechanism* (Swift can allocate, write, flip, and call generated code
with no entitlement plumbing) and gives the harness gate (§7) a real
JIT to test. It does **not** prove the same allocation succeeds inside
the iOS app sandbox: on iOS, anonymous `PROT_EXEC` mappings are
refused by the kernel unless the process holds the JIT entitlement
**or a debugger is attached** — Sean's StikDebug attach is exactly
the latter, which is why the runtime gate in §2 probes at every
`run()` start instead of assuming. Device activation can only be
proven by Sean on the iPad (§7.3).

---

## 2. Engine architecture

### 2.1 Shape

- **`NovaJIT.swift`** — one new file beside the interpreter (in the
  shipping tree: `vm-app/NovaVM/VM/NovaJIT.swift`, added by lane J5;
  in the harness: `tools/harness/variants/jit/NovaJIT.swift`, lanes
  J1–J4). It contains: the availability probe, the code pool
  (executable-page allocator with W^X discipline), the AArch64
  emitter, the block compiler, the block cache, and the dispatch
  trampoline. It depends on `NovaCPU`/`NovaMemory` only through the
  same public surface `hotRun` uses (`withHotBuffer`, `mmioRead`,
  `mmioWrite`, the CPU's state fields, `handleTrapAfterStep`
  semantics) — the interpreter files are **not modified** by J1–J4.
- **AArch64 only.** Every target that matters (iPad M3, iPhone,
  `macos-latest` CI) is arm64. Under `#if arch(arm64)` the real
  implementation compiles; on any other arch `NovaJIT` is a stub that
  reports `.unavailable(.unsupportedArchitecture)` and the
  interpreter runs. (The spike is arch-dual because it is a probe;
  the JIT is not.)
- **Dispatch point.** `NovaCPU.run(maxSteps:)` is the only place an
  engine is chosen — in J5 it becomes: if `requestedEngine == .jit`
  and the §2.2 probe succeeded at this `run()` entry, drive the JIT
  trampoline for the run; otherwise drive the existing hotloop
  `run()` body **unchanged**. The JIT trampoline's outer loop mirrors
  `run()`'s accounting exactly (steps, trap handling via the same
  `handleTrapAfterStep` logic, bail-step accounting), so the two
  engines are interchangeable at the `run()` boundary — which is
  precisely what the harness observes.

### 2.2 Runtime gate (probe at VM start)

At every `run()` entry with JIT requested, before any guest
instruction executes, the VM thread runs `NovaJIT.probe()`:

1. Try the allocation paths in a per-platform preference order.
   macOS (settled by the §1 spike): **W^X `mprotect` → MAP_JIT →
   plain RWX** (RWX last: the spike showed it refused outright).
   iOS (order itself is §8 D1, unsettled until device-tested;
   default until then): **MAP_JIT → W^X `mprotect` → plain RWX**,
   because iOS's debugger-attach JIT model is W^X-first and
   MAP_JIT is its native mechanism.
2. For the first path that allocates: write the spike's 2-instruction
   `const42`, flip to executable state by that path's discipline,
   call it, require `42`. Only a path that **executes** counts —
   allocation success alone is never trusted (this is also what
   keeps the probe safe on stock iOS: the kernel refuses the
   executable mapping itself, so the probe returns "unavailable"
   without ever jumping into unsigned code; §8 D1 records the
   residual risk).
3. Success → JIT available **for this run**; cache the winning
   `JitAllocPath` and a code pool built on it. Failure of every
   path → interpreter, silently: no error, no trap, no console
   output; `activeEngine` simply reports the interpreter.

The probe is re-run at **every** `run()` start, never cached across
runs: StikDebug can be attached or detached between runs, and a
stale "available" would be a crash, not a slowdown. Cost is one page
allocation + flip + a 2-instruction call — microseconds against any
real run. Within a run the result cannot change (the pool is built
once, up front; §4 J7).

### 2.3 Engine indicator surface (API only — no UI in this design)

The app (or any future diagnostics screen) reads exactly three
things; naming them here is the whole deliverable for the indicator:

- `NovaCPU.requestedEngine: NovaEnginePreference` — `.interpreter`
  (default) or `.jit`; set by the harness flag (§7) or, in J5, by
  the app. Setting it never guarantees JIT runs.
- `NovaCPU.activeEngine: NovaActiveEngine` — `.interpreterHotloop`
  or `.jit(path: JitAllocPath)`; written at every `run()` entry with
  what that run actually used. **This is the value an indicator
  shows** ("JIT active" ⟺ `.jit`).
- `NovaJIT.lastProbe: JitAvailability` — `.available(path:
  JitAllocPath)` or `.unavailable(reason: JitUnavailableReason)`
  (`.allocationFailed(errno:)` / `.smokeTestFailed` /
  `.unsupportedArchitecture`), plus `NovaCPU.jitStats: JitStats?`
  (counters: `blocksCompiled`, `blockEntries`, `invalidations`,
  `singleSteps`, `faultExits`, `limitExits`) for a diagnostics
  surface. `NovaVMEngine` wiring (e.g. folding `activeEngine` into
  its status line) is J5's job; this lane builds no UI and touches
  no app file.

---

## 3. Compilation granularity and the block cache

**Granularity: basic blocks at control-flow targets**, mirroring
predecode's boundaries exactly, because they are already proven
against the goldens and `selfmod`:

- A **block head** is any pc control flow arrives at: run entry,
  branch/call targets, return targets (when first dispatched to),
  and the fallthrough pc past a previous block's end.
- Compilation decodes guest bytes sequentially from the head through
  `NovaMemory`'s checked accessors (a decode read that would fault
  ends the block *before* that instruction — the interpreter then
  reproduces the unfused-fetch fault state, exactly as predecode
  §2 argued). Compilation stops **after** the first control-flow
  instruction (`JMP/JMP32`, `BZ/BNZ`, `BEQ/BNE`, `CALL/CALL32`,
  `LOOP`, `RET`, `JMPI`, `CALLI`), after a status-writing
  instruction (`CSRSET`, `MRET` — §5.3), after an
  invalidation-relevant pointer write (`DSPSET`/`CSPSET` — §4 J2),
  **before** any bail instruction (§6: `ROLL`, `MEMCPY`,
  unimplemented opcodes), at the **64-instruction cap** (predecode
  parity), or before any instruction overlapping a stack region
  (§4 J2). Conditional branches end the block whether taken or not;
  the fallthrough becomes its own head and may compile overlapping
  bytes under a second key — duplicate native code, traded for the
  same simple correctness story predecode chose.
- The **cache** is `[UInt64: CompiledBlock]` plus the bounding
  interval `[codeLo, codeHi)` over all cached blocks' byte ranges
  (the O(1) reject for §4 J1). A `CompiledBlock` records: guest pc,
  byte length, instruction count, code-pool offset, and the guest
  pc range it covers. Lifetime: **per `run()` call** (§4 J6).

Compilation is lazy (on first dispatch to a head) and happens only
in the trampoline, never inside generated code: generated code
returns to Swift for every miss, exit, and event.

---

## 4. Invalidation rules (AGG-B adapted for native code)

AGG-B's rules are restated as J-rules. The adaptation principle:
**a stale decoded block costs a re-decode; a stale native block
executes wrong machine code at full speed — with immediates and
exit targets baked in — and can corrupt the shared state block
before any check runs.** Every ambiguity therefore resolves toward
flushing more, and the cache stays cheap to rebuild (blocks ≤ 64
instructions, compile is a linear emit).

- **J1 (was (a)) — guest stores, checked inline.** After every
  RAM-writing instruction the JIT inlines — `STORE8/16/32/64` (RAM
  path) and `STORL` — generated code compares the written range
  `[addr, addr+size)` against the cache bounding interval
  `[codeLo, codeHi)` (three compares; the common no-overlap case is
  the first compare). On overlap the instruction **completes**
  (its semantics are done; `pc` already names the next
  instruction), then the block exits with reason `.invalidated`:
  the trampoline drops the **whole cache** and re-dispatches the
  next pc fresh. Whole-cache, not per-block, for AGG-B's reasons
  (cheap rebuild, rare in real workloads) plus the native one:
  overlapping blocks under multiple keys (§3) make a surgical
  per-block drop the easiest place to miss one — and a miss here
  is silent wrong *native* execution, not a stale decode.
  *Against selfmod:* phase 1a's store (byte 30 patching byte 32,
  inside the block compiled from 0) exits `.invalidated` → the
  fallthrough `PUSH8` recompiles as `PUSH8 67` → prints `C`.
  Phase 2's store patches its own block's range → drop → iteration
  2 recompiles → prints `E`, not `D`. Phase 1b's target was never
  compiled when patched; its first compile reads fresh bytes →
  `B`. All three phases pass by the same one rule.
- **J2 (was (a′)) — stack writes are unchecked because they cannot
  hit a cached block.** `dpush`/`cpush` writes (including `ENTER`,
  `CALL`, and trap vectoring pushes) land only inside the
  architectural stack regions, enforced by their limit checks; the
  compiler **refuses to compile any instruction overlapping
  `[dslim, dataStackBase)`, `[cslim, callStackBase)`, or
  `[vslim, vectorStackBase)`** (§3), so no cached byte is ever a
  push target, and push code skips the J1 compare entirely — this
  is what keeps stack-heavy code (the common case) at zero
  invalidation overhead. A dispatch whose head lies in a stack
  region single-steps through the interpreter (and J5 flushes).
  The one way to move a stack pointer, `DSPSET`/`CSPSET`, is a
  block terminator that **flushes the whole cache after
  executing**: a moved stack could otherwise be re-aimed into code
  space and J2's premise would silently break.
- **J3 (was (a′′)) — MMIO never executes in generated code.** The
  four MMIO-routed opcodes peek (not pop) their address operand;
  an MMIO-range address exits *before* the instruction
  (`.singleStep`, §5.2) and the interpreter's `mmioWrite`/
  `mmioRead` runs it. Host handlers behind file/net MMIO write
  guest RAM synchronously; J5 then flushes, so their writes can
  never leave stale code. (Console stores pay an exit per
  character — the same deliberate correctness-over-speed cost
  predecode paid on `galaxy`; the refinement AGG-B §5 flagged,
  calling `mmioWrite` directly for the provably-RAM-safe console
  address only, is deferred to a post-J4 profiling decision,
  §8 D3 — *not* taken pre-emptively, because it weakens J3 from
  "any host code" to an argument about specific handlers.)
- **J4 (was (b)) — every trap flushes, before handling.** On any
  fault exit (§5.2) and on a timer-limit firing (§5.3), the
  trampoline drops the whole cache **before** calling
  `handleTrapAfterStep`. Vectored traps resume in guest firmware
  that may self-modify; unvectored traps run host code that may
  write RAM (file READ payloads). Either way nothing compiled
  before the trap is trusted after it.
- **J5 (was (b′)) — every interpreter single-step flushes.** Any
  instruction executed by `step()` on the JIT's behalf (`ROLL`,
  `MEMCPY`, MMIO, bail opcodes, stack-region heads, the
  DIV-overflow bail of §6) drops the whole cache after it runs.
  The invariant stays statable in one line, verbatim from AGG-B:
  **native blocks are only ever trusted across consecutive block
  executions whose writes were all interval-checked.**
- **J6 (was (c)) — per-run lifetime.** The cache and its code pool
  are created at JIT `run()` entry and destroyed (pages unmapped)
  when `run()` returns. Host-side loads between runs
  (`loadBytes`, `storeHostBytes`, `loadProgram`, `reboot`) can
  never go stale — there is nothing left to go stale.
- **J7 — exhaustion is a flush, never a failure.** If the code
  pool fills, the trampoline flushes the whole cache, recycles the
  pool pages (flip RX→RW, reset the block table, bump a generation
  counter), and continues the run. Compilation itself can never
  trap the run: any internal emitter failure degrades that head to
  interpreter single-stepping (with J5 flushes) for the rest of
  the run.

---

## 5. Exactness design

This is the hard part, and the standard is absolute: for every
guest-observable quantity — console bytes, `cycle`, `pc`, `tval`,
halt classification, timer behaviour, step-budget prefixes — the
JIT must be indistinguishable from the shipped hotloop core on
every program, including faulting ones. The design gets there the
same way hotloop did: **generated code mutates state in `step()`'s
exact order, and every exit presents a state the interpreter could
have produced.**

### 5.1 The shared state block and register discipline

Generated code is a function `(state: UnsafeMutableRawPointer) ->
UInt64 /*exit reason*/` under AAPCS64. One `JitState` struct is
allocated per run; its layout (all `UInt64` slots) is fixed:

```
 0 ramBase        64 csp           128 regs[0]  … 248 regs[15]
 8 ramSize        72 fp            256 nextPc
16 maxStart16     80 status       264 lastDelta (insns executed)
24 maxStart32     88 epc          272 exitAux (trap rawValue, …)
32 maxStart64     96 cause        280 codeLo (cache interval lo)
40 cycle         104 tval         288 codeHi
48 pc            112 savedStatus  296 entryStatus (status at block entry)
56 dsp           120 flags (N/Z/C/V packed bits)
```

`ramBase`/`ramSize`/`maxStart*` are filled once per run from
`NovaMemory` (the run executes inside `withHotBuffer`, whose
pointer is valid for the whole run for the reasons hotloop's
header documents: the `ContiguousArray` is never resized after
`init`). Guest RAM accesses in generated code use `ramBase` plus
**the checked accessors' own comparisons** (`addr <= maxStart64`
for 8-byte, etc.), so an inline access succeeds iff
`NovaMemory`'s would, transferring the same little-endian bytes.

During a block, hot state lives in AArch64 callee-saved registers
(prologue saves them, every exit stub restores them):

| Reg | Holds |
|---|---|
| x19 | `JitState` pointer |
| x20 | **delta** — instructions executed so far in this block |
| x21 / x22 / x23 | `dsp` / `csp` / `fp` |
| x24 | **limit** — instructions still allowed in this block (§5.3) |
| x25 | `ramBase` |

Everything else (`cycle`, `pc`, `status`, `epc`, `cause`, `tval`,
flags, `regs[]`) is memory-resident in `JitState` and accessed in
place — guest-register and flag traffic is memory traffic in the
interpreter too, so this concedes nothing. `dsp/csp/fp` are loaded
from `JitState` at block entry and stored back by **every** exit
stub, so at any trampoline-visible moment `JitState` is complete.

### 5.2 Cycle counting and the exit-stub protocol

`cycle` itself is **not** incremented in memory per instruction —
that was measured territory (it is what the interpreter pays for).
Instead:

- Each instruction's code is preceded by the boundary sequence:
  `if limit == 0 { goto limitExit } ; limit -= 1 ; delta += 1`.
  Delta therefore counts exactly the instructions whose bodies
  have begun, and it is incremented at the same point `step()`
  increments `cycle` (at fetch, before the body) — so a body that
  faults has already been counted, and one that hasn't begun has
  not. Two extra instructions per guest instruction is the entire
  exactness tax on the hot path.
- **Every exit stub** performs the same fold, in order:
  `state.cycle += delta`; `state.dsp/csp/fp = x21/x22/x23`;
  `state.lastDelta = delta`; `state.pc`/`state.nextPc` set per
  exit kind (below); restore callee-saved registers; return the
  reason code. After any block return, `JitState` is a state the
  interpreter could have left, and the trampoline's sync-out
  (copying `JitState` → `NovaCPU` fields, settling `timerCount`
  per §5.3) makes it the object state — the same
  sync-on-every-exit discipline `hotRun` documents.
- **Fault exits** (reason `.fault`, `exitAux` = `NovaTrap`
  rawValue): generated code reaches a fault only at points where
  `step()` can throw, with all prior mutations of that instruction
  already committed in `step()`'s order (codegen rule, §6) — e.g.
  a load's address pop has already updated `x21` before its
  bounds check fails; a push that would overflow has **not**
  written and has **not** moved `x21` (check-then-write, mirroring
  `dpush`); `PUSHR n ≥ 16` writes `tval = n` to `JitState` before
  exiting, `DIV` by zero leaves `tval` untouched, exactly as
  `step()` does. The stub sets `state.pc` to the faulting
  instruction's `nextPC` constant (baked at compile time),
  matching the interpreter's "pc past the operand, cycle counted"
  fault state. Operand-*fetch* faults cannot occur in generated
  code: immediates are baked at compile time, and a block never
  contains an instruction whose operand bytes the compiler could
  not read (§3) — that instruction is single-stepped instead, so
  its unfused-fetch state comes from `step()` itself.
- **Trap bridging.** A `.fault` return is *not* a second trap
  implementation: the trampoline syncs out, flushes (J4), then
  calls the interpreter's own `handleTrapAfterStep(trap)` — the
  verbatim V1 catch-block logic hotloop factored out — which does
  timer/ECALL vectoring (saving `epc`/`cause`, pushing them,
  disabling interrupts, jumping to `timerVector`) or invokes
  `trapHandler` / halts, identically for both engines. `ECALL`,
  `EBREAK`, and `TRAP` are compiled *as* fault exits (reason
  `.fault`, rawValues 8/3/3; `TRAP`'s baked operand byte written
  to `tval` by its stub) — their entire semantics is "throw this",
  so there is nothing to re-implement and nothing to drift.
  `WFI` is its own reason (`.wfi`): delta includes it, the
  trampoline sets `running = false`, the run ends — the same
  observable state as `hotRun`'s halted path.

### 5.3 The guest timer and the step budget (the limit register)

The timer is the sharpest exactness constraint: its check runs
**before every instruction** in `step()` (decrement the countdown
if interrupts are enabled; on reaching zero, reset to the
interval and throw `timerInterrupt` with `epc`/`pc`/`cycle`
pointing *at* the un-executed instruction), and its countdown is
guest-visible through MMIO. The step budget has the opposite
shape: `run()` checks it *before* each step, so budget exhaustion
pre-empts a timer firing at the same boundary. Neither can be
checked only at block granularity — a 64-instruction block would
fire the timer up to 63 instructions late and would overshoot
`bouncer`/`counter`'s budget-prefix goldens.

The protocol (all computed by the trampoline at each dispatch,
from state that cannot change mid-block — see the freeze argument
below):

```
timerAllow  = (interval > 0 && entryStatus & 1 != 0) ? timerCount - 1
                                                       : ∞
budgetAllow = maxSteps - stepsUsed
limit       = min(blockInsnCount, timerAllow, budgetAllow)
limitKind   = .budget if budgetAllow <= timerAllow else .timer
```

- `timerAllow` is `timerCount - 1` because, starting a countdown
  at `C`, the checks before instructions 1…C−1 decrement without
  firing and the check before instruction C fires: exactly C−1
  instructions may execute. (`timerCount ≥ 1` whenever the timer
  is armed: every writer — reset, the interval MMIO write, the
  firing reset itself — sets it to the interval or leaves it
  counting down from it. The `timerCount == 0 && armed` corner is
  handled defensively by not entering a block at all: the
  trampoline emulates the firing directly, as below.)
- The boundary sequence (§5.2) stops the block *before* the
  (limit+1)-th instruction with reason `.timerLimit` or
  `.budgetLimit`. On `.budgetLimit`: state is folded, `stepsUsed`
  reaches `maxSteps` exactly, the run returns with
  `running == true` — halt `step-budget`, console prefix and
  `cycles == steps` bit-exact, mid-block if need be.
  On `.timerLimit`: the trampoline settles `timerCount :=
  timerInterval` (the reset `step()` performs as it fires),
  counts **one** step for the firing pseudo-instruction
  (mirroring `hotRun`, which does `used += 1` on its timer path
  while leaving `cycle` untouched), flushes (J4), and calls
  `handleTrapAfterStep(.timerInterrupt)` with `pc` at the
  interrupted instruction. Vectoring, resumption, and firmware
  timeslicing then proceed exactly as in the interpreter.
- **Settling on ordinary exits:** the countdown only ever moves
  inside `step()`'s check, once per begun instruction, so after a
  block that executed `delta` instructions under armed entry
  conditions the trampoline sets `timerCount -= delta` before
  anything can observe it (a single-stepped MMIO read of
  `timerCountAddr` therefore sees the live value — the same
  flush-before-MMIO discipline hotloop applies to its cached
  timer locals). Blocks entered disarmed never touch it.
- **The freeze argument** (why entry conditions hold for the whole
  block): within a block, nothing can change the timer's
  parameters or the interrupt-enable bit except — `timerInterval`/
  `timerVector` writes: MMIO only → never in a block (J3);
  `status` writes: `CSRSET` and `MRET` only → both are block
  terminators (§3), and their own timer check already ran under
  the *old* status at their boundary, so settling by entry
  conditions stays exact; `timerCount` writes: MMIO-read-only
  register, no guest write path. ∎

### 5.4 MMIO and out-of-bounds accesses mid-block

- **MMIO:** only `LOAD64`, `LOADU8`, `STORE8`, `STORE64` route to
  MMIO in the interpreter, and only they check. Generated code
  **peeks** the address on top of the data stack (a load from
  `[x21]`, no pop): if `addr ≥ 0xFFFF_FFFF_FFFF_0000`, the block
  exits *before* the instruction (`.singleStep`; delta and steps
  exclude it; `pc` names it) and the trampoline single-steps it
  through `step()` — which does the pop, the `mmioRead`/
  `mmioWrite`, the timer-field flush/reload, and any host-handler
  reentrancy, all in the one proven implementation — then flushes
  (J5) and re-dispatches. Peeking rather than popping is what
  makes "before" exact: no state of the instruction exists yet.
  RAM addresses proceed inline. The other memory opcodes
  (`LOAD8`, `LOADU16/32`, `STORE16/32`) never route: an MMIO-range
  address simply fails their RAM bounds comparison and fault-exits
  with `loadAccessFault`/`storeAccessFault`, exactly as the
  checked accessors throw in `step()`.
- **Out-of-bounds RAM access mid-block:** the inline comparison
  fails *after* the operand pops that `step()` performs first and
  *before* any byte moves (a faulting multi-byte access transfers
  nothing, matching the accessors' check-before-memcpy atomicity).
  The block fault-exits per §5.2 with `pc = nextPC`, cycle
  counted, `dsp/csp` exactly as the partial instruction left
  them. Execution never reaches the bad address: the comparison
  is the same single comparison `NovaMemory` performs, against
  the same precomputed maxima.

### 5.5 WFI and stop-flag responsiveness

- `WFI` ends its block with reason `.wfi` (§5.2); nothing after it
  in the block exists (it is a control terminator for compilation
  purposes too).
- The engine stops the VM cross-thread (`NovaVMEngine.stop()` sets
  `cpu.running = false`; the register panel reads CPU state at
  4 Hz). The trampoline checks `cpu.running` and syncs object
  state out at **every block dispatch** — worst-case latency 64
  guest instructions between the stop request and the trampoline
  observing it, plus one sync per ≤ 64 instructions for the
  register snapshot. The requirement is parity with hotloop's
  8192-instruction writeback cadence; block-granularity sync beats
  it by 128×. No mid-block poll is needed *because* blocks are
  capped at 64 — if a future lane raises the cap, it must add a
  back-edge poll in the same change.

---

## 6. Opcode coverage

The contract is the 93 opcodes `step()`'s switch implements.
**Codegen rule (applies to every group): emit checks and state
mutations in `step()`'s exact statement order for that opcode; a
fault exit may occur only where `step()` can throw, with all
earlier mutations already committed.** Groups:

### 6.1 Inline — straight-line (block continues)

- **Stack (28):** `NOP 00`, `PUSH8 01`, `PUSH16 02`, `PUSH32 03`,
  `PUSH64 04` (immediates sign-extended/baked at compile time —
  J1 is what makes baking self-modifying-safe), `POP 05`,
  `POPN 06` (operand-bounded loop ≤ 255, each pop checked),
  `DUP 07`, `DUP2 08`, `SWAP 09`, `ROT 0A`, `ROTR 0B`, `OVER 0C`,
  `TUCK 0D`, `PICK 0E`, `DEPTH 10`, `DSPGET 11`, `FPGET 13`,
  `ENTER 14`, `LEAVE 15`, `LOADL 16`, `STORL 17` (J1-checked),
  `LOADARG 18`, `PUSHR 19` / `POPR 1A` (`n ≥ 16` → `tval = n`,
  fault exit `illegalInstruction`), `PUSHALL 1B`, `POPALL 1C`,
  `CSPGET 1D`. All stack traffic goes through check-then-write
  push / read-then-move pop sequences mirroring
  `dpush/dpop/cpush/cpop` (overflow/underflow/access-fault exits
  with the pointer unmoved, as in §5.2).
- **ALU (29):** `ADD 40`, `SUB 41`, `MUL 42`, `MULH 43`
  (`SMULH`), `AND 48`, `OR 49`, `XOR 4A`, `NOT 4B`, `NEG 4C`,
  `SHL 4D`, `SHR 4E`, `SAR 4F` (AArch64 register shifts mask the
  count to 6 bits natively — the interpreter's `& 63` is free),
  `INC 50`, `DEC 51`, `CMP 52` / `TST 53` (compute the subtraction,
  pack N/Z/C/V into `JitState.flags` — guest flags live in state,
  never in the host NZCV, so host code between blocks can't
  disturb them), `EQ 54`, `NE 55`, `LT 56`, `LTU 57`,
  `POPCNT 5C` (`CNT`+fold), `REV8 5D` (`REV`), `EXT8 5E`,
  `EXT16 5F`, `EXT32 60` (`SBFX`/sign-extend forms).
  **`DIV 44`, `DIVU 45`, `REM 46`, `REMU 47` — peek-guarded
  inline:** generated code peeks both operands (no pops yet).
  Divisor 0 → fault exit `illegalInstruction` with both pops
  committed first (the interpreter pops, *then* guards — the
  exit stub path performs the two pops in generated code before
  returning, preserving the exact post-pop `dsp`). Unsigned:
  proceed with `UDIV` (+ `MSUB` for `REMU`). Signed: the pair
  (dividend `INT64_MIN`, divisor −1) **bails before the
  instruction** (`.singleStep`, nothing popped) — Swift's `/`
  and `%` trap the *host* on that pair while AArch64 `SDIV`
  silently returns the dividend, so native code must not decide
  this case; `step()` reproduces whatever the interpreter does
  today, bit-for-bit, including its host behaviour (§8 D2).
  All other signed pairs use `SDIV` (+ `MSUB` for `REM`), whose
  results (including divide-by-zero, already excluded, and
  truncation-toward-zero) match Swift's exactly.
- **Memory, RAM path (9):** `LOAD8 80`, `LOAD64 83`,
  `LOADU8 84`, `LOADU16 85`, `LOADU32 86`, `STORE8 87`,
  `STORE16 88`, `STORE32 89`, `STORE64 8A` — bounds per §5.4,
  J1 interval check after the four stores (and `STORL`), MMIO
  peek-exit for `83/84/87/8A` per §5.4.
- **System, pure (3):** `CSRGET C6` (operand switch 0/1/2, else
  fault exit `illegalInstruction` — note `step()` pops nothing
  and sets no `tval` here; neither does the JIT), `RDCYCLE CC`,
  `CPUID F5`.
  - **`RDCYCLE` inline, exactly:** pushes
    `state.cycle + delta`, where delta already includes
    `RDCYCLE`'s own increment (§5.2's boundary order) — the same
    value `step()` pushes (`cycle` after its fetch increment).
    Deterministic, so it stays on the fast path and remains
    golden-safe.
  - **`CPUID` inline:** a pure function of the popped leaf
    (0→`0x4E564F41`, 1→`0x0200`, 2→`0b0111`,
    3→`0x00312D61766F4E`, else 0) — a compare chain, no host
    state, nothing to call out for.

### 6.2 Inline — block-terminating (execute in the block, then exit)

- **Control flow (12):** `JMP A0`, `JMP32 A1`, `BZ A2`, `BNZ A3`,
  `BEQ A6`, `BNE A7` (read `flags` Z bit from state), `CALL A8`,
  `CALL32 A9`, `CALLI AA`, `RET AB`, `JMPI AC`, `LOOP AD`. The
  stub writes the resolved target (baked constant for
  direct branches — computed with `step()`'s wrapping
  `pc + offset` arithmetic at compile time; register/stack value
  for `RET/JMPI/CALLI`) to `state.nextPc` and returns reason
  `.next`; the trampoline dispatches (compile-or-enter) at
  `nextPc`. Dynamic targets are a *dispatch*, not a bail — they
  stay in native code across calls/returns.
- **Environment writers (4):** `DSPSET 12`, `CSPSET 1E`
  (terminate + J2 flush after), `CSRSET C7` (operand switch,
  else fault exit; terminate so §5.3's entry conditions are
  recomputed), `MRET C2` (`pc := epc`, `status := savedStatus`;
  terminate — dynamic target + status change).

### 6.3 Trap/halt exits (compiled as exits, §5.2)

`TRAP AE` (`.fault` breakpoint, `tval` := baked operand),
`ECALL C0` (`.fault` ecallU), `EBREAK C1` (`.fault` breakpoint),
`WFI C5` (`.wfi`). No interpreter round-trip: their semantics is
the throw itself, and the trampoline hands the trap to the
interpreter's own `handleTrapAfterStep`.

### 6.4 Helper call — block continues after a Swift callout

Generated code calls `@convention(c)` Swift helpers with the
state pointer, following AAPCS64 (delta/limit/stack pointers are
in callee-saved registers, so they survive the call by
construction; the helper touches only what `step()` touches):

- **`RDTIME CB`** → helper evaluating the interpreter's exact
  expression, `UInt64(Date().timeIntervalSince1970 * 1_000_000)`,
  pushed by generated code on return. Non-deterministic by
  definition (no golden executes it; `bench`'s console is
  non-deterministic for this reason and stays speed-only).
- **`RDRAND F4`** → helper returning
  `UInt64.random(in: 0...UInt64.max)`, same reasoning.

Helper callouts are the *only* calls generated code makes;
anything needing more (memory moves, host devices) goes through
the trampoline instead.

### 6.5 Bail to the interpreter (block ends BEFORE the instruction)

Executed by one real `step()` from the trampoline, counted as one
step, followed by a J5 flush — hotloop's `ROLL` precedent,
generalised:

- **`ROLL 0F`** — heap-allocating multi-pop/push body; not worth
  native code, exactly as hotloop decided.
- **`MEMCPY 8F`** — unbounded write range; J1 cannot check it
  cheaply inline, and J5 makes the single-step safe. (Predecode
  bailed it for the same reason.)
- **MMIO instances** of `83/84/87/8A` (runtime bail, §5.4) and
  the signed `DIV/REM` overflow pair (§6.1).
- **Every unimplemented opcode** — the remaining 163 values
  (`1F–3F`, `58–5B`, `61–7F`, `81`, `82`, `8B–8E`, `90–9F`,
  `A4`, `A5`, `AF–BF`, `C3`, `C4`, `C8–CA`, `CD–F3`, `F6–FF`):
  compilation stops before them; `step()` sets `tval = opcode`
  and throws `illegalInstruction`, so their trap state is the
  interpreter's by construction. A block whose *head* is a bail
  instruction is a pure single-step dispatch.

Coverage check: 28 + 29 + 9 + 3 inline, 16 terminating, 4
trap/halt exits, 2 helper, 2 named bails = **93** — every opcode
`step()` implements, each with a named treatment.

---

## 7. Harness plan

### 7.1 Plumbing (lane J1)

- `tools/harness/main.swift` gains `--engine interpreter|jit`
  (default `interpreter` — every existing invocation, golden, and
  mode is byte-unchanged). With `jit`, it sets
  `cpu.requestedEngine = .jit` before `run()`; the harness core
  for that build is the variants/jit pair (below), whose
  `NovaCPU.run()` contains the §2.1 dispatch. The harness's halt
  classification, meta format, and boot replication do not change:
  the JIT is observable only through the same console/cycles/halt
  triple, which is the point.
- `run.sh` learns one thing: `build_harness_dir` adds
  `$dir/NovaJIT.swift` to the `swiftc` line when present (the
  variant-dir contract grows by one optional file; existing
  variants are unaffected), and `run_one` passes
  `--engine jit` when the binary under test was built from a
  directory containing `NovaJIT.swift`. `gate-variant jit` and
  `speed-all` then work with **no manifest edits** — `speed-all`
  already auto-discovers variant directories.

### 7.2 The gate

- **Correctness:** `run.sh gate-variant jit` over **all 9 goldens**
  — `hello`, `fib`, `galaxy_examples`, `hi`, `galaxy_fixed`,
  `galaxy` (context-exact), `bouncer`, `counter`
  (budget-prefix: these two are the §5.3 limit protocol's real
  examiners), and `selfmod` (the J1/J2 examiner: 61 cycles,
  `SCBDEK\n`, WFI). Pass = byte-identical console, cycles, and
  halt for every case, same standard as every Phase 1 variant.
  Plus one harness-only addition in J4: a firmware-mode smoke run
  (`--firmware` shell image, `--timer-interval 100000`, scripted
  `--input`) compared between engines — no golden (the shell is
  interactive), engines must agree with each other.
- **Speed:** `run.sh speed-all` prints JIT vs hotloop (the
  `current` row *is* the shipped hotloop core) on `bench`
  (~50.5 M instructions, compute-bound; expectation: JIT wins
  big — bench is the workload native code exists for) and
  `galaxy` (print-heavy; J3's per-character MMIO exits cap the
  win — the honest expectation is a modest gain, and §8 D3 is
  decided from this number). Report ratios, not absolutes, per
  the harness README's standing guidance. No speed figure is a
  gate; the gate is exactness. A JIT that is not faster than
  hotloop on bench does not ship (that judgement is the
  coordinator's at J4, with the table in front of them).

### 7.3 What macOS can and cannot prove

- The macOS gate **proves**: semantic exactness of generated code
  against the goldens (including self-modifying code and
  budget/timer boundaries), the invalidation rule set, the
  trampoline/step accounting, and relative speed on Apple
  Silicon.
- It **cannot prove**: that executable allocation succeeds inside
  the iOS app under StikDebug (different sandbox, different
  kernel policy — §1), iOS W^X/MAP_JIT specifics, or on-device
  performance/thermals. **JIT activation on device can only be
  proven by Sean on the iPad**: sideload the v0.0.71 IPA, attach
  StikDebug to enable JIT, open the app, confirm the engine
  indicator (§2.3) reports JIT active, run `galaxy`/`fib` and
  compare console output, then detach and confirm the app falls
  back to the interpreter silently. Until that check exists,
  every JIT claim is a macOS claim. This is stated plainly so no
  future summary upgrades it by accident.

---

## 8. Build plan (follow-on lanes, dependency order, each gateable)

| Lane | Scope | Gate |
|---|---|---|
| **J1 — scaffolding** | `variants/jit/`: copy of the shipping hotloop `NovaCPU.swift` + stub `NovaJIT.swift` (probe per §1/§2.2, allocator, `JitState`, trampoline that single-steps *everything*); harness plumbing (§7.1: `--engine`, `run.sh` pickup). Interpreter files untouched. | `gate-variant jit` passes all 9 goldens with zero blocks compiled (proves plumbing, probe, flush discipline, step accounting). |
| **J2 — codegen core** | AArch64 emitter (+ intra-block fixups), block compiler/dispatcher, §5.1 register discipline, §5.2 delta/exit-stub protocol; inline groups: stack + ALU (incl. peek-guarded DIV family). Everything else still single-steps. | All 9 goldens pass with the subset compiled; `selfmod` passes (its opcodes are in-subset; J1/J2 rules live from this lane). |
| **J3 — memory + control** | Inline loads/stores with §5.4 bounds + J1 checks + MMIO peek-exits; control-flow terminators + dynamic dispatch; `DSPSET/CSPSET/CSRSET/MRET` terminators; `ROLL`/`MEMCPY` bails. | All 9 goldens pass fully compiled, incl. `bouncer`/`counter` prefixes (limit protocol under real budgets) — the exactness gate. |
| **J4 — system completion + speed** | Timer-limit protocol (§5.3) in full; `RDTIME`/`RDRAND` helpers; `CSRGET`, `CPUID`, `RDCYCLE`; trap/halt exits; `jitStats`. Firmware-mode engine-agreement smoke (§7.2). | All 9 goldens + firmware smoke agree between engines; `speed-all` produces the JIT-vs-hotloop table on `bench` + `galaxy` for the ship/no-ship judgement. |
| **J5 — app integration** (the only lane that touches `vm-app/`) | Promote `NovaJIT.swift` into `vm-app/NovaVM/VM/`; wire `requestedEngine`/`activeEngine` (§2.3) into `NovaCPU.run()` dispatch and the engine's status surface; version bump to 0.0.71; IPA build. | Harness `gate` still passes on the shipping core; device validation per §7.3 owed by Sean (StikDebug attach → indicator → fallback check). |

Each lane is one harness-variant-sized change, independently
revertible, and the interpreter is never edited except J5's
`run()` dispatch shim (which leaves the hotloop body itself
untouched).

## 9. Decisions taken, and decisions that could NOT be made here

**Taken** (argued above): basic blocks at predecode boundaries,
64-instruction cap; whole-cache invalidation (J1–J7); delta +
limit registers with exit-stub state folding; peek-don't-pop for
every bail; trap handling reused, never re-implemented;
per-run cache lifetime; AArch64-only; probe at every `run()`
entry.

**Could not be made without more information:**

- **D1 — iOS allocation-path priority.** The spike (§1) settles
  macOS (W^X and MAP_JIT both work; plain RWX is refused). It
  says nothing about iOS: whether StikDebug-attached iOS accepts
  MAP_JIT, plain RWX, or only the W^X `mprotect` path — and in
  which order to try them — needs Sean's device (a device
  variant of the spike, run under StikDebug, is a J5
  prerequisite). The design therefore keeps all three paths
  behind the §2.2 probe with a per-platform preference list as
  the only open parameter. Residual risk noted in §2.2: the probe executes
  generated code only after a successful executable mapping,
  which stock iOS refuses outright, so the no-debugger case
  fails safe; an exotic environment that maps but faults on
  execute would crash the probe instead — accepted, as every
  iOS JIT (UTM/Dolphin-class) accepts the same shape.
- **D2 — `DIV`/`REM` of (`INT64_MIN`, −1).** The interpreter's
  Swift `/` traps the host process; native `SDIV` doesn't.
  §6.1 bails the pair to `step()`, preserving today's behaviour
  exactly — but whether today's behaviour is *intended* (vs. a
  latent interpreter bug both engines should fix together,
  e.g. defining it as `illegalInstruction`) is a spec call for
  Sean/coordinator. The bail makes either future choice a
  one-line change.
- **D3 — console-MMIO direct callout.** Whether J3's
  per-character exits actually cost meaningful `galaxy` speed
  is measurable only after J4's table exists. If they do, the
  pre-argued refinement (direct `mmioWrite` callout for the
  console address only, flush still applied to file/net command
  addresses) comes back as its own gated lane; if they don't,
  J3 stands as designed.
- **D4 — cross-run cache persistence for firmware mode.** J6
  (per-run lifetime) is the exactness-safe choice and matches
  predecode, but NovaShell runs are long-lived and recompilation
  per `run()` call could matter there. No data exists yet;
  J4's firmware smoke should measure recompile counts before
  anyone proposes relaxing J6 (which would need a host-write
  invalidation story this design deliberately does not have).
