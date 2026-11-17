# v0.0.74 — file/net MMIO exclusivity fix (the Run-tab crash)

## Symptom (device report, 2026-11-17)

NovaVM v0.0.73 crashes the second the Run tab is tapped. The Run tab
auto-boots NovaShell (VMView.onAppear -> engine.boot()), and NovaShell
issues file commands during boot: `load_config` READs (and creates)
novash.cfg, then `date_sync` attempts a net GET — all before the first
prompt. With the app's sandbox file handler always attached, the first
of those commands killed the process.

## Cause (the flagged v0.0.70 bug, J4 §5 / J5 §6 — left untouched by order until now)

`NovaCPU.hotRun` executes inside `NovaMemory.withHotBuffer`, i.e.
inside `bytes.withUnsafeMutableBufferPointer` — a modify access on
`NovaMemory.bytes` held for the whole run. The file/net MMIO handlers
run synchronously inside `mmioWrite` and re-entered checked accessors
on the same storage (`read8` string loops; `storeHostBytes` /
`loadHostBytes` fetched fresh buffer pointers from `bytes`). Swift
exclusivity enforcement aborts: "Simultaneous accesses … but
modification requires exclusive access". Stack shape (J4):
hotRun -> mmioWrite -> handler -> read8 -> abort.

The golden gate never saw it: goldens run without a sandbox, so
`fileHandler` is nil and the path is never taken. J4's firmware
smoke 1 (with --sandbox) exposed it in the interpreter and was left
evidence-only.

## Fix

Host handlers must not begin ANY Swift access on `bytes` while the
hot loop's modify access is outstanding. The interpreter itself is
untouched (cycle counts, fault behaviour, and the hot loop are
exactly as gated):

- `NovaMemory` captures the RAM base pointer once in init
  (`ramBase`). Valid for the instance's life under the file's own
  documented invariant: `bytes` is assigned exactly once and never
  resized/appended/reassigned; all mutation is in-place.
- `storeHostBytes` (both overloads) and `loadHostBytes` now memcpy
  through `ramBase` instead of fetching a buffer pointer from
  `bytes`. Same bounds math, same in-RAM-prefix semantics.
- New `hostReadCString(from:maxLength:)`: byte-for-byte what the
  handlers' `try? read8` loops collected (stop at first NUL, at end
  of RAM, or at the cap), built on `loadHostBytes`.
- `NovaVMEngine.handleFileCommand` / `handleNetGet`: the three
  `read8` string loops (file READ path, file WRITE path, net URL)
  now use `hostReadCString`. No other handler RAM access remains
  (the `write8` in `reboot()` runs on the UI thread while halted —
  not inside the hot loop — and is unchanged).
- `tools/harness/main.swift`: the sandbox file handler mirrors the
  engine exactly (it previously used read8/write8 byte loops, which
  would still abort in the harness even with the core fixed).

## Regression gate

`run.sh gate` gains a `shellboot+sandbox` case: boot the embedded
NovaShell with --sandbox and a scripted `help` line. PASS requires
clean exit, the banner and the help listing in the console, and
novash.cfg created in the sandbox (proof the boot-time file WRITE
handler executed inside the hot loop). Before this fix the run
aborts during boot; the golden cases cannot regress it silently
again.

## Untouched

Interpreter hot loop and step path, DIV/REM INT64_MIN/-1 behaviour,
all goldens. Version 0.0.73 -> 0.0.74 (pbxproj x2 + Info.plist).
