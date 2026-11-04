# NOVA v0.0.70 — Lane OPT-APP: app-side optimization (Phase 2)

Date: 2026-11-04. Files edited (only these, in place, no commits):
`vm-app/NovaVM/VM/NovaVMEngine.swift`,
`vm-app/NovaVM.xcodeproj/project.pbxproj`, `vm-app/NovaVM/Info.plist`.
Not edited: `NovaCPU.swift` / `NovaMemory.swift` (core lane), `VMView.swift`
(view-side ideas flagged in §5 only). No Swift toolchain on this VM — the CI
build is the compile gate. Escalation applied (Sean, 2026-11-04 09:00 ET:
"as optimized as possible while still making everything work") — see the
parameter choice in §1.3.

---

## 1. Console batching (recon item (a)2 — the "graphics like text" fix)

### 1.1 What changed

Before: `memory.consoleOutput` (fires on the VM thread, once per character
from `NovaMemory.mmioWrite`'s UTF-8 assembly) dispatched
`DispatchQueue.main.async { consoleText += s; cap-check }` **per
character** — one main-queue hop + one `@Published` mutation per char, and
each publish triggers `VMView`'s full-string `ANSIRenderer` rescan.

After (all in `NovaVMEngine.swift`):

- `consoleOutput` now calls `enqueueConsole(_:)`, which runs **on the VM
  thread**: under an `NSLock` it appends the string to `consoleBuffer`
  (a plain, non-`@Published` `String`) and bumps `consoleBufferCount`
  (tracked incrementally so the hot path never pays `String.count` on
  the whole buffer per character).
- `flushConsoleBuffer()` runs on the main queue and publishes the whole
  buffer in **one** `consoleText += chunk`, then applies the cap (§1.2).
  It swaps the buffer out under the lock, so VM-thread appends during a
  flush land in the next chunk — no loss, no reordering (single FIFO
  buffer, appends serialized by the lock, flushes serialized on main).
- Scheduling: the first enqueue with no flush pending queues a timed
  flush after `consoleFlushInterval`; reaching `consoleFlushThreshold`
  queues an immediate flush. A `consoleFlushASAPPending` flag coalesces
  threshold flushes, so during a flood the VM thread cannot enqueue a
  redundant main-queue block per character while main is busy rendering.

### 1.2 Cap-rule equivalence (the subtle part)

Today's rule, per append: `if count > 100_000 { keep suffix(90_000) }`.
**Applying that rule once per flush chunk is NOT equivalent to the
per-character path**, despite first appearances. Counterexample: console
at 99,999 chars, one 4,096-char chunk. Per-character: the count reaches
100,001 at chunk char 2 → trim to 90,000 → remaining 4,094 chars append →
final **94,094** chars. Naive per-chunk: one trim at the end → **90,000**
chars. Different final text whenever a chunk crosses the cap boundary
mid-chunk (any chunk ≥ 2 chars can do this).

So the flush keeps the rule's constants and shape (append once; if the
count exceeds 100_000, replace with a suffix) but computes the keep-count
with `cappedConsoleLength(existing:appending:)`: pure integer arithmetic
that simulates the per-character length trajectory — chars to reach
100,001 → drop to 90,000 → repeat — in O(number of trims), then takes a
single `suffix(keep)`. This reproduces the per-character end state
**exactly for any chunk size and any starting state**, including the
over-cap state the trap handler can create (its line appends with no cap
check; the `len > 100_000` branch of the simulation covers it: the next
character trims back to 90,000, as the old code did).

Verification (no Swift toolchain, so done as a Python model of both
algorithms over unique-token streams): 307 cases — hand-picked
boundaries (99,999+4,096; 90,000+10,001/10,002; 100,000+1; 0+250,000;
50,000+3×60,000) plus 300 randomized (existing 0…100,050, 1–6 chunks of
1…20,000) — **0 mismatches in final length or final content**.

Granularity note: `NovaMemory` delivers one `String` per completed UTF-8
sequence (a single Character in all valid-UTF-8 output), so the old path
was per-Character in practice and the equivalence above is at Character
granularity, matching both sides' `.count` semantics. The only exception
is `NovaMemory`'s forced flush of >8 buffered *invalid* bytes, which can
deliver a multi-Character string as one unit; if such a unit ever
straddled the 100k boundary, the old code would have trimmed one append
later than the new code. Guest output is text/ANSI (valid UTF-8); this
pathological corner is accepted and recorded here rather than hidden.

### 1.3 Parameters (escalation tuning)

- **Interval: 100 ms** (`consoleFlushInterval = 0.1`) — top of the
  50–100 ms band in the original task. Publish cost is dominated by the
  view's O(console-length) re-render per publish, so publish *count* is
  the lever: trickle output now publishes at most 10×/s instead of
  20×/s, while interactive shell echo still lands within 100 ms.
- **Threshold: 16,384 chars** (`consoleFlushThreshold`) — during a flood
  (galaxy-class output), a full 100k console costs ~7 publishes instead
  of ~25 at a 4 KB threshold. Cost of the larger threshold: ~16 KB of
  buffer (plus whatever arrives during one render), and screen updates
  arriving in ~2–4-screenful bursts during floods — which is precisely
  the relief wanted, since each burst would otherwise have cost a full
  re-render. Neither parameter can change the final text: §1.2's cap
  computation is chunk-size-independent by construction, ordering is
  FIFO through the single buffer, and the tail flush (§1.4) is a
  separate synchronous path that ignores both parameters.

### 1.4 Guaranteed tail flush (no lost tail, no reordering)

Flush points, all synchronous on the main queue at the moment they run:

- **Halt:** `start()`'s completion block calls `flushConsoleBuffer()`
  before setting `isRunning = false` / `"Halted"`. `cpu.run()` has
  returned, so every guest character is already in the buffer
  (enqueues happen synchronously on the VM thread inside `mmioWrite`).
- **Trap:** the trap handler's main-queue block flushes *before*
  appending the `[TRAP …]` line — same relative order the old
  per-character FIFO produced.
- **Stop:** `stop()` calls `flushConsoleBuffer()` after
  `runGroup.wait(...)` (VM thread exited ⇒ buffer holds the complete
  tail). **`reset()`, `reboot()` and `boot()` all call `stop()` first**,
  so they inherit the flush before they assign `consoleText = ""`.
- **Load:** `loadProgram`'s main-queue block flushes and *then* clears,
  atomically on main — the old program's tail can neither vanish
  mid-load nor land after the clear and resurrect stale text.
- **Config apply:** `applyConfig` swaps `NovaMemory` and copies the
  `consoleOutput` closure onto the new instance; the closure routes to
  the engine-level buffer, which is memory-instance-independent, so a
  swap mid-stream loses nothing.

All real callers of these methods are main-thread (SwiftUI actions and
the engine's own main-queue blocks); `flushConsoleBuffer()` additionally
self-hops to main if ever called off it.

## 2. applyConfig allocation peak — DECISION: code left unchanged

Recon (a)1 / task item 2: `applyConfig` allocates the new `NovaMemory`
before `self.memory = newMem` releases the old → transient old+new, up to
~2 GB at the 1 GB setting. The task allowed a restructure only if
dropping the old first is **provably** safe, on the premise that config
apply happens while the VM is stopped. **That premise does not hold in
the code**, so the restructure is not provable and was not attempted:

Reference trace for the old `NovaMemory`:

- `NovaVMEngine.memory` — a **non-optional** `var`. It cannot be set to
  `nil` for the drop-first window; it must point at a live instance at
  all times.
- `cpu.memory` — `NovaCPU.swift:40`: `var memory: NovaMemory!`
  (implicitly unwrapped). The VM thread dereferences it continuously
  (fetch/store/MMIO/timer fields in `step()`), and so do
  `resetCPUState()` (stack bases, `timerInterval`/`timerCount`) and the
  trap path.
- The MMIO closures (`consoleOutput`, `fileHandler`, `netHandler`) live
  *on* the memory instance; `applyConfig` itself reads
  `memory.consoleOutput` from the old instance to wire the new one.
- Views hold **no** retained reference (`VMView.sendKeys` reaches
  `engine.memory.pushKey` transiently per keystroke) — this part of the
  trace is clean.
- **The VM is not stopped on this path:** `SettingsView`'s Save button
  calls `engine.applyConfig(c)` directly, and `applyConfig` never
  touches `cpu.running`, `runThread`, or `runGroup` — the engine's own
  comment says "we swap it live here". A running VM thread is therefore
  a live dereferencer of `cpu.memory` throughout any restructure window.

A drop-first sequence would need a placeholder instance installed in
both `engine.memory` and `cpu.memory` while the real one allocates —
but `NovaMemory.init` clamps to a **64 MB floor**, so the placeholder
itself allocates ≥ 64 MB, and during the window `cpu` would execute /
`resetCPUState()` would derive stack bases from the placeholder's
layout and timer state. With a possibly-running VM, that window has
observable behaviour the current code doesn't. Eliminating the peak
safely requires first making apply stop the VM (a behaviour change to
Settings) and a device test — exactly what the recon recommended
("note it, don't restructure it inside a memory lane without a device
test"). **Left unchanged; `ram_mb` clamp semantics (incl. the effective
64 MB floor) untouched**, as required.

## 3. File/net MMIO payload copies (recon item (a)3)

The core lane shipped bulk helpers in `NovaMemory.swift` for exactly
this (`v070-opt-core.md` §4) — stable signatures, single-memcpy,
semantics designed to reproduce the byte loops. Adopted as instructed
(an interim engine-local 8-byte-chunk implementation from earlier in
this lane was removed in their favour):

- `handleNetGet`: response copy →
  `memory.storeHostBytes(data.prefix(n), at: bufAddr)` (`data.prefix(n)`
  is a `Data` slice, so exactly the `n = min(data.count, maxBytes)`
  bytes move — the `Data` overload would otherwise copy the whole
  download). Still returns `Int64(n)` from handler bookkeeping, as
  before.
- File LIST (cmd 1): per name, `memory.storeHostBytes(bytes,
  at: bufAddr + UInt64(offset))`; the `offset + bytes.count <= bufSize`
  admission check and returned `offset` are unchanged.
- File READ (cmd 2): `memory.storeHostBytes(data.prefix(n),
  at: bufAddr)`, `n = min(data.count, bufSize)`, returns `Int64(n)`.
- File WRITE (cmd 3): guest→host loop →
  `let bytes = memory.loadHostBytes(from: bufAddr, count: count)`;
  the subsequent `Data(bytes)` atomic write and `Int64(bytes.count)`
  return are unchanged.

Semantics preservation: `storeHostBytes` writes the in-RAM prefix and
silently drops the rest — identical to a monotonic `try? write8` loop
over a contiguous range (in-bounds ⇔ index < size − addr), including
dropping MMIO-page bytes (plain `write8` faults there; the helper never
routes to `mmioWrite`). `loadHostBytes` returns the in-RAM prefix,
identical to the loops' stop-at-first-fault behaviour (valid range from
any start address is contiguous). Same results/error values, same byte
counts, same bytes moved in all four handlers. Deliberately **not**
bulk-copied: the NUL-terminated URL (≤ 2,048 B) and path (≤ 256 B)
readers — they stop at the first NUL, which a blind bulk read can't
know in advance (the core lane's note reaches the same conclusion).

Side benefit beyond the copies themselves: file WRITE's old path built
the `[UInt8]` byte-by-byte and then copied it again into `Data(bytes)`
(recon §1.3: ~2× transient). `loadHostBytes` produces the array in one
memcpy; only the unavoidable `Data(bytes)` copy remains.

## 4. Version bump

- `project.pbxproj`: `MARKETING_VERSION` `1.0 → 0.0.70` in **both**
  target configurations (Debug line 342, Release line 379). This is
  the value that ships: `GENERATE_INFOPLIST_FILE = YES`, so the built
  app's `CFBundleShortVersionString` comes from here. `CURRENT_PROJECT_VERSION`
  (= 1) and every other build setting untouched.
- `Info.plist`: `CFBundleShortVersionString` `0.0.6 → 0.0.70`
  (orphaned file — the project never references it — fixed so the repo
  stops lying, per recon §3.4). `CFBundleVersion` untouched.

## 5. Flagged, NOT done (out of this lane's file scope)

- **VMView ANSIRenderer (the remaining O(n²)):** batching cuts publish
  count by orders of magnitude, but each publish still costs
  `ANSIRenderer.render(engine.consoleText)` — a full-string rescan
  building a `Text` tree (`VMView.swift:118`), plus a scroll
  `.onChange` per publish. Follow-up for a view lane: render only the
  visible tail (e.g. last ~20k chars) or cache/incrementally extend the
  rendered segments keyed on the unchanged prefix. The engine-side
  model already keeps the full text, so a tail-render is display-only
  and safe to do independently.
- **`reboot()` firmware reload** (`NovaVMEngine.swift`, this lane's file
  but outside the task's handler scope): still a byte-at-a-time
  `write8` loop over ~27 KB where `boot()` uses the `loadBytes` memcpy
  path. Swapping to `try? memory.loadBytes(fw, at: 0)` is provably
  equivalent (firmware is ~27 KB at address 0, RAM ≥ 64 MB, so no
  clamping/fault divergence) — left for a follow-up to keep this
  change-set exactly on-task.
