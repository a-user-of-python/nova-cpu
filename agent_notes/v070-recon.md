# NOVA v0.0.70 — Lane E recon + memory audit (Phase 1, READ-ONLY)

Date: 2026-11-04. Scope: `~/workspace/nova-cpu` (app in `vm-app/`) + sibling
`~/workspace/nova-programs`. No app source was edited; this file is the only
write. Line numbers are against the local copies as read today.

**Push baselines (GitHub API, 2026-11-04):**

| Repo | `main` HEAD | Tree | HEAD subject |
|---|---|---|---|
| `a-user-of-python/nova-cpu` | `6f71f57c1733fef427e3b4f7fc967551f120d007` | `fb28321ca266f8647339968c754a338d0a93f6b9` | "Rebuild project file from clean version with icon" |
| `a-user-of-python/nova-programs` | `435a333620ea5e94a5480832b994b5a530904752` | `69447fde31ba86527bcaa31890640934236f15e4` | "v0.0.69: fix line_copy R12 clobber + ed_delete arg order" |

Neither local tree is a git checkout — confirmed: no `.git` in either
`~/workspace/nova-cpu` or `~/workspace/nova-programs`.

---

## 1. Memory-use audit

### Ranked summary

| # | Finding | Resident / transient size | Measurable? | Verdict |
|---|---|---|---|---|
| 1 | Guest RAM eagerly allocated in full at launch (and re-allocated on config apply) | 64 MB default, up to 1 GB; **2× that transiently** during `applyConfig` | Yes — footprint at launch, before any Run | Leave the size/semantics alone; only the `applyConfig` double-hold is worth a look |
| 2 | Console: per-character main-thread publish + full-string re-render on every publish | ~100–200 KB resident, but O(n) work per char → O(n²) per screenful; main-thread churn | Yes — main-thread CPU / time-to-render at high output rates | **Top optimization target** (batching), resident-memory win is small |
| 3 | File/net MMIO handlers copy whole payloads, byte-at-a-time | Transient up to ~10 MB (file READ/WRITE), ~1 MB (net) per command | Yes, for large files only | Leave for v0.0.70 memory work; it's a speed issue more than a memory one |
| 4 | Firmware bytes exist in 3–4 copies at once on boot paths | ~27 KB each, ≤ ~108 KB transient | Only in Instruments; irrelevant at app scale | Leave alone (one trivial cache possible, see §1.4) |
| 5 | Selected program / custom firmware `Data` retained whole | Programs in-repo 27 B–27 KB; arbitrary picks bounded only at load time; custom firmware ≤ 1 MB | Only with a deliberately huge pick | Leave alone — retention is deliberate (see §1.5) |
| 6 | 0.25 s live register snapshot | 128 B + 32 B per tick, 4×/s, panel-visible only | No (noise) | Leave alone |
| 7 | Keyboard queue: unbounded `[UInt8]`, `removeFirst()` per guest read | Practically one typed line; O(n) memmove per pop | Only pathologically | Leave alone |

### 1.1 Guest RAM — eager, full-size, single copy (the big one, by design)

- `NovaMemory.swift:42,56-63` — storage is one
  `ContiguousArray<UInt8>(repeating: 0, count: clamped)`. The **full
  configured size is committed up front**; there is no sparse file, no
  `mmap`, no lazy/on-demand paging layer in the app. `ContiguousArray`
  guarantees one contiguous allocation, zero-filled at init.
- `NovaVMEngine.swift:60-66` (`init`) — `ramBytes = cfg.ramMB * 1024 * 1024`,
  then `NovaMemory(totalSize: ramBytes)` runs at **app launch**, before any
  program is loaded or Run is pressed. Default config is 64 MB
  (`NovaConfig.swift:24-33`), so the default launch footprint includes a
  64 MB guest array; at `ram_mb=1024` it is a full 1 GB from launch.
- No second full copy exists: CPU, file/net handlers and views all go
  through the same `NovaMemory` instance (`cpu.memory = memory`,
  `NovaVMEngine.swift:67`). Program/firmware bytes are `memcpy`'d *into*
  this array (`NovaMemory.swift:158-170`, `loadBytes`) — that in-guest copy
  is the program's actual memory, not a duplicate buffer.
- **Clamp semantics — do not touch.** Three layers agree on the floor, and
  it is **64 MB, not 16 MB**, despite the docs:
  - `NovaConfig.swift:20-21`: `maxRAMMB = 1024`, `minRAMMB = 64`;
    `sanitize()` (`:38`) clamps `ramMB` into `[64, 1024]`.
  - `NovaMemory.swift:54,58-59`: `maxTotalSize = 1 GB`; init clamps into
    `[64 MB, 1 GB]` regardless of what it's handed.
  - `SettingsView.swift:40,51-54`: slider range is
    `NovaConfig.minRAMMB...NovaConfig.maxRAMMB`, step 16.
  - The "16–1024" figure survives only in comments/serialized text
    (`NovaConfig.swift:8,158` serialize header, `SettingsView.swift:39`
    comment). Any v0.0.70 work must preserve the effective `[64 MB, 1 GB]`
    behaviour exactly.
- **Transient double-hold in `applyConfig`** — `NovaVMEngine.swift:130-149`:
  when RAM size changes, the new `NovaMemory` is fully allocated *before*
  `self.memory = newMem` releases the old one, so peak guest-RAM during a
  config apply is old + new (up to ~2 GB at the 1 GB setting — the one
  place the 1 GB cap is effectively exceeded, transiently). Safe reduction
  exists in principle (stop the VM, drop the old memory first, then
  allocate), but `memory` is a non-optional `var` referenced by `cpu` and
  by the MMIO closures, so it needs a deliberate restructure, not a
  one-liner. Measurable: footprint spike during a RAM-size change in
  Settings. Recommend: note it, don't restructure it inside a memory
  lane without a device test.
- Safe reduction for the launch allocation itself: **none recommended.**
  Switching to a lazily-faulted allocation (e.g. `calloc`/`mmap`-backed
  storage) would change the storage type every accessor in
  `NovaMemory.swift:75-156` touches, for a resident-memory saving that on
  iOS is partly illusory (untouched zero pages are cheap for the OS to
  reclaim/back lazily anyway) and a real risk to the hot fetch/store
  paths. Leave alone.

### 1.2 Console storage — ~100 k cap, per-char publish, full re-render

Path: guest byte → `NovaMemory.mmioWrite` → `consoleOutput` closure →
`NovaVMEngine.consoleText` (`@Published String`) → `VMView`.

- UTF-8 assembly is cheap and bounded: `NovaMemory.swift:225,229-241` —
  `utf8Buffer` accumulates bytes until a complete UTF-8 sequence forms
  (forced flush at >8 bytes), then one `String` per character (usually
  1 char) is passed to `consoleOutput`. No duplicate console buffer here.
- The cost is in the engine: `NovaVMEngine.swift:94-102` — **every
  character** schedules a `DispatchQueue.main.async` block that does
  `consoleText += s`. Each mutation of a `@Published String` publishes to
  SwiftUI. Swift `String` append itself is amortized (no full copy per
  char in the common unique-reference case), so this is not a classic
  copy-on-write blow-up in the string — the blow-up is one main-thread
  hop + one publish *per character*.
- Cap mechanics, `NovaVMEngine.swift:97-100`: only after an append, if
  `consoleText.count > 100_000`, it is replaced with
  `String(t.suffix(90_000))` — a one-off ~90 k-char copy, recurring every
  ~10 k chars of further output. Resident console cost is therefore
  bounded at ~100 k characters (~100–200 KB depending on encoding) plus
  the trap line appended the same way at `NovaVMEngine.swift:85`.
- The multiplier is the view: `VMView.swift:118` calls
  `ANSIRenderer.render(engine.consoleText)` on **every** body evaluation,
  and `render` (`VMView.swift:8-61`) rescans the entire string and builds
  a concatenated `Text` segment-by-segment. So each published character
  triggers an O(console-length) re-render — O(n²) total work to fill the
  console once, plus a transient second representation (the segment
  `current` string + `Text` tree) of roughly console size per render.
  `.onChange(of: engine.consoleText)` (`VMView.swift:128-130`) also
  scrolls on every publish.
- Safe reduction (the optimization lane's natural target, no semantics
  change): batch in the engine — accumulate incoming characters in a
  non-published buffer on the VM side and flush to `consoleText` on a
  timer/quantum (e.g. every ~50–100 ms or every few KB), keeping the
  exact same 100 k/90 k cap rule applied at flush time. Optionally also
  render only the tail in `VMView`. This cuts main-thread publishes by
  orders of magnitude; the *resident* saving is small (~100 KB scale) —
  sell it as CPU/jank, not footprint. Measurable: main-thread CPU and
  dropped frames while running a chatty program (e.g. galaxy).

### 1.3 Engine per-run allocations

- `start()` (`NovaVMEngine.swift:388-411`): one `Thread` per run, no
  retained run history; `runThread` reference is dropped in `stop()`
  (`:417`). Nothing accumulates across runs.
- `reboot()` (`NovaVMEngine.swift:429-435`) reloads firmware with a
  **byte-at-a-time `write8` loop**, where `boot()`/`loadProgram()` use
  the `memcpy` bulk path (`loadBytes`). No extra allocation, but it's a
  per-byte bounds-checked pass over ~27 KB — a speed wart, not memory.
- File MMIO (`NovaVMEngine.swift:290-360`), runs synchronously on the VM
  thread:
  - LIST (cmd 1): writes names byte-at-a-time into guest RAM; host-side
    allocation is just the sorted name list. Cap 1 MB buffer.
  - READ (cmd 2): `Data(contentsOf:)` loads the **whole file** (cap
    10 MB via `bufSize` clamp, `:306`), then copies byte-at-a-time into
    guest RAM. Transient: one file-sized `Data`.
  - WRITE (cmd 3): builds a `[UInt8]` of the full count (cap 10 MB,
    `:327`), then `Data(bytes)` makes a **second copy**, then atomic
    write. Transient ≈ 2× payload.
- Net MMIO (`NovaVMEngine.swift:247-288`): response `Data` capped at
  1 MB (`:264`), copied byte-at-a-time into guest RAM. Transient ≈ 1×
  payload plus the `URLSession` copy.
- Safe reduction for all three: a bulk guest-write helper (the inverse
  of `loadBytes`) would collapse the byte loops and one copy. Memory
  saving is transient-only (≤ ~10 MB worst case, ~0 typical); do it for
  speed if at all, not for footprint.

### 1.4 Firmware copies

- Embedded image: `novaShellBytes` in `NovaFirmware.swift` (from
  ~line 100 to end of file) is a **27,060-byte** `[UInt8]` literal —
  that's storage in the app binary, not heap.
- `refreshBuiltIn()` (`NovaFirmware.swift:27-38`, called once at engine
  init): builds `Data(novaShellBytes)` (copy 1) and reads the on-disk
  `NOVA/firmware/novash.bin` (copy 2) to compare; rewrites the file only
  if different. ~54 KB transient, once per launch.
- `defaultImage` (`NovaFirmware.swift:39-55`) is a **computed** property:
  *every* call rebuilds `Data(novaShellBytes)` and re-reads the firmware
  file for the equality check. It's called per load/boot/reboot
  (`NovaVMEngine.swift:198,424,450`), so each boot pays ~54 KB of
  transient copies and a file read, retaining only the returned `Data`
  (~27 KB) until it's copied into guest RAM. Safe reduction: cache the
  embedded `Data` in a `static let` — trivially safe, saves nothing
  measurable. Leave alone unless the lane is already in this file.
- `NovaFolders.resolveFirmware` (`NovaConfig.swift:158-166`) also returns
  firmware `Data` but has **no callers** in the app — dead path, ignore.
- `NovaVMEngine.ensureProgramInSharedDir` (`:475-486`) likewise has no
  callers (the live copy-to-shared logic is in `ProgramsView`). Dead
  code, no memory effect.

### 1.5 Retained program / firmware `Data` (deliberate — leave alone)

- `NovaVMEngine.swift:36-41`: `customFirmwareData: Data?` and
  `selectedProgramData: Data?` hold the **entire** picked binary for as
  long as it's selected. Set at pick time in `FirmwareView.swift:149-177`
  (≤ 1 MB enforced) and `ProgramsView.swift:140-141,178-180`.
- This is intentional: the comment at `NovaVMEngine.swift:35` — firmware
  bytes are copied at pick time because security-scoped URLs expire.
  The same reasoning covers program picks from outside the sandbox.
- Plus the in-guest copy after load (§1.1) and, for programs, a disk copy
  in `NOVA/shared/` (`ProgramsView.swift:143-146,183-185`) — disk, not
  RAM. In-repo programs are 27 B–27 KB (largest: `novashell/shell.bin`
  27,092 B), so retained cost is noise unless a user picks a multi-MB
  `.bin`; `loadProgram` rejects `data.count >= memorySize/2`
  (`NovaVMEngine.swift:190`) but only at load time, not at pick time.
  Leave alone.

### 1.6 Register viewer snapshots

- `NovaVMEngine.swift:29-30,213-216`: `regSnapshot` is a fresh
  16×`UInt64` array (128 B) per snapshot; `spSnapshot` is a 4×`UInt64`
  tuple. No history is kept — each snapshot replaces the last.
- Live path (`NovaVMEngine.swift:370-386`): a 0.25 s `Timer` copies
  `cpu.regs` into the `@Published` snapshot (same 128 B) and republishes,
  which re-renders `RegisterGrid`. Started/stopped only with the panel's
  visibility (`VMView.swift:101-107`). Allocation is negligible; the
  only cost is a 4 Hz SwiftUI re-render of a small grid while the panel
  is open. Leave alone.

### 1.7 Minor / bounded

- Keyboard queue `NovaMemory.swift:195,296-299`: `[UInt8]`, append on
  host push, `removeFirst()` (O(n) memmove) per guest pop at `:280`.
  Unbounded in theory; in practice `VMView.sendKeys` (`VMView.swift:
  208-217`) pushes one typed line + newline at a time. Leave alone.
- Launch log `NovaVMEngine.swift:115-130`: opens a `FileHandle` per
  call (6 calls during init) and appends to `Documents/NOVA/launch.log`
  forever — disk growth, not RAM. Leave alone.
- Console trap line, status strings, config serialization: all
  small/transient. Nothing else in the views retains data proportional
  to guest RAM or output volume.

---

## 2. Graphics / text surface inventory (MMIO map)

**Headline: there is exactly ONE guest-visible output surface — the
console character stream. There is no framebuffer, no display/graphics
MMIO, no pixel/plane/ palette device anywhere in `NovaMemory` or
`NovaCPU`.** A repo-wide search for framebuffer/display/graphics/pixel
in the app finds nothing beyond the console rendering in `VMView`.
Anything that looks graphical (e.g. galaxy's coloured spiral) is ANSI
escape sequences inside the console text, styled by
`VMView.ANSIRenderer` (`VMView.swift:7-62`).

All MMIO lives in one page, `0xFFFF_FFFF_FFFF_0000 – 0x…0078`, defined
at `NovaMemory.swift:169-190`. Routing (`NovaCPU.swift`): only four
opcodes check the MMIO range (`addr >= 0xFFFF_FFFF_FFFF_0000`) —

| Opcode | CPU lines | Routes to |
|---|---|---|
| LOAD64 `0x83` | `NovaCPU.swift:321-325` | `memory.mmioRead(addr)` |
| LOADU8 `0x84` | `NovaCPU.swift:328-332` | `memory.mmioRead(addr) & 0xFF` |
| STORE8 `0x87` | `NovaCPU.swift:341-345` | `memory.mmioWrite(addr, v & 0xFF)` |
| STORE64 `0x8A` | `NovaCPU.swift:354-358` | `memory.mmioWrite(addr, v)` |

Note: LOAD8/LOADU16/LOADU32/STORE16/STORE32 do **not** route to MMIO —
they call the plain RAM accessors, so an MMIO-range address there throws
a load/store access fault. Guest code must use the four opcodes above.

### Register-by-register

| Address | Name (NovaMemory.swift) | R/W | Exact code path per access |
|---|---|---|---|
| `0xFFFF_FFFF_FFFF_0000` | `consoleAddr` (:169) | W only | `mmioWrite` (:230-241): low byte appended to `utf8Buffer`; on a complete UTF-8 sequence (or >8 buffered bytes) `consoleOutput?(s)` fires → `NovaVMEngine.swift:94-102` appends to `@Published consoleText` on the main queue, 100 k/90 k cap → rendered by `ANSIRenderer.render(consoleText)` in `VMView.swift:118`. Read: falls through `mmioRead` default → `0`. |
| `0xFFFF_FFFF_FFFF_0008` | `keyboardAddr` (:170) | R only | `mmioRead` (:277-280): under `keyboardLock`, returns `keyboardQueue.removeFirst()` as `UInt64`, or `0` if empty (guest polls). Host side: `VMView.sendKeys` (`VMView.swift:208-217`) pushes each typed byte + a trailing `10` via `memory.pushKey` (`NovaMemory.swift:296-299`). Write: no case in `mmioWrite` — ignored. |
| `0xFFFF_FFFF_FFFF_0010` | `fileCmdAddr` (:171) | W (trigger) | `mmioWrite` (:246-252): synchronously calls `fileHandler(v, fileArg0, fileArg1, fileArg2)` on the VM thread → `NovaVMEngine.handleFileCommand` (:290-360): cmd 1 LIST, 2 READ, 3 WRITE against `NOVA/shared/`. Result stored in `fileResult`. |
| `0xFFFF_FFFF_FFFF_0018` | `fileArg0Addr` (:172) | W | `mmioWrite` (:253-254): stores into `fileArg0`. |
| `0xFFFF_FFFF_FFFF_0020` | `fileArg1Addr` (:173) | W | `mmioWrite` (:255-256): stores into `fileArg1`. |
| `0xFFFF_FFFF_FFFF_0028` | `fileArg2Addr` (:174) | W | `mmioWrite` (:257-258): stores into `fileArg2`. |
| `0xFFFF_FFFF_FFFF_0030` | `fileResultAddr` (:175) | R | `mmioRead` (:281-282): `UInt64(bitPattern: fileResult)`. |
| `0xFFFF_FFFF_FFFF_0040` | `timerIntervalAddr` (:179) | R/W | Write (:242-244): `timerInterval = v; timerCount = v`. Read (:285-286): returns `timerInterval`. Scheduler device, not display. |
| `0xFFFF_FFFF_FFFF_0048` | `timerCountAddr` (:180) | R | `mmioRead` (:283-284): returns live `timerCount`. Writes not handled (ignored). |
| `0xFFFF_FFFF_FFFF_0050` | `timerVectorAddr` (:183) | R/W | Write (:245-246): stores `timerVector`. Read (:287-288): returns it. |
| `0xFFFF_FFFF_FFFF_0058` | `netCmdAddr` (:186) | W (trigger) | `mmioWrite` (:259-266): for `v == 1` (GET, 20 s) or `v == 2` (quick GET, 5 s), synchronously calls `netHandler(netUrl, netBuf, netBufSize, v)` → `NovaVMEngine.handleNetGet` (:247-288), blocking HTTP GET, response copied into guest RAM, byte count stored in `netResult`; anything else → `netResult = -1`. Network device, not display. |
| `0xFFFF_FFFF_FFFF_0060` | `netUrlAddr` (:187) | W | `mmioWrite` (:267-268): stores guest address of the NUL-terminated URL. |
| `0xFFFF_FFFF_FFFF_0068` | `netBufAddr` (:188) | W | `mmioWrite` (:269-270): stores response-buffer guest address. |
| `0xFFFF_FFFF_FFFF_0070` | `netBufSizeAddr` (:189) | W | `mmioWrite` (:271-272): stores max response bytes. |
| `0xFFFF_FFFF_FFFF_0078` | `netResultAddr` (:190) | R | `mmioRead` (:289-290): `UInt64(bitPattern: netResult)`. |

Any other address in the MMIO page: `mmioWrite` does nothing,
`mmioRead` returns `0` (`NovaMemory.swift:292`).

**Consequence for the optimization lane:** the console char path
(`0x…0000` write → per-char publish → full re-render, §1.2) is the only
guest-output path there is. There is no second surface to batch,
cache, or bypass — optimizing guest output *is* optimizing this path.
Keyboard input is the only guest-visible input surface (polled byte
queue, above). File, timer and network MMIO are control/data devices
that never touch the screen except through console writes by guest code.

---

## 3. Delivery mechanics recon

### 3.1 How pushes actually work here

- Neither repo is a git checkout (no `.git`, confirmed above), and plain
  `git push` is not available (no credential helper in this sandbox).
  All pushes go through the GitHub git-database API via the
  `custom.github` credential, using the helpers in
  `~/workspace/custom-connectors/custom.legacy-github/CONNECTOR.md`
  (requests only to `api.github.com`; credentials never printed).
- Two helper scripts exist at `~/workspace/`:
  - `git-api-push.py` — single-commit delta push. Requires remote ref ==
    local `HEAD~1` exactly and refuses otherwise. **Not usable as the
    standing route**: the API recreates commits, so remote SHAs diverge
    from any local history after the first push (same lesson as
    AGENTS.md's git-helper notes: verify by *tree*, never by commit SHA).
  - `git-api-push-tree.py` — **the standing route.** Creates a new remote
    commit whose tree is local HEAD's tree and whose parent is the
    current remote HEAD. It (a) reads the remote HEAD's commit message,
    (b) finds the local commit whose *subject line matches* it — that
    commit is the assumed base tree, (c) diffs base→HEAD and uploads
    fresh blobs only for changed files, (d) POSTs the **full tree** from
    `git ls-tree -r HEAD` (reusing remote blob SHAs for unchanged
    files), (e) creates the commit and PATCHes the ref.
- No written temp-repo procedure was found in the goal folder
  (`~/workspace/goals/nova-custom-cpu-and-ios-vm-app/GOAL.md` is a
  one-paragraph summary with no push notes) or in either repo. The
  recipe below is reconstructed from the two scripts' source and is the
  only procedure consistent with what they require.

### 3.2 Exact push recipe (both repos)

Preconditions: know the repo's current remote HEAD SHA + HEAD subject
(see baselines in the header; re-read them immediately before pushing —
the tree script parents onto whatever remote HEAD is at run time).

1. **Stage a temp git repo** (per repo, e.g. `/tmp/nova-cpu-push/`):
   - `git init`, configure a neutral local identity (never the user's
     name in anything that could surface publicly).
   - Recreate the **base commit**: materialize the current remote tree
     locally (GET `/repos/a-user-of-python/<repo>/git/trees/<tree-sha>?recursive=1`,
     download each blob, write the files), `git add -A`, and commit with
     the message subject **exactly equal to the remote HEAD subject**
     (nova-cpu: `Rebuild project file from clean version with icon`;
     nova-programs: `v0.0.69: fix line_copy R12 clobber + ed_delete arg order`).
     This exact-subject commit is what `git-api-push-tree.py` searches
     for; without it the script exits with "Cannot find local commit
     matching remote HEAD message; refusing."
   - Overlay the new state: copy the working tree from
     `~/workspace/nova-cpu` (resp. `nova-programs`) over it, excluding
     `__pycache__/` directories, `git add -A`, commit with the release
     message (e.g. `v0.0.70: <summary>`).
2. **Push:** `python3 ~/workspace/git-api-push-tree.py /tmp/nova-cpu-push a-user-of-python nova-cpu main`
   (resp. `nova-programs`). It prints local HEAD, remote HEAD (becomes
   the parent), the matched base commit, changed-file count, new tree
   SHA, new commit SHA.
3. **Verify by tree, never by SHA:** GET
   `/repos/a-user-of-python/<repo>/git/ref/heads/main`, then GET that
   commit; its `tree.sha` must equal `git -C /tmp/nova-cpu-push rev-parse HEAD^{tree}`.
   Spot-check one or two changed files via the contents API. Only then
   is the push "done".
4. Repeat independently for the second repo — they share no history and
   there is no cross-repo ordering requirement, but if the app embeds
   new shell bytes from nova-programs sources, push **nova-programs
   first** so the app's embedded copy is never ahead of its source repo.

**Known script limitations (plan around them):**

- **Deletions break the tree script.** Its changed-file loop `open()`s
  every path in `git diff --name-only base HEAD` — a deleted file isn't
  on disk and the script dies. (The single-commit `git-api-push.py`
  handles deletions via a `cat-file -e` check + `sha: null` tree entry.)
  If a v0.0.70 change deletes a file: either do that push with a manual
  API tree POST (`base_tree` = remote tree, changed entries only, `sha: null`
  for deletions — the delta pattern in AGENTS.md), or split the push so
  deletions ride a hand-built commit. Additions/modifications only — the
  common case — are fine with the stock script.
- **Full-tree POST size:** fine here (~57 files nova-cpu, ~30 files
  nova-programs, both < 1 MB). The 502-on-large-tree failure mode from
  other repos does not apply; if it ever does, switch that push to the
  `base_tree` + changed-entries delta form.
- The script skips gitlink (`commit`) tree entries — neither repo has
  submodules, so this is a non-issue.

### 3.3 Workflow files (`.github/workflows/`) — scope caveat

- The git-database API refuses to create/update workflow files when the
  credential lacks the `workflow` scope (HTTP 403, "refusing to allow …
  to create or update workflow"). The historical record here is mixed:
  project notes from 2026-10-13 describe the token's permissions as
  fixed with "no workflow files", yet an updated
  `.github/workflows/build-ipa.yml` *was* successfully API-pushed on
  2026-10-12 (commit prefix `b589130e`) after the user explicitly
  granted permission, and the workflow on remote is `active` today.
  Treat scope as **uncertain until tried**.
- Procedure: include workflow changes in the normal tree push, but push
  them **last / as their own commit** so a refusal can't strand the rest
  of the release. If the tree/commit POST (or ref PATCH) comes back 403
  naming workflow scope: do **not** retry in a loop. Fall back to
  handing the user the workflow file's full contents as raw inline text
  to paste into the existing file via GitHub's web UI (his standing
  preference for paste-elsewhere content), or he pushes that one file
  from his Mac. Everything else (source, dispatch, artifact download)
  works without workflow scope. v0.0.70 should not *need* a workflow
  change — `build-ipa.yml` already does everything below.

### 3.4 IPA build — v0.0.70 procedure

Workflow: `.github/workflows/build-ipa.yml` ("Build IPA"), triggers:

- `workflow_dispatch` with a required `version` input (default
  `v0.0.1`), and
- `push` on tags matching `v*`.

In both cases the version string is used **only** as the IPA filename:
`VERSION = ${{ github.event.inputs.version || github.ref_name }}`, and
the package step produces `NovaVM-<VERSION>.ipa`, uploaded as the
`NovaVM-ipa` artifact. Nothing in the workflow stamps the app bundle's
version.

What past releases actually did (verified via API today):

- Tags and GitHub Releases exist only up to **v0.0.18** (18 tags, 17
  releases). Every release after that — the local goal folder holds IPAs
  up to `NovaVM-v0.0.69.ipa` — was apparently produced by
  **workflow_dispatch on `main`** with the version typed into the input:
  the five most recent `build-ipa.yml` runs are all
  `workflow_dispatch` / `head_branch: main` (latest, run `39684056915`,
  completed success). No tag, no Release object.
- So the tag trigger is legacy (v0.0.1–v0.0.18 era); dispatch is the
  living procedure.

**Recommended v0.0.70 procedure:**

1. Land the source changes on `main` via §3.2 (nova-programs first if
   applicable).
2. Dispatch "Build IPA" on `main` with `version = v0.0.70`
   (POST `/repos/a-user-of-python/nova-cpu/actions/workflows/build-ipa.yml/dispatches`,
   `{"ref": "main", "inputs": {"version": "v0.0.70"}}`).
3. Download the `NovaVM-ipa` artifact from the completed run; the file
   inside is `NovaVM-v0.0.70.ipa`. Deliver under that exact name.
4. Do **not** also push a `v0.0.70` tag — it would trigger a second,
   duplicate build, and tags/Releases were abandoned after v0.0.18.
   Create one only if a GitHub Release page is explicitly wanted.

**Version strings — the stale `0.0.6`, and what actually matters:**

- `vm-app/NovaVM/Info.plist:23-24` says `CFBundleShortVersionString =
  0.0.6`, `CFBundleVersion = 1`. **But this file is not referenced by
  the Xcode project at all** — `project.pbxproj` contains no
  `Info.plist` reference and sets `GENERATE_INFOPLIST_FILE = YES`
  (pbxproj :330, :367) with `INFOPLIST_KEY_*` settings. The built app's
  plist is *generated*, and its `CFBundleShortVersionString` comes from
  `MARKETING_VERSION = 1.0` (pbxproj :342, :379). That's consistent with
  the project's own history note: the on-device version string "is
  always 1.0" regardless of release number, which is exactly what
  caused the v0.0.59–61 stale-firmware confusion before the
  content-aware `refreshBuiltIn()` fix.
- Recommendation: **fix both, in the same source push** —
  `MARKETING_VERSION` `1.0 → 0.0.70` in both build configurations of
  `project.pbxproj` (that's the one the built IPA actually carries, and
  it's what sideload tools / Settings will show), and
  `CFBundleShortVersionString` `0.0.6 → 0.0.70` in the physical
  `Info.plist` so the repo stops lying to the next reader, even though
  that file is currently orphaned. Risk is minimal: the workflow never
  parses either value (filename comes from the dispatch input), and no
  code reads `CFBundleShortVersionString` at runtime anymore
  (`refreshBuiltIn` is content-compared, not version-stamped). If the
  lane wants zero project-file churn, the fallback is acceptable too —
  dispatch-only, exactly like v0.0.19–v0.0.69 shipped — but then say
  plainly in the delivery note that the in-app version will still read
  1.0.
