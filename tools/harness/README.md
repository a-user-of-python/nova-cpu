# NOVA golden-baseline harness

Phase 1 of the v0.0.70 optimization pass: a headless harness that runs guest
programs on the NOVA VM core exactly as the iOS app does, plus a frozen
snapshot of the current core and a set of golden outputs. Later optimization
work must pass `run.sh gate` — same console bytes, same cycle count, same
halt reason, for every program — before it can be called behaviour-preserving.

There is no Swift toolchain on the dev VM, so everything here runs on the
GitHub `macos-latest` runner via `.github/workflows/harness.yml`
(`swiftc` from Xcode; no SwiftPM/Xcode project, on purpose).

## Layout

```
tools/harness/
  main.swift          the headless runner (Foundation only)
  baseline/           VERBATIM snapshot of the pre-optimization core
    NovaCPU.swift       (copied from vm-app/NovaVM/VM/ on 2026-11-04,
    NovaMemory.swift     cmp-verified identical at copy time)
  fixtures/           vendored copies of the nova-programs test inputs
                      (that tree is not part of this repo — see fixtures/README.md)
  golden/             committed goldens: <program>.{console,cycles,halt}
  run.sh              baseline | gate | speed | build  (set -o pipefail)
  speed.py            timing helper for speed mode
  build/              scratch (gitignored): harness binaries, staged .bins, logs
```

## Headless compilation — no shims needed

`NovaCPU.swift` + `NovaMemory.swift` compile standalone with `main.swift`:

* Both core files import **Foundation only**.
* `NovaCPU` references only `NovaMemory` and `NovaTrap` (defined in
  `NovaMemory.swift`). `NovaMemory` references nothing app-side.
* Neither file touches `NovaVMEngine`, `NovaConfig`, `NovaFirmware`,
  `NovaFolders`, or `DeviceInfo`. Those are app concerns (UI, config files,
  firmware distribution) and the harness re-implements the *relevant boot
  behaviour* itself (below) rather than importing them.

So the baseline snapshot is a bit-for-bit copy of the shipping core, and the
gate builds the harness against the live `vm-app/NovaVM/VM/` files. If a
future core change introduces an app dependency, the gate build itself will
fail — which is the correct signal, and the fix is to keep the core
Foundation-only, not to grow a shim here.

Build command (what `run.sh` does):

```bash
swiftc -O -o nova-harness tools/harness/main.swift <NovaCPU.swift> <NovaMemory.swift>
```

## Boot replication decisions

`main.swift` mirrors `NovaVMEngine` (`vm-app/NovaVM/VM/NovaVMEngine.swift`)
wherever behaviour is observable by a guest:

| Aspect | App behaviour | Harness |
|---|---|---|
| RAM | `NovaConfig.default` = 64 MB → `NovaMemory(totalSize: 64 MiB)` | `--ram-mb 64` (default, same) |
| Stack/status init | `resetCPUState()`: dsp/csp/vsp from the memory layout, esp = vectorStackBase − 1 MiB, limits = base − 8 MiB (esp limit − 1 MiB), fp = 0, pc = 0, status = `(3<<2)\|1` | copied literally |
| Firmware + program | firmware at `0x0`, program at `0x1000`, entry `0x0` (`loadProgram`) | `--firmware F --program P` (program defaults to `0x1000`) |
| Program only | program at `0x0`, entry `0x0` (`boot()` with firmware off) | `--program P` (load addr defaults to `0x0`) |
| Fixed-address binaries | NovaShell `run` loads at `0x10000 + slot*64 KiB` | `--load-addr`/`--entry` per program (see manifest) |
| Console | guest MMIO bytes → `memory.consoleOutput` string chunks | same closure; raw bytes → `<program>.console` |
| Traps | engine trap handler records the trap and halts the VM | same; recorded as the `.halt` golden |
| File MMIO | LIST/READ/WRITE against the shared folder, `..`/`/` rejected, same size clamps | identical handler when `--sandbox DIR` is passed; no handler (→ −1, `NovaMemory`'s default) otherwise |
| Network MMIO | real HTTP via `URLSession` | **always −1 (offline)** — real HTTP is non-deterministic and cannot appear in a golden |
| Keyboard | UI pushes bytes into `memory.keyboardQueue` | `--input` / `--input-hex` / `--input-file` pre-loads the same queue before the run |
| Program size guard | `data.count < memorySize/2` else `programTooLarge` | same check |

Deliberate deviations (each is required for a deterministic golden, and each
is observable, so they are listed rather than hidden):

1. **Hardware timer is OFF by default in bare mode** (engine `resetCPUState()`
   arms it at 100 000 cycles). In the app, a bare program that runs past
   100 000 cycles with no firmware vector installed is *killed by a spurious
   timer trap* — an artefact of the shared reset path, not program behaviour.
   With firmware, the timer is the scheduler's timeslice and the firmware
   installs a vector + re-programs the interval itself, so `--firmware` mode
   defaults `--timer-interval` to the engine's 100 000 and everything after
   that is genuine firmware behaviour. Bare-mode runs can re-arm it with
   `--timer-interval 100000` to reproduce the app artefact exactly.
2. **The `[TRAP ...]` console annotation is not in the `.console` golden.**
   The engine appends `"\n[TRAP <n> tval=0x..]\n"` to the *UI text*; it is not
   guest output. The trap is captured in the `.halt` file instead
   (`trap:<case> tval=0x..`), so no information is lost.
3. **`NovaShell`-context values are pinned for `galaxy`** (see below).

Halt classification (`NovaCPU.run(maxSteps:)` returns nothing, so the reason
is reconstructed from observable state, in priority order):

* trap handler fired → `trap:<case> tval=0x..` (this includes
  `trap:illegalInstruction tval=0x..`; vectored traps — timer/ECALL with a
  firmware vector — never reach the handler, exactly as on device);
* `cpu.running` still true when `run` returns → `step-budget`;
* otherwise → `wfi` (WFI/`0xC5` is the only instruction that clears
  `running` inside `step()`).

## Programs, golden types, exclusions

| Case | Source | Load / entry | Budget (steps) | Golden type |
|---|---|---|---|---|
| `hello` | `examples/hello.nova` (assembled) | `0x0` | 1 000 000 | **exact** — ends in WFI |
| `fib` | `examples/fib.nova` (assembled) | `0x0` | 10 000 000 | **exact** — fib(20) printed, WFI |
| `galaxy_examples` | `examples/galaxy.bin` (generator output, staged verbatim) | `0x1000` | 5 000 000 | **exact** — static text, WFI |
| `hi` | `fixtures/hi.nova` (assembled) | `0x0` | 1 000 000 | **exact** — WFI |
| `galaxy_fixed` | `fixtures/galaxy_fixed.nova` (assembled) | `0x0` | 1 000 000 | **exact** — WFI |
| `galaxy` | `fixtures/galaxy.bin` (generator output, staged verbatim) | `0x10000`, R15=`0x10000` | 5 000 000 | **context-exact** — see below; ends in ECALL → `trap:ecallU` |
| `bouncer` | `fixtures/bouncer.nova` (assembled) | `0x0` | 20 000 000 | **budget-prefix** — infinite loop |
| `counter` | `fixtures/counter.nova` (assembled) | `0x0` | 40 000 000 | **budget-prefix** — infinite loop |

**Budget-prefix goldens** (`bouncer`, `counter`): these programs never halt
by design (they are NovaShell scheduler demos). The invariant is: *at exactly
N executed steps, the console prefix, the cycle count (== N) and
halt=`step-budget` are reproduced bit-for-bit.* Any core change that alters
instruction semantics or timing shows up as a prefix/cycle divergence. The
budgets are sized for ~2.5 animation frames each (bouncer's busy-wait is
1 M iterations ≈ 8 M steps/frame; counter's is 2 M ≈ 16 M steps/frame).

**Context-exact golden** (`galaxy`, the nova-programs one): this binary is
*not* a standalone program. Its generator (`gen_galaxy.py`) states it plainly:
it expects NovaShell's scheduler to load it at `0x10000`, set **R15 = load
address** (its data pointers are R15-relative), and maintain two firmware RAM
cells — `UPTIME` (addr 10164, tick counter) and `DATETIME` (addr 10172,
filled by the shell's *network* date sync). It finishes with `ECALL`,
expecting the scheduler to retire it. The harness therefore runs it in a
**pinned scheduler context**: loaded at `0x10000` in fresh (zeroed) RAM,
R15 = `0x10000`, timer off — i.e. the state a freshly booted shell presents
before its first timer tick, with `UPTIME` = 0 and `DATETIME` empty (offline:
date sync failed, exactly what the shell itself does with no network). Under
that pinned context the output is fully deterministic and byte-exact. What
this golden does *not* claim: on a real device under the live shell, the
`Uptime:`/`Date:` fields vary (uptime grows; the date comes from an HTTPS
time API, i.e. ultimately the wall clock). Those two fields are the shell's
data, not the program's computation; everything else — all ~9 KB of rendered
art and specs — is the program's own deterministic output.

**Why the galaxy `.nova` files are not assembled directly:** both
`examples/galaxy.nova` and `nova-programs/galaxy/galaxy.nova` are placeholder
*templates*. Their `PUSH64` immediates are magic values (`0xDEADBEEFCAFEBABE`,
`0xFEEDFACEDEADBEEF`, `0xAAAAAAAAAAAAAAAA`, …) that `gen_galaxy.py` patches
with the real console/data addresses before appending the text data after the
code. Assembling the template with `novas.py` produces a binary that traps
with a load-access fault on its first printed byte. The canonical runnable
artifacts are the generator-produced `.bin` files, so the runner stages those
verbatim. (The nova-programs `galaxy_bare.bin` variant is not used: it is an
undocumented second build of the same program; the canonical `galaxy.bin` is
the one the generator writes and the README describes.)

**Exclusions:**

* **`novashell` (`shell.nova`/`shell.bin`) — EXCLUDED: it is firmware, not a
  program.** Its README says so ("It *replaces the default firmware*: it
  loads at address `0x0`"), `gen_shell.py` generates it as the firmware
  image, and its binary is (a close variant of) the app's built-in
  `NovaFirmware` image. It is also interactive (polls the keyboard forever,
  never halts) and its boot path performs a *network* date sync, so no
  deterministic golden exists for it. The harness can boot it for manual
  experiments: `nova-harness --firmware shell.bin --sandbox <dir>
  --input $'help\n' --steps …`.
* No golden program needs keyboard input in its pinned context — all input
  paths above are pre-scriptable via the keyboard queue, but every program
  in the manifest runs to its golden with an empty queue (verified from
  source: none reads `KEYBOARD_IN`).

## Determinism audit

Method: (1) `grep` for `RDTIME`/`RDCYCLE`/`RDRAND` mnemonics in every
`.nova` source and every generator `.py`; (2) a linear opcode walk
(instruction-length-accurate disassembly) over every assembled/generated
binary's *code* region, counting opcodes `0xCB` (RDTIME), `0xCC` (RDCYCLE),
`0xF4` (RDRAND) — raw byte counts are meaningless here because immediates and
text data contain those byte values as data.

Findings:

* **No program in the manifest executes `RDTIME`, `RDCYCLE`, or `RDRAND`.**
  Source grep: 0 occurrences in all eight sources and both galaxy
  generators. Opcode walk: 0 occurrences in every code region
  (hello 51 B, fib 121 B, hi 27 B, bouncer 225 B, counter 165 B,
  galaxy_fixed 137 B, examples-galaxy code 63 B, programs-galaxy code 321 B).
  NovaShell's firmware source is also clean (5 500 B of code walked, 0
  occurrences) — its uptime is a timer-tick counter, not `RDTIME`.
* `RDCYCLE` would have been safe anyway (it returns `cpu.cycle`, fully
  deterministic). `RDTIME` returns host wall-clock microseconds
  (`Date().timeIntervalSince1970`) and `RDRAND` returns host randomness in
  `NovaCPU.swift` — any future program using either must get a masked /
  invariant golden, never a byte-exact one.
* The one genuine wall-clock coupling is **indirect**: programs/galaxy reads
  the firmware's `DATETIME` cell, which the live shell fills from an HTTPS
  time API. Handled by the pinned context above, and disclosed there.
* Everything else that could vary is pinned: RAM size (stack bases derive
  from it), step budgets, input queues (empty), file/network MMIO (offline),
  timer (off / pinned).

## Running it

Locally there is no Swift toolchain, so the supported path is CI
(`.github/workflows/harness.yml`, `macos-latest`):

* **Regenerate goldens:** Actions → “NOVA Harness (golden baseline)” →
  Run workflow → mode `baseline`. Downloads: `nova-goldens` artifact.
  Commit its contents into `tools/harness/golden/` to make them the gate.
  (The first baseline run is expected to be committed as-is: baseline and
  current cores are identical at Phase 1, so `gate` must pass immediately
  after.)
* **Gate:** mode `gate`, and automatically on every push touching
  `vm-app/NovaVM/VM/**`, `tools/harness/**`, `examples/**`, or `novas.py`.
  Exit code is non-zero on any mismatch; the log prints a per-program
  PASS/FAIL table with the differing field (console / cycles / halt).
* **Speed:** mode `speed`. Times baseline vs current on `fib`
  (compute-bound, runs to WFI), `galaxy` (print-heavy, ~9 KB of console) and
  `bench` (speed-only workload, see below), best of 5 whole-process runs
  each, printing guest cycles, wall time and instructions/sec for each core.
  Short runs are noise-prone — compare the baseline/current ratio, not
  absolute IPS.

**`bench` — speed-only, never a golden.** `fixtures/bench.bin` (vendored
from `nova-programs/bench/`, sha256
`3040c56c618ebc812306b91341bdee3676f80de4c8783484c9a2d2b7fed765ce`) is timed
by `run.sh speed` only: bare mode, loaded at `0x0`, 200 M step budget (it
executes ~50.5 M instructions and halts WFI). It is deliberately **not** in
the golden manifest (`CASES` in `run.sh`) and must never join the gate: its
printed rates derive from `RDTIME` (host wall clock — see the determinism
audit), so its console bytes are non-deterministic, even though its cycle
count is deterministic. Only its instructions/sec is a meaningful harness
output.

On any Mac with Xcode, the same commands work directly:

```bash
bash tools/harness/run.sh baseline   # regenerate goldens from the snapshot core
bash tools/harness/run.sh gate       # diff current core against goldens
bash tools/harness/run.sh speed      # baseline vs current instructions/sec
bash tools/harness/run.sh build      # compile-check the current core only
```

Manual harness invocation (flags in `main.swift`, `--help` prints usage):

```bash
tools/harness/build/nova-harness-current \
  --program program.bin --load-addr 0 --steps 1000000 \
  --console-out out.console --meta-out out.meta
# meta file: cycles=, halt=, trap_raw=, steps_budget=, console_bytes=, pc=
```

## Golden discipline

* A golden change is a *behaviour change claim*: regenerate only with
  `run.sh baseline` (snapshot core) or by deliberately re-baselining, and say
  which programs changed and why in the commit/PR.
* Never edit a golden file by hand.
* Adding a program: add its fixture/source, a `CASES` entry and a
  `set_case_args` entry in `run.sh`, audit it for `RDTIME`/`RDRAND` first,
  and document its golden type in the table above.
