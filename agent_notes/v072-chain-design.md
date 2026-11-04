# NOVA v0.0.72 — Phase 3 JIT block chaining design

Date: 2026-11-04. Status: DESIGN (implementation spec for the
chaining lane). Builds directly on agent_notes/v071-jit-design.md
(§3 block shape, §4 J-rules, §5 exactness) and the shipped
v0.0.71 code. Nothing in this design touches NovaCPU.swift,
NovaMemory.swift, the interpreter, the probe, the D3 console
callout, run.sh, or main.swift. The ONLY file that changes is
NovaJIT.swift (both copies, kept byte-identical).

## 0. Problem and baselines

v0.0.71 JIT (CI host macos-26-arm64, best of 5, run 41901995849):
bench 50,514,754 ips (interpreter 215,558,619; original
11,085,094), galaxy 2,803,663 ips (interpreter 7,827,588;
original 2,623,822). Every compiled block returns to the Swift
trampoline, which per dispatch pays: syncIn (~40 field copies),
the §5.3 limit computation, a dictionary lookup, the
withHotBuffer closure, the call, timer settle, syncOut (~40
copies), and the reason switch. Chaining removes that round-trip
for block-to-block transfers: a block whose successor is already
compiled jumps straight into the successor's code.

## 1. Shape of the solution

- Each chainable block exit (catalogue in §4) is emitted as a
  branch to a per-site **chain stub** inside the same block's
  code, with the target guest pc in **x9** (baked constant for
  direct exits; copied from the target register for dynamic
  exits).
- The stub consults a per-run **link table** (raw heap buffer,
  48-byte slots, §3). A slot is valid iff its stored generation
  equals the run's current link generation and (for dynamic
  sites) its stored target pc equals x9. On a hit the stub
  settles the finished block's accounts, computes the
  successor's §5.3 limit exactly as the trampoline would, and
  `br`s to the successor's **chained entry** (the point in the
  successor's code immediately after its prologue).
- On any miss (no link, stale generation, chain cap reached,
  defensive timer corner) the stub performs the ordinary `.next`
  exit: state.pc = x9, reason 0, branch to the block's fold
  label. The trampoline then dispatches exactly as v0.0.71 did —
  and fills the site's slot (pass-through linking, §5), so the
  next traversal of the same edge chains.
- Invalidation is by **generation**: the trampoline bumps the
  link generation on every cache flush (rules J4/J5/J7 and
  DSPSET/CSPSET flushes all go through the one flushCache
  function). Every slot from an older epoch is instantly stale;
  no slot ever needs individual clearing, and J7 pool recycling
  (which always follows a flush) can never be reached through a
  stale slot.

## 2. JitState additions (appended slots, offsets 384…448)

Existing layout (0…376) is unchanged. New slots:

| off | field | meaning |
|----:|-------|---------|
| 384 | maxSteps | run budget (trampoline-seeded per dispatch) |
| 392 | chainStepsUsed | stepsUsed as of the current block's entry, maintained across a chain |
| 400 | chainTimerCount | live guest timer countdown as of the current block's entry (meaningful only when armed) |
| 408 | timerInterval | run's timer interval (0 = disarmed) |
| 416 | linkTable | host address of the link-table buffer |
| 424 | generation | current link generation |
| 432 | runDelta | guest instructions executed by earlier blocks of this trampoline segment |
| 440 | chainCount | blocks entered by chaining in this segment (cap + stats) |
| 448 | exitEndFlags | end-mode flags of the most recently ENTERED block (bit0 endFlushes, bit1 endIsCap, bit2 endIsTerminator) |

Add the matching stored properties to JitState, the JitOff
constants, and verifyLayout() checks. syncIn/syncOut do NOT
touch the new slots (they are trampoline/JIT-internal, exactly
like jitLimit/limitReason).

**Fold change (compiler):** the common fold now writes
`lastDelta = runDelta + x20` instead of `lastDelta = x20`. The
trampoline seeds runDelta = 0 at every dispatch, so an
unchained segment reports exactly what v0.0.71 reported; a
chained segment reports the whole chain's instruction count,
which is precisely what the trampoline's stepsUsed / timer
settle / nativeInstructions accounting consumes.

## 3. Link table

Slot layout (6 × UInt64 = 48 bytes), index = siteId:

| +0 | entry | host address of the successor's chained entry (0 = empty) |
| +8 | target | guest pc of the successor block |
| +16 | insnCount | successor's instructionCount (for the limit computation) |
| +24 | generation | epoch this slot was filled in |
| +32 | endFlags | successor's end-mode flags (same packing as exitEndFlags) |
| +40 | reserved | 0 |

Site ids are per-run, allocated by the trampoline from a single
counter and handed to each compile (`firstSiteId`); the compiler
returns the sites it created plus its next free id, and the
trampoline advances its counter by the consumed count even when
compilation fails (ids are never reused within a run — a reused
id could resurrect a filled slot for the wrong edge).

Capacity starts at 8192 slots and doubles when a compile would
overflow (checked before each compile, margin 16). The buffer
is a raw `UnsafeMutablePointer<UInt64>` reallocated on growth;
state.linkTable is re-seeded at every dispatch, and growth only
ever happens at dispatch time (compilation), never mid-segment,
so generated code always sees a stable base within a segment.

## 4. Compiler changes

### 4.1 Emitter

Add one helper (encoding cross-checked against the AArch64
manual: BR Xn = 0xD61F0000 | Rn<<5):

```swift
func br(_ rn: Int) { emit(0xD61F0000 | (UInt32(rn) << 5)) }
```

### 4.2 Chained entry point

In compile(), record `chainedEntryWordIndex = em.words.count`
immediately after the prologue's final load
(`em.movReg(20, 31)` — delta = 0). A chained jump lands there:
the host stack frame pushed by the segment's first block is
still active (identical push/pop pairs make the successor's
epilogue balance it), x19–x28 already hold exactly what the
prologue would have loaded (x24 is set by the chain stub, §4.4;
x20 was zeroed by the chain stub). Record
`block.chainedEntryOffset = chainedEntryWordIndex * 4`.

### 4.3 Chainable exits

`emitExitNext(target:chain:)` / `emitExitNextDynamic(reg:chain:)`
gain a `chain` parameter (default false). With chain = true the
exit registers a chain site and emits:

- static: `loadImm64(9, target); b(chainStubLabel)`
- dynamic: `movReg(9, reg); b(chainStubLabel)`

Chain = true ONLY at these call sites (line numbers from the
v0.0.71 file): JMP (1816), JMP32 (1821), BZ both exits
(1830/1832), BNZ (1841/1843), BEQ (1854/1856), BNE (1867/1869),
CALL (1876), CALL32 (1883), CALLI dynamic (1890), RET dynamic
(1895), JMPI dynamic (1900), LOOP both exits (1911/1913), and
the 64-instruction cap fallthrough stub in compile() (target =
the block's endPc).

Chain stays FALSE (plain v0.0.71 exit) for: DSPSET (1468),
CSPSET (1566) — both flush after executing (rule J2), CSRSET
(1980) and MRET (1945) — both write status, so the successor's
§5.3 entry conditions must be recomputed by the trampoline, the
WFI exit, and the non-cap/non-terminator fallthrough stub (a
foreign instruction is pending; the trampoline must
single-step it).

### 4.4 The chain stub (new JitStubKind case `.chain(siteId:)`)

Emitted with the other per-site stubs. Entry contract: x9 =
target guest pc, x20 = the finished block's delta, x19–x28 as
at any block exit. Scratch: x10–x15 only. Sequence:

1. **Cap check.** `chainCount >= 128` → miss. (Parity with
   design §5.5: a segment is then ≤ 129 blocks ≤ 8256 guest
   instructions between trampoline sync-outs — hotloop's
   writeback cadence is 8192.)
2. **Slot lookup.** slot = linkTable + siteId*48 (siteId*48
   baked via loadImm64). Miss if slot.generation ≠
   state.generation, slot.target ≠ x9, or slot.entry == 0.
   Keep slot pointer in x10 and entry in x11 from here on.
3. **Settle accounts** (hit path only): state.cycle += x20;
   state.runDelta += x20; state.chainStepsUsed += x20;
   state.chainTimerCount −= x20; then x20 = 0.
4. **chainCount += 1**; state.entryStatus = state.status
   (coherence). state.exitEndFlags = slot.endFlags is stored
   only at the very end of the hit path, just before the br —
   NOT here (coordinator review fix during implementation):
   the step-5 defensive corner exits via the fold after this
   point, and on that path the flags must still describe the
   block that is exiting, not the successor's.
5. **Successor limit** (the trampoline's §5.3 formula,
   evaluated with the settled values):
   budgetAllow = state.maxSteps − state.chainStepsUsed;
   timerAllow = (state.timerInterval > 0 && state.status & 1
   != 0) ? state.chainTimerCount − 1 : UInt64.max — with the
   defensive corner chainTimerCount == 0 while armed exiting
   via the ordinary .next path (accounts already settled,
   x20 = 0, so the fold presents lastDelta = runDelta; the
   trampoline emulates the firing exactly as at a dispatch).
   limitReason = budgetAllow ≤ timerAllow ? 6 (.budgetLimit)
   : 5 (.timerLimit), stored to state.limitReason;
   x24 = min(slot.insnCount, budgetAllow, timerAllow), also
   stored to state.jitLimit.
6. **`br x11`.**
7. **Miss / corner:** state.pc = x9; w0 = 0 (reason .next);
   branch to foldLabel. (On the early miss paths x20 and
   runDelta are untouched; on the corner path both are already
   settled and x20 = 0. The one fold formula,
   lastDelta = runDelta + x20, is correct for both.)

### 4.5 CompiledBlock additions

`chainSites: [JitChainSite]` (siteId, target for static sites,
isDynamic flag) and `chainedEntryOffset: Int`. JitChainSite is
a small struct defined beside CompiledBlock.

## 5. Trampoline changes

- Own: link table buffer + capacity (§3), `nextSiteId`,
  `linkGeneration` (starts at 1; 0 means "empty slot").
- flushCache additionally does `linkGeneration &+= 1` (wrapping
  guarded away from 0). This is the ONLY invalidation the link
  table needs: every event that can stale a compiled block —
  J1 .invalidated exits, J4 fault flushes, J5 single-step
  flushes, J2 DSPSET/CSPSET flushes, J7 pool recycle — already
  funnels through flushCache.
- Per dispatch, after syncIn and alongside the existing
  jitLimit/limitReason seeding: state.maxSteps = maxSteps;
  state.chainStepsUsed = stepsUsed; state.chainTimerCount =
  cpu.memory.timerCount; state.timerInterval = interval;
  state.linkTable = table base; state.generation =
  linkGeneration; state.runDelta = 0; state.chainCount = 0;
  state.exitEndFlags = endFlags(of: the dispatched block) —
  seeded inside the buffer closure where blk is known, next to
  the jitLimit seeding.
- The compiler is constructed with `firstSiteId: nextSiteId`;
  after every compile attempt (success or failure),
  `nextSiteId = compiler.nextSiteId`. Before compiling, grow
  the table if nextSiteId + 16 > capacity.
- **fillLinks(for:observedPc:reason:)** — for each site of a
  block: static sites use their baked target; a dynamic site
  uses observedPc, and only when the segment's reason was
  .next (the dynamic exit was the one taken — a block has at
  most one dynamic exit site, its terminator). If the target
  is in the cache, write the slot (entry = pool.base +
  target.poolOffset + target.chainedEntryOffset, target,
  insnCount, current generation, endFlags). Called (a) right
  after a block is compiled (dynamic sites skipped — pass a nil
  observed pc), and (b) after every dispatch segment, for the
  block that started the segment, with the segment's reason and
  state.pc. This is pass-through linking: the first traversal
  of an edge pays the trampoline once, every later one chains.
- **Stats:** after a segment, `stats.blockEntries += 1 +
  state.chainCount` (chainCount counts the chained entries).
  JitStats gains NO new fields — the harness stats line and its
  format stay byte-identical to v0.0.71.
- **The .next switch case reads the end-mode from
  state.exitEndFlags, not from blk**: bit0 → flushCache; bit1
  or bit2 → continue (re-dispatch at state.pc); neither →
  single-step if budget remains. This is the one place the
  last-entered block (not the segment's first block) decides,
  and it is what makes a chain that ends inside a DSPSET block
  still flush, and a chain ending at a foreign fallthrough
  still single-step. For an unchained segment the seeded value
  equals blk's flags, so v0.0.71 behaviour is preserved
  bit-for-bit.

## 6. Exactness arguments (why this cannot diverge)

- **Cycle accounting.** The fold change (§2) plus the stub's
  settle step keep the invariant "state.cycle counts every
  begun instruction exactly once, at the same point step()
  counts it". RDCYCLE inside a chained block reads
  state.cycle + x20, where the stub folded all predecessor
  deltas into state.cycle and zeroed x20 before the jump —
  the same value the interpreter would push.
- **Timer.** Within one segment the armed bit cannot change:
  the only status writers (CSRSET, MRET) end their block with
  a non-chain exit to the trampoline, and timerInterval can
  only change via MMIO, which single-steps (segment ends).
  The stub's countdown mirror (chainTimerCount, settled per
  block) therefore tracks step()'s per-instruction checks
  exactly, each chained block gets the same limit and
  limitReason the trampoline would have computed, and the
  trampoline's own settle (`timerCount -= lastDelta`, with
  lastDelta now the segment total) lands on the same value:
  per-block deltas satisfy deltaᵢ ≤ timerAllowᵢ, so the total
  never underflows the countdown. The budget side is the same
  argument with chainStepsUsed: chained blocks can collectively
  reach but never pass maxSteps, and a mid-chain budget
  exhaustion exits through the successor's own limit stub with
  reason .budgetLimit and the exact budget-prefix state.
- **Invalidation (J1).** A store's inline interval check is
  unchanged and still exits .invalidated from inside the
  storing block — never through a chain stub. A chain is only
  followed when every store so far in the segment passed the
  check against the cache interval, which covers every cached
  block including all possible chain successors. After any
  flush the generation bump kills every link before the next
  dispatch can fill or follow one.
- **J4/J5 events end segments.** Faults, single-step bails
  (MMIO peeks, DIV-pair bail, ROLL/MEMCPY and foreign heads),
  WFI, and both limit reasons are produced by stubs inside the
  block that owns them and return to the trampoline exactly as
  in v0.0.71; chaining only replaces the .next re-dispatch.
- **exitEndFlags.** Every entry into a block — by trampoline
  dispatch (seed) or by chain (slot copy) — installs that
  block's end-mode flags before its first instruction runs, so
  whenever a .next exit reaches the trampoline the flags
  describe the block that actually exited.
- **Selfmod.** Its two invalidations come from J1 exits inside
  the patching blocks; chaining neither adds nor removes a J1
  check, so the recorded count (2) is preserved, and the
  post-flush recompiles re-link by pass-through.

## 7. Gates for this lane

1. `gate-variant jit` — 9/9 incl. selfmod, engine_active=jit on
   every case, singleSteps = 0 on goldens (as J4/J5 recorded),
   selfmod invalidations = 2.
2. `gate-variant vm-app/NovaVM/VM` after promotion — same.
3. Plain `gate` — 9/9 (interpreter path untouched).
4. `speed-all` — chained JIT (d3 on) bench + galaxy vs the
   §0 baselines. Ship judgement: the chained JIT must beat the
   v0.0.71 JIT materially on bench; if it cannot beat it or
   cannot keep the gate exact, v0.0.72 does not ship and the
   evidence is reported instead (coordinator's call, per the
   commission).
