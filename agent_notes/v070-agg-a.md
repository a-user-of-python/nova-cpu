# NOVA v0.0.70 — Lane AGG-A notes: hotloop + dispatch variants

Date: 2026-11-04. Deliverables: overhead inventory
(`agent_notes/v070-overhead-inventory.md`), variant cores in
`tools/harness/variants/hotloop/` and `tools/harness/variants/dispatch/`,
harness plumbing (`speed-all`, `gate-variant`) in `tools/harness/run.sh`.
Nothing was copied into `vm-app/`; no commits. No Swift toolchain on
this VM — CI (`gate-variant` + `speed-all` via the harness workflow,
extended by the coordinator if needed) is the compile + behaviour gate.

## How the variant files were built (provenance)

Each variant `NovaCPU.swift` = the V1 `vm-app` file with everything
from the `// MARK: - Run loop` marker onward replaced; everything
before it — including the throwing `step()`, `dpush/dpop/cpush/cpop`,
all state fields — is **byte-identical to V1** (verified by diff:
the only prefix delta is the variant banner comment). The dispatch
file is the hotloop file with exactly two mechanical substitutions
(handler table in the marked slot; the marked switch region replaced
by one table call), so the two variants share everything except
dispatch BY CONSTRUCTION, not by parallel re-typing.

Each variant also carries a `NovaMemory.swift`: byte-identical to V1
except a banner and ONE added method, `withHotBuffer` (below). The
task brief preferred sharing V1's memory unchanged; that proved
impossible for a true direct-buffer stack path because `bytes`,
`sizeU64` and `maxStart*` are all `private` in NovaMemory — there is
no existing API through which NovaCPU can touch the buffer without
the per-access checked accessor. The added method is the minimal
surface that makes the fast path possible; nothing else in memory
changed (verified by diff: banner + method only).

## hotloop design

`run()` keeps V1's outer shape (`running = true`, budget accounting,
identical trap handling) but delegates the per-step work to
`hotRun(budget:)`, a non-throwing loop that returns
`(stepsUsed, outcome)` with outcome ∈ {budgetOrHalt, trap(NovaTrap),
bail}. Trap handling itself — vectoring for timer/ECALL when
`timerVector != 0`, else `trapHandler?(trap, tval)` + halt-if-no-
handler — was factored VERBATIM (comments included) from V1 `run()`'s
catch block into `handleTrapAfterStep(_:)`, shared by the hot trap
exit and the bail path. One deliberate narrowing: V1's generic
`catch { running = false }` survives only on the bail path; the hot
path cannot reach it because `step()` only ever throws `NovaTrap`
(every throw site in both core files is a `NovaTrap`) and `hotRun`
produces `NovaTrap` values only.

Inside `hotRun`, the loop runs inside `memory.withHotBuffer { buf in
… }` — a new NovaMemory method that yields the guest buffer's base
pointer for the duration of one closure. Safety argument (also in
the method's comment): `bytes` is assigned once in `init` and no
code path in NovaMemory resizes/appends/removes/reassigns it
afterwards (grep-verified); the VM executes on one thread; host MMIO
handlers invoked mid-loop use the ordinary checked accessors against
the same fixed storage. The pointer never escapes the closure.

State residency: pc, cycle, dsp, csp, fp, status, tval, epc, cause,
savedStatusForMret, the four flags, and `regs` (a local `[UInt64]`;
first mutation pays one COW copy of 128 B) live in locals for the
whole run. Limits/bases (`dslim`, `cslim`, stack bases, RAM size and
the derived `maxStart` equivalents) are loaded once into `let`s.
`esp/vsp/satp/eslim/vslim` are never touched by `step()`, so they are
neither localized nor written back. Full write-back (`syncOut()`)
runs on EVERY exit, plus every 8192 instructions mid-run so the
engine's 4 Hz register snapshot and its cross-thread `stop()`
(`cpu.running = false`, NovaVMEngine.swift:521) observe live state
with bounded lag — the periodic point is also the loop's
external-stop check (V1 checks `running` per step; hotloop per
≤8192 steps, still microseconds).

Timer state is the one deliberate partial localization:
`timerInterval`/`timerCount` are cached in locals, with two sync
points that keep MMIO-observed behaviour exact — flush `timerCount`
to memory before every `mmioRead` (guest can read the live countdown
at `timerCountAddr`), reload both after every `mmioWrite` (a write
to `timerIntervalAddr` mutates both inside NovaMemory). Write-back
on exit writes `timerCount` only; `timerInterval`'s authoritative
copy stays in NovaMemory (the local is a cache), so `syncOut` never
writes it. Inventory item X7 is why this care exists.

### The data-stack fast path

`hpush/hpop/hcpush/hcpop` are line-level mirrors of
`dpush/dpop/cpush/cpop` with dsp/csp in locals and the slot reached
directly in the buffer. Each raw access is guarded by EXACTLY the
generic accessor's own comparison (`addr <= ramSize-8` for 64-bit),
evaluated in the same order relative to the stack-limit check, and
the pointer is assigned only after the transfer — the same
check-then-transfer-then-assign order as the throwing originals.
Because the guard is the accessor's guard, the fast path needs no
separate "is this in the stack region?" test: it succeeds for
exactly the addresses `read64/write64` succeed for (stack region
included, arbitrary `DSPSET` targets included), and produces the
accessor's fault kind where the accessor would fault. The same
mirroring covers operand fetches (`frd8/16/32/64`, which never
advance `lpc` — callers advance after success, reproducing
`let x = try read(pc); pc &+= n`) and general loads/stores
(`hload*/hstore*`); the four MMIO-routing opcodes route at exactly
V1's addresses/conditions, with `mmioRead` evaluated BEFORE the
result push (V1 evaluates it inside the `dpush(...)` argument, so a
keyboard byte is consumed even if the push then overflows — mirrored).
MEMCPY reproduces `copyBytes`' guard verbatim (same five comparisons,
same wrapping `&+`, same `loadAccessFault`) and then does one raw
`memmove`.

### Fetch path — what was NOT restructured

Opcode fetch and operand fetches remain separate checked accesses,
in V1's order, for V1's stated reason (opt-core note): a faulting
operand must leave pc/cycle advanced past the opcode byte. The
hot loop removes the per-access FUNCTION/closure/throw overhead
around those accesses; it does not fuse them, pre-decode, or cache
an instruction window. A fetched opcode is read from the buffer at
`lpc` each iteration — no code cache exists, so self-modifying code,
overwritten code, and jumps into operand bytes all behave exactly as
in V1 by construction.

## Throw-site audit summary

Every throw site in V1 `step()` + the four stack primitives (32
distinct sites) was audited for (a) trap kind, (b) which state
mutations have already happened when it fires, (c) tval handling.
The full ordering contract is written at the top of the hot loop in
the variant file; the load-bearing cases:

| Site (V1) | Already mutated when it throws | Mirror |
|---|---|---|
| Timer (`step:125`) | `timerCount` reset to interval; pc/cycle NOT advanced; step still counts in `run()` | Loop-top check; `ltCount = ltInterval`, `used += 1`, exit `.trap` |
| Opcode fetch (`read8` at :137) | nothing (pc/cycle advance after the read) | Range check before any local changes |
| Operand fetches (all PUSH/branch/CALL/CSR cases) | pc/cycle past opcode only; `pc &+= n` runs after success | `frd*` don't advance; callers advance on success |
| `dpush` overflow (:61) | nothing — check precedes write, dsp assigned after write | `hpush`: limit check, range check, memcpy, then assign |
| `dpush` store fault (write64) | nothing (dsp unassigned) | same, `.storeAccessFault` |
| `dpop` underflow (:69) | nothing | `hpop` first check |
| `dpop` load fault (read64) | nothing (dsp assigned after read) | range check before assign |
| Div/rem-by-zero (:257 etc.) | BOTH pops done; no tval | pops via guard chain, then kind set |
| PUSHR/POPR bad index (:224, :228) | operand fetched + pc advanced; no pop (PUSHR) / no pop yet (POPR pops after the guard) | same order; `ltval = n` |
| Default illegal (:471-473) | pc/cycle past opcode | `ltval = opcode`, `.illegalInstruction` |
| CSRGET/CSRSET bad index (:439, :448) | CSRSET's value already popped; CSRGET nothing pushed; no tval | inner-switch default sets kind only |
| TRAP (:419-422) | operand fetched, pc advanced, tval = code | same |
| ECALL/EBREAK (:426, :428) | pc/cycle past opcode | kind only; vectoring reads synced pc |
| MEMCPY guard (Memory :185-189) | all three pops done | guard verbatim after three `hpop`s |
| LOAD64 MMIO + push overflow | keyboard byte already consumed by `mmioRead` | `mmioRead` called before `hpush` |

Multi-pop/push opcodes (DUP2, ROT, PUSHALL, …) use guard chains
(`guard let a = hpop(), let b = hpop(), hpush(b), …`) whose
left-to-right short-circuiting reproduces the sequential `try`
evaluation order exactly: a failure stops the chain with all prior
pops/pushes already applied — identical intermediate state.

Signed division/remainder expressions are copied verbatim
(`b / a`, `b % a` after the same `a != 0` guard), so even the
`Int64.min / -1` host-trap edge behaves as V1 does (both crash the
host identically; neither core guards it).

## Bail-to-step() cases

Exactly one: **ROLL (0x0F)**. It is the only opcode that
heap-allocates per execution (a `[UInt64]` temp, inventory X3) and
its mirror would need the same allocation plus n pops + n pushes
with mid-sequence trap states — mirroring is possible but it is the
highest transcription-risk body in the switch for an opcode no
golden program executes. Mechanism: at the TOP of each iteration,
before the timer check, the loop peeks the byte at `lpc` (only when
`lpc` is in RAM; a faulting `lpc` is not a bail and falls through to
the normal timer-then-fetch-fault order). If it is 0x0F, the loop
exits with state synced, 0 steps consumed for it, and `run()`
executes one real `step()` — which re-does the timer check first,
so a timer trap on a ROLL boundary fires instead of ROLL, exactly
as V1. Cost: one hot-loop exit/re-entry per ROLL (state sync ≈ 20
stores + array copy-back), negligible for a rare opcode. The switch
still contains a defensive 0x0F case (sets the bail flag) so the
switch is total if the peek is ever bypassed. HONEST GAP: no golden
program executes ROLL (verified by the Phase-1 opcode walk in the
harness README), so the gate does NOT exercise the bail path — it is
covered by construction (it literally runs V1's `step()`), not by a
golden. A future ROLL-using fixture would close this.

## Stack-top caching — what was NOT done, and why

No top-of-stack register caching was implemented. dsp-in-local +
direct buffer access shipped; a cached top element did not, because
the proof burden is exactly where this ISA bites:

- `DSPSET` (0x12) can move dsp to ANY address mid-run, and `PICK`,
  `LOADL/STORL/LOADARG`, `DEPTH`, `ENTER/LEAVE`, and every load/store
  can read or write the stack slot through computed addresses that
  alias the cached top — each would need an alias/flush proof.
- A cached top must be flushed with byte-exact trap state on every
  trap exit, call, MMIO access (host handlers can read/write guest
  RAM, including the stack), and bail — the flush points are
  enumerable, but a single missed one is a silent guest-visible
  corruption that the current goldens (which do exercise stack ops
  heavily) might still not catch in the aliasing cases above.
- The expected gain is one 8-byte load+store round trip per binary
  op on top of what locals+direct-buffer already remove; the risk/
  reward is wrong for a first hot-loop landing. Revisit only after
  hotloop is measured and gate-green, as its own variant.

## dispatch design

The dispatch variant is the hotloop file with the giant `switch`
replaced by a 256-entry table of `(UInt8) -> Void` closures, built
once per `hotRun` entry inside the loop closure (so handlers capture
the locals and helpers directly — that capture is the design: no
context struct, no parameter threading). Unassigned slots keep the
default handler (tval = opcode, illegalInstruction). Handler bodies
are the switch case bodies with `break` spelled `return`; flow
control after the call is the hotloop's own post-switch checks
(`pendingTrap` / `halted` / `bailRequested`). Expected to be SLOWER
than the switch in Swift — per instruction it pays an array bounds
check, a closure load, and an indirect closure call with captured-
context indirection, and the 256-closure table is rebuilt on every
`hotRun` entry (i.e. after every vectored trap re-entry too). It is
built to be measured and, in all likelihood, rejected on the record;
the sweep asked for the number, not the hope.

## Harness plumbing

`run.sh` gains two subcommands; existing subcommands are untouched
(new code is additive: one helper `build_harness_dir`, two command
functions, two dispatch lines, usage text). `gate-variant <dir>`
accepts a path or a bare variant name, builds `main.swift` +
variant `NovaCPU.swift` + variant `NovaMemory.swift` if present else
the vm-app memory, and diffs all CASES against the committed goldens
with the same PASS/FAIL table format as `gate`. `speed-all` builds
baseline, current, and every `variants/*/` directory (glob — later
variants need no script edits), times each on bench + galaxy at
speed mode's budgets (bench 200 M steps bare at 0x0; galaxy via
`set_case_args`), best of 5, one table per workload; a variant that
fails to build is reported and skipped with a nonzero exit at the
end. Verified here with `bash -n` and a stub-swiftc smoke test (no
Swift toolchain on this VM): both subcommands ran end-to-end, the
glob picked up all three variant dirs present (hotloop, dispatch,
and the pre-existing CPU-only predecode — which exercised the
memory-fallback path), and the gate table printed per-field diffs.

## Risks flagged for CI (the compile gate)

1. **Nested-function + closure surface (highest risk).** `hotRun`'s
   body is a trailing closure containing ~15 nested functions that
   capture and mutate local vars (`hpush` mutates `ldsp`,
   `pendingTrap`, …) and a nested `syncOut` that writes `self.*`
   explicitly. All standard Swift, but it is the newest idiom in the
   file; if swiftc objects anywhere, it will be here (variant
   NovaCPU.swift ≈ lines 583-1248). Fallback if a capture rule
   bites: convert the helpers from nested funcs to local closures
   (`let hpush: (UInt64) -> Bool = { … }`) — semantics unchanged.
2. **`withHotBuffer` generic + tuple return.** The closure is
   annotated `(UnsafeMutablePointer<UInt8>) -> (UInt64, HotOutcome)`;
   if type inference struggles, giving `hotRun` an explicit
   `let result: (UInt64, HotOutcome) = mem.withHotBuffer { … }`
   shape is the fix.
3. **Guard chains mixing bindings and Bool calls**
   (`guard let a = hpop(), hpush(a) else { break }`) — legal Swift,
   used heavily in both variants; also `guard` with `break` inside
   `for` loops inside switch cases / closures (POPALL). If any one
   form is rejected it will appear many times in the log — one
   systematic fix (rewrite as nested `if`s) covers all.
4. **memcpy/memmove pointer conversions** follow NovaMemory's own
   V1 patterns (`memcpy(&v, base + i, n)`), plus
   `memmove(buf + Int(dst), buf + Int(src), Int(n))` mirroring
   `copyBytes`. Low risk.
5. **Behavioural (gate) risks**, in descending order: the SAR case
   was restructured once during authoring (rewritten to the standard
   two-pop guard chain — re-check it first if ALU goldens diverge);
   timer interactions under `--firmware` runs are not covered by any
   golden (goldens pin the timer off / bare), so firmware-mode timer
   exactness rests on the audit, not the gate; the ROLL bail is
   unexercised by goldens (see above).
6. `speed-all` on CI will also build the pre-existing `predecode`
   variant (another lane's) — if that variant does not compile,
   `speed-all` reports it and exits nonzero even if AGG-A's variants
   are fine. Read the per-variant build lines before blaming this
   lane's code.
