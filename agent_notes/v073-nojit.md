# NOVA v0.0.73 — JIT removed from the shipped app (Sean's directive)

Date: 2026-11-04 (ET). Commissioned by Sean 2026-11-04 21:11 ET:
"remove jit from default nova". The default NovaVM app ships
WITHOUT the JIT again. This is a removal from the shipped app
only — the JIT is preserved in the repo's test lanes, not
deleted.

## What changed (commit a2287855, tree 6dff2f12, tree-verified)

- `vm-app/NovaVM/VM/NovaCPU.swift` — the v0.0.71 additions
  (J5-promoted ADDITIONS 1–5: `requestedEngine` / `activeEngine` /
  `jitStats`, `jitD3Enabled`, the `run()` probe hook,
  `selectEngineForRun`, and the `jitHandleTrapAfterStep` /
  `jitSetStats` trampoline bridges) are stripped. Verified: the
  result is **byte-identical to the v0.0.70 hotloop core**
  (`tools/harness/variants/hotloop/NovaCPU.swift`, md5
  89c27d30afec36b456117e80c988bafe) — the pure Phase 1
  interpreter, whose body the JIT work never modified.
- `vm-app/NovaVM/VM/NovaJIT.swift` — deleted from the app tree
  and unwired from `NovaVM.xcodeproj` (PBXBuildFile,
  PBXFileReference, group child, Sources entry all removed).
  The byte-identical copy at `tools/harness/variants/jit/
  NovaJIT.swift` (md5 d3466a00eff896b7cafbea182ddb5a31) is
  untouched and remains the gated lane copy.
- `vm-app/NovaVM/VM/NovaVMEngine.swift` — `cpu.requestedEngine =
  .jit` removed from `init()`; the halt completion now sets the
  fixed string `statusLine = "Halted — Interpreter"`. With one
  engine the line can never claim JIT.
- Version 0.0.72 → 0.0.73 (`MARKETING_VERSION` in both pbxproj
  configurations + `CFBundleShortVersionString` in Info.plist).

Untouched, as ordered: the interpreter hotloop body itself, the
flagged file-MMIO exclusivity behaviour, and DIV/REM
INT64_MIN/−1 behaviour. No other app file referenced the JIT
(grep-verified across vm-app Swift sources).

## Lanes after the removal

- Plain gate builds the shipped app core (run.sh only adds
  `vm-app/.../NovaJIT.swift` when the file exists — it no longer
  does, so the plain gate compiles the pure interpreter; the
  harness binary's `.engine` marker reads `interpreter`).
- `gate-variant vm-app/NovaVM/VM` now exercises the interpreter
  only — the natural consequence of the removal (previously it
  gated the promoted JIT copy in the app tree).
- `gate-variant jit` (tools/harness/variants/jit) is unchanged
  and still gates the preserved JIT under `--engine jit`.

## Gates (head a2287855, all CI-host macos claims)

- **Plain gate** (push-triggered, shipped app core), run
  41953744266: **9/9 PASS incl. selfmod** — `== GATE: all
  programs match the golden baseline`.
- **Speed** (dispatch, mode=speed), run 41953922219, best of 5:
  bench **269,590,600 ips**, galaxy **11,210,124 ips** for the
  shipped core — squarely the v0.0.70 interpreter class
  (reference points: 215.6M / 7.83M on run 41901995849's host;
  244.6M / 10.0M like-for-like on the v0.0.72 speed host; host
  variance accounts for the spread). No regression from the
  removal — the core is byte-identical to v0.0.70's.
- **Preserved JIT lane** (dispatch, mode=gate-variant,
  variant=jit), run 41953926048: **9/9 PASS incl. selfmod**,
  `engine_active=jit(path: wxTransition)` on every case,
  selfmod invalidations=2, singleSteps=0 on all goldens —
  identical stats to the v0.0.72 record. (Its evidence-only
  firmware smoke 1 still shows the known pre-existing
  file-MMIO/sandbox divergence between engines; smoke 2, no
  sandbox, agrees. Neither is gated; nothing in this lane
  changed that behaviour.)

## IPA

- `build-ipa.yml` dispatched with input `version = v0.0.73`,
  run 41954205285 SUCCESS at head a2287855.
- `NovaVM-v0.0.73.ipa`: **1,155,009 bytes, md5
  a83aa9b09fb4b78af37e9fd5d93e8eb8**, staged at
  ~/workspace/your_files/NovaVM-v0.0.73.ipa.
- Verified from the IPA's own Info.plist: bundle id
  `com.nova.vm`, CFBundleShortVersionString `0.0.73`,
  UIFileSharingEnabled true, LSSupportsOpeningDocumentsInPlace
  true.
- Binary string scan of the shipped executable: 0 occurrences
  of `NovaJIT`, `wxTransition`, `runTrampoline`, `jit(path`;
  the literal `Halted — Interpreter` present exactly once.
  The JIT is not in the shipped binary.

## Consequence for device testing

The v0.0.71/v0.0.72 StikDebug device proof ("Halted — JIT"
under attach) is moot for the default app — v0.0.73 has one
engine and its status line always reads "Halted —
Interpreter". bench.bin on-device still gives true iPad
interpreter rates if wanted. If Sean ever wants the JIT back
in the app, the promotion path is the J5 record in reverse:
the lane copy and its gates never went away.
