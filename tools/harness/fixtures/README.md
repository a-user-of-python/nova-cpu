# Harness fixtures — vendored test inputs

The golden programs that live in the sibling `nova-programs/` tree are NOT
part of the nova-cpu repository, so CI could never check them out. They are
vendored here, verbatim, as test fixtures (test inputs are pinned by nature —
that is the point of a golden baseline).

| Fixture | Source (copied 2026-11-04) |
|---|---|
| `hi.nova` | `~/workspace/nova-programs/hi/hi.nova` |
| `bouncer.nova` | `~/workspace/nova-programs/bouncer/bouncer.nova` |
| `counter.nova` | `~/workspace/nova-programs/counter/counter.nova` |
| `galaxy_fixed.nova` | `~/workspace/nova-programs/galaxy/galaxy_fixed.nova` |
| `galaxy.bin` | `~/workspace/nova-programs/galaxy/galaxy.bin` (generator output of `gen_galaxy.py`; the sibling `galaxy.nova` is a placeholder template and cannot be assembled into a runnable program — see `../README.md`) |
| `examples_galaxy.bin` | `~/workspace/nova-cpu/examples/galaxy.bin` (nova-cpu `examples/`; the generator-produced canonical binary for the placeholder-template `examples/galaxy.nova`; sha256 `a1f8f91c8a3152586cd3523e0bef0bd59b8ff87e8658eb834e20ce9e0e4e11c6`, 1,480 B; vendored 2026-11-04 because `examples/galaxy.bin` is not part of the pushed tree, so CI could never check it out) |
| `bench.bin` | `~/workspace/nova-programs/bench/bench.bin` (sha256 `3040c56c618ebc812306b91341bdee3676f80de4c8783484c9a2d2b7fed765ce`, md5 `6b299ebec56f11daa6b7a4107556dce3`, 1,847 B; vendored 2026-11-04) — **SPEED-ONLY workload, never a golden**: `run.sh speed` times it bare at `0x0`; it is deliberately absent from the golden manifest because its printed rates derive from `RDTIME` (wall clock), so its console bytes are non-deterministic (its cycle count is deterministic) |

## Added fixtures (not vendored — written for the harness)

| Fixture | Source |
|---|---|
| `selfmod.nova` | Written 2026-11-04 for the v0.0.70 Phase-1 escalation (lane AGG-B): a self-modifying-code test that exposes stale decode caches. Original work, not copied from `nova-programs/`. |

### `selfmod.nova` — self-modifying code / decode-cache invalidation

Deterministic, self-halting (WFI), no input, no `RDTIME`/`RDCYCLE`/`RDRAND`
(audited: the source uses none, and the assembled code region — the whole
116-byte binary is code — contains no `0xCB`/`0xCC`/`0xF4` opcodes).
Run it bare at load address `0x0` (like `hello`/`hi`):
`nova-harness --program selfmod.bin --load-addr 0 --steps 1000000`.

**Addressing:** `novas.py` resolves `PUSH64 <label>` to the label's absolute
byte address (assembler pass 2, `PUSH64` case), and labels are offsets from
the binary start, so under the bare `0x0` load the assembled value is the
runtime address — no generator patching, no hand-computed offsets. Each
patch stores one byte at `<label of a PUSH8 opcode> + 1`, i.e. it rewrites
that PUSH8's immediate. Assembled layout (verified by disassembly of the
assembled binary): `p1a_push` at 31 (immediate byte at 32), `p2_push` at 58
(immediate byte at 59), `p1b_push` at 110 (immediate byte at 111),
`CALL p1b_body` targets 110, binary length 116 bytes.

**Program:** prints a fixed header `S`, one result character per phase,
and a fixed footer `K\n`:

- **Phase 1a (patch + fall-through):** the patching `STORE8` and the patched
  `PUSH8 65` ('A') sit in one straight-line run with no branch between
  them. The store rewrites the immediate to 67 ('C') moments before
  execution falls into it. A block cache that decoded the run before the
  store must invalidate its own in-flight block.
- **Phase 1b (patch the not-yet-executed, then CALL it):** `p1b_push`
  (`PUSH8 65`) has never executed when its immediate is rewritten to 66
  ('B'); a `CALL` then enters it and it returns. Catches eager decoders
  (whole-program pre-decode, superblocks spanning the CALL).
- **Phase 2 (patch the already-executed, loop re-entry):** `p2_loop` runs
  `PUSH8 68` ('D'), prints 'D', patches its own immediate to 69 ('E') and
  loops back to the same block head. The second iteration must print 'E'.
  Kills caches that invalidate only on first decode and any persistent
  cache with no store invalidation.

**Expected golden (from the baseline switch interpreter, which has no
cache and therefore always sees fresh bytes):**

- Console: `SCBDEK\n` — bytes `[83, 67, 66, 68, 69, 75, 10]` (7 bytes).
  Stale-decode failures are distinguishable by position: phase 1a stale →
  `A` in position 2, phase 1b stale → `A` in position 3, phase 2 stale →
  second loop character repeats `D` (`SCBDDK\n`).
- Cycles: **61**. Hand trace (count = executed instructions, 1 cycle each,
  WFI included): setup 2 + header print 3 + phase-1a patch 5 + phase-1a
  print 3 + phase-1b patch 5 + `CALL` 1 + phase-1b body 4 + phase-2 init 2
  + iteration 1: 11 + patch block 6 + iteration 2: 12 (incl. the exit
  `JMP`) + footer 6 + `WFI` 1 = 61. Cross-checked with an independent
  Python simulation of the assembled binary: console `SCBDEK\n`, 61
  cycles, balanced data/call stacks at halt, all three patched bytes
  landed (mem[32]=67, mem[59]=69, mem[111]=66).
- Halt: `wfi` (final `pc = 0x6e`, one past the `WFI` at 109).

Refresh procedure (only when a golden bump is intended):

```bash
cp ~/workspace/nova-programs/hi/hi.nova               fixtures/hi.nova
cp ~/workspace/nova-programs/bouncer/bouncer.nova     fixtures/bouncer.nova
cp ~/workspace/nova-programs/counter/counter.nova     fixtures/counter.nova
cp ~/workspace/nova-programs/galaxy/galaxy_fixed.nova fixtures/galaxy_fixed.nova
cp ~/workspace/nova-programs/galaxy/galaxy.bin        fixtures/galaxy.bin
cp ~/workspace/nova-cpu/examples/galaxy.bin           fixtures/examples_galaxy.bin
cp ~/workspace/nova-programs/bench/bench.bin          fixtures/bench.bin
# then regenerate goldens:  ../run.sh baseline   (and commit the new goldens)
```
