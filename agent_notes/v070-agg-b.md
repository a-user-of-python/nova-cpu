# NOVA v0.0.70 — Lane AGG-B: "predecode" block-cache variant + selfmod fixture

Date: 2026-11-04. Files written (disjoint from AGG-A; `run.sh`, `main.swift`
and everything under `vm-app/` untouched; no commits):

- `tools/harness/fixtures/selfmod.nova` — new self-modifying-code fixture.
- `tools/harness/fixtures/README.md` — appended `selfmod` entry (only edit).
- `tools/harness/variants/predecode/NovaCPU.swift` — the variant core.
  `NovaMemory.swift` is **unchanged** (invalidation is handled entirely
  CPU-side), so the variant directory holds only the CPU file; the harness
  compiles it against the current `vm-app` `NovaMemory.swift`.
- This note.

No Swift toolchain on this VM (verified: no `swiftc`): the variant was
generated from the current V1 core by script so that everything outside
the additions is verbatim — `diff` against `vm-app/NovaVM/VM/NovaCPU.swift`
shows only a header banner, the predecode section, and the `run()`
replacement; `step()` is byte-identical (checked programmatically).
Braces/parens/brackets balance; public API is unchanged (additions are
`private`). CI is the compile + gate check.

---

## 1. The selfmod fixture (correctness bar, written first)

`fixtures/selfmod.nova`, 116 bytes assembled, bare at `0x0`, deterministic,
self-halting (WFI), no input, no `RDTIME`/`RDCYCLE`/`RDRAND` (source grep
clean; the whole binary is code and a length-accurate opcode walk finds no
`0xCB`/`0xCC`/`0xF4`).

**Addressing:** `novas.py` *does* let a program name a label as an
immediate — pass 2, `PUSH64` case: `if arg in labels: v = labels[arg]`.
Labels are offsets from the binary start and the harness loads bare
programs at `0x0`, so the assembled value is the runtime address. No
generator patching (the `gen_galaxy.py` idiom) and no hand-computed fixed
offsets were needed. Each patch stores one byte at
`<label of a PUSH8 opcode> + 1`, rewriting that PUSH8's immediate, using
the stack order `[value, address]` that `STORE8` expects (address on top;
idiom verified against `hi.nova`).

**Phases** (one result character each, framed by fixed `S` … `K\n`):

| Phase | What happens | Cache bug it exposes |
|---|---|---|
| 1a | Patch `PUSH8 65`→`67`, then **fall through** into it with no branch in between (patch store at byte 30, patched insn at 31) | A block decoded from `main` already holds the old byte; the store must invalidate the *in-flight* block, not just future lookups |
| 1b | Patch never-executed `p1b_push` (`PUSH8 65`→`66`, at 110), then `CALL` it | Eager decoders (whole-program pre-decode, superblocks spanning the CALL); the spec's literal case |
| 2 | Loop body `p2_push` (`PUSH8 68` at 58) executes, prints `D`, patches its own immediate to `69`, loops back to the same block head | Persistent caches with no store invalidation, and caches that invalidate only on first decode — iteration 2 must print `E`, not `D` again |

Phase 2 is the second phase the task asked for ("patch code already
executed once"); it was feasible without fragility because `PUSH64 p2_push`
makes the patch target exact, so both phases ship.

**Expected golden** (baseline switch interpreter — no cache, always fresh):

- Console: `SCBDEK\n` = bytes `[83, 67, 66, 68, 69, 75, 10]`, 7 bytes.
  Stale failures are position-distinguishable: 1a stale → `A` at index 1,
  1b stale → `A` at index 2, phase-2 stale → `SCBDDK\n`.
- Cycles: **61**, halt `wfi`, final `pc = 0x6E` (one past the WFI at 109).
- Hand trace (1 cycle per executed instruction, WFI included): setup 2 +
  header print 3 + 1a patch 5 + 1a print 3 + 1b patch 5 + `CALL` 1 + 1b
  body 4 + phase-2 init 2 + iteration 1: 11 + patch block 6 + iteration 2:
  12 (incl. exit `JMP`) + footer 6 + `WFI` 1 = **61**. Independently
  cross-checked with a Python simulation of the assembled binary: same
  console, 61 cycles, both stacks balanced at halt, and all three patched
  bytes verified in memory afterwards (mem[32]=67, mem[59]=69,
  mem[111]=66). Disassembly confirms patch sites: `p1a_push`=31 (imm 32),
  `p2_push`=58 (imm 59), `p1b_push`=110 (imm 111), `CALL`→110.

Note: the golden still has to be *generated* by `run.sh baseline` and the
case added to `run.sh`'s manifest — both are AGG-A/coordinator territory
(this lane does not edit `run.sh`); the values above are the prediction
the baseline run must reproduce.

## 2. Variant design: predecode

`run()` keeps V1's exact outer contract (same signature, same step
accounting — see §4) but executes from decoded basic blocks:

- **Block heads** = any pc control flow arrives at: initial entry, branch/
  call/return targets, and fallthrough past a block end. `fetchBlock`
  returns the cached block for a head or decodes one.
- **Decode** (`decodeOne`/`fetchBlock`): from the head, decode the
  straight-line run into `[DecodedInsn]` — each entry carries `pc`,
  `nextPC`, `opcode`, the fully parsed operand (`imm`: PUSH8/16/32
  sign-extended exactly as `step()` computes, or raw PUSH64; `n`: 1-byte
  operand; `target`: branch/call destination precomputed as
  `nextPC + offset` with `step()`'s wrapping arithmetic). Decode stops
  **after** the first control-flow instruction (`JMP/JMP32`, `BZ/BNZ`,
  `BEQ/BNE`, `CALL/CALL32`, `LOOP`, `RET`, `JMPI`, `CALLI`, `WFI`), at a
  bail-list opcode (excluded), at undecodable bytes (excluded), at the
  64-instruction cap, or before any instruction overlapping a stack
  region. Undecodable-at-head / bail-at-head / stack-region heads return
  nil → one `step()` → retry.
- **Execute** (`execDecoded`): mirrors `step()` case-for-case for the
  decoded set. Per instruction: `pc` := entry.pc, timer check (identical
  logic, so a timer trap vectors with `epc` at the interrupted
  instruction), `cycle &+= 1`, `pc` := entry.nextPC, then the body. Only
  decode is cached: stack, memory, flags, registers and `cycle` are all
  read live (loads read guest memory at execute time; `RDCYCLE` pushes
  the live counter, which already includes its own increment — same
  ordering as `step()`).

**Exactness of trap state.** A faulting body leaves `pc = nextPC`,
`cycle` incremented once, `tval` exactly as `step()` sets it (bodies are
copied; e.g. `DIV` by zero throws without touching `tval`, `PUSHR n≥16`
sets `tval = n`). An instruction whose *operand bytes* would fault is
never decoded (decode reads throw → block ends before it), so `step()`
reproduces the V1 unfused-fetch state (pc/cycle past the opcode byte —
the case the V1 note deliberately preserved). Illegal opcodes are
bail-listed, so their `illegalInstruction`/`tval` also come from
`step()` verbatim; `execDecoded`'s `default` re-throws the same trap as
a safety net and is unreachable by construction.

**Block-boundary policy.** One block = one straight-line run from one
head, ending at (and including) the first control transfer, ≤64 insns.
Conditional branches end the block whether taken or not (fallthrough
becomes a new head and may decode overlapping bytes under a second key —
a little duplicate decode, traded for a much simpler correctness story).
`WFI` ends a block (it clears `running`).

**Bail list** (end the block; executed by `step()`): `ECALL`, `EBREAK`,
`TRAP`, `MRET`, `CSRSET`, `RDTIME`, `RDRAND`, `CPUID`, `MEMCPY`, and every
opcode `step()` doesn't implement (`0x58–0x5B` MIN/MAX/CLZ/CTZ, `LOAD16`/
`LOAD32`, FP/SIMD/crypto, …). Rationale: traps and host-visible effects
stay on the one path that already gets them right; `RDTIME`/`RDRAND` are
non-deterministic anyway; `MEMCPY` writes an unbounded range that cannot
be range-checked cheaply (and the post-`step()` cache drop covers it).

## 3. Invalidation rule set (the whole ballgame)

The cache is **per-run**: built during `run()`, dropped when `run()`
returns, so host-side loads between runs (`loadBytes`, `storeHostBytes`)
can never go stale (rule (c) by construction).

- **(a) Guest stores from decoded code.** After every successful RAM
  write in `execDecoded` (`STORE8/16/32/64`, `STORL`), `noteGuestWrite`
  tests the written range against every cached block's byte range
  (O(1) bounding-interval reject first: `[cacheLo, cacheHi)`). On any
  intersection the **whole cache is dropped** and the executor abandons
  the current block after the storing instruction (`pc` already at
  `nextPC`), so the remainder re-decodes from fresh bytes. Whole-cache,
  not per-block: blocks are cheap to re-decode, stores landing in the
  code bounding region are rare in real workloads, and a missed overlap
  is a silent wrong-answer while a spare drop costs one re-decode.
  *Against selfmod:* phase 1a is exactly the in-flight case (store at 30
  patches byte 32, inside the block decoded from 0) → flush → `p1a_push`
  re-decodes as `PUSH8 67` → `C`. Phase 2's store patches block
  `[58, …)` which is cached → dropped → iteration 2 re-decodes → `E`.
  *Against the goldens:* `galaxy` writes only data past its code (writes
  fall outside the bounding interval or fail the exact check), `fib`/
  `hello`/etc. write stack + console only.
- **(a′) Stack writes are not individually checked — and cannot hit a
  cached block.** `dpush`/`cpush` (including `ENTER`, `CALL`, trap
  vectoring) write only inside the architectural stack regions, enforced
  by their limit checks; `fetchBlock` **refuses to cache any instruction
  overlapping `[dslim, dataStackBase)`, `[cslim, callStackBase)` or
  `[vslim, vectorStackBase)`**, so no cached byte is ever a push target.
  The one way to move a stack pointer is privileged `DSPSET`/`CSPSET`:
  both flush the cache on execution in `execDecoded`.
- **(a′′) MMIO stores flush.** `STORE8`/`STORE64` to the MMIO page run
  host code synchronously inside `mmioWrite` (file/net handlers), which
  can write guest RAM — so any MMIO store from a block drops the cache
  and ends the block. (Console stores pay this too; they end blocks in
  print loops, a deliberate correctness-over-speed choice — see §5.)
  MMIO *loads* do not flush: in both the app and the harness, handlers
  fire on command *writes*, reads only pop the keyboard queue / return
  device registers, never RAM.
- **(b) Every trap flushes.** `handleTrap` (the V1 vectoring logic,
  verbatim) drops the cache on all paths: vectored timer/ECALL traps
  resume in firmware that is itself guest code and may self-modify;
  unvectored traps run the host trap handler; and while the CPU is out
  of the interpreter, MMIO file activity (`READ` → host stores into
  guest buffers) may have rewritten anything.
  *Against the goldens:* `galaxy` ends in one `ECALL` (run ends anyway);
  `programs-galaxy`'s pinned context traps once at the end. Firmware
  mode pays a flush per timeslice — acceptable, a timeslice is 100k
  cycles.
- **(b′) Anything executed via `step()` flushes.** The fallback path can
  execute stores/`MEMCPY`/MMIO commands the block path never
  range-checked. It is the rare path by design, so `run()` drops the
  whole cache after every fallback step. This makes the invariant
  statable in one line: **decoded blocks are only ever trusted across
  consecutive block executions whose writes were all range-checked.**

## 4. Step-budget parity (budget-prefix goldens)

V1 charges one step per `step()` call, trap iterations included. The
block loop charges one step **per decoded instruction** (checked before
each instruction, incremented on success and on trap, mirroring V1's
placement), so `bouncer`/`counter` still halt mid-block at exactly
`maxSteps` instructions with `cycles == steps` and the exact console
prefix. `run()`'s signature and halt classification observables
(`running`, `pc`, `cycle`, `tval`) are unchanged.

## 5. Expected win mechanism

Per executed instruction in a hot block, the following V1 costs
disappear: the opcode `read8` + up to 8 bounds-checked operand byte
reads through `NovaMemory` (each a range check + `ContiguousArray`
access), the implicitly-unwrapped `memory` resolution per access, and
the re-parse/sign-extend of immediates and branch offsets. What remains
is an array index, a switch on a stored opcode byte, and the semantic
body (stack traffic through `dpush`/`dpop` is unchanged — that is the
floor this variant cannot go below without touching the stack model).
Loop-heavy code (`fib`, `bench`, the galaxy print loop) amortises each
block's single decode over every re-entry. Known give-backs: console
`STORE8`s flush per (a′′) — print-*character* loops re-decode their
block per character in the worst case (still no worse than V1 plus one
decode), and bail-heavy code (an `RDTIME` per bench iteration) pays a
`step()` + flush per bail. Both are correctness-first choices, flagged
here so a disappointing `galaxy`/`bench` speed number is not a surprise;
if speed mode shows the console flush dominating, the safe refinement is
to flush on MMIO stores only for the file/net command addresses and let
pure console-address stores pass (the console handler provably never
writes RAM) — not done pre-emptively, because it weakens rule (a′′) from
"any host code" to an argument about specific handlers.

## 6. Risks for CI (one fix round via coordinator)

1. **Mixed range/value patterns in `decodeOne`'s switch**
   (`case 0x05, …, 0x40...0x57, 0x5C...0x60, …`): standard Swift, but it
   is the least-idiomatic construct in the file; if `swiftc` objects,
   splitting that case into three cases is a mechanical fix.
2. **`for _ in 0..<d.n` with `d.n: UInt8`** copies `step()`'s own idiom
   (`0..<n` over a `UInt8` read from memory), so it should compile for
   the same reason the baseline does.
3. **Tuple-optional decode return** `(insn: DecodedInsn, terminal:
   Bool)?` with `throws` — plain Swift; the `do/catch` in `fetchBlock`
   assigns it into a pre-declared optional.
4. Behavioural risk concentrates in `execDecoded` body drift vs
   `step()` — mitigated by copying bodies verbatim and by the gate:
   any drift shows as a console/cycle/halt mismatch on the golden suite,
   and `selfmod` (once the coordinator adds it to the manifest and
   baselines it at 61 cycles / `SCBDEK\n`) pins the invalidation paths
   the existing goldens don't exercise.
