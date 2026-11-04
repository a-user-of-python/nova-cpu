#!/usr/bin/env bash
# run.sh — NOVA golden-baseline harness driver.
#
# Subcommands:
#   baseline   Build the harness against the SNAPSHOT core in baseline/ and
#              (re)generate tools/harness/golden/<program>.{console,cycles,halt}
#   gate       Build the harness against the CURRENT core in vm-app/ and diff
#              every program against the committed goldens. Exit 1 on any
#              mismatch; prints a per-program PASS/FAIL table.
#   speed      Build BOTH cores and time them on a compute-bound program
#              (fib), a print-heavy program (galaxy) and the bench workload
#              (speed-only, never a golden), fixed budgets, reporting
#              instructions/sec for each.
#   build      Build the harness against the current core only (smoke check).
#   speed-all  Build baseline, current, and EVERY variant core under
#              variants/*/ and time each on bench + galaxy (same budgets
#              as speed mode), printing one table per workload.
#   gate-variant <dir>
#              Build the harness against the variant core in <dir> (a
#              variants/<name> directory, or a bare variant name) and
#              diff every program against the committed goldens.
#
# Everything Swift is compiled with the system swiftc (Xcode) on the CI
# runner — there is no SwiftPM/Xcode project involved on purpose.
set -o pipefail
set -u

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
FIX_DIR="$HARNESS_DIR/fixtures"
GOLDEN_DIR="$HARNESS_DIR/golden"
BUILD_DIR="$HARNESS_DIR/build"
BIN_DIR="$BUILD_DIR/bin"
NOVAS="$ROOT/novas.py"

# Program manifest. Golden types (see README.md for the full defence):
#   exact          halts by itself (WFI/trap); console+cycles+halt byte-exact
#   budget-prefix  infinite loop; run for a fixed step budget — the console
#                  PREFIX, cycles (== budget) and halt=step-budget are exact
#   context-exact  exact, but only under the pinned NovaShell scheduler
#                  context documented in README.md (galaxy)
CASES="hello fib galaxy_examples hi galaxy_fixed galaxy bouncer counter selfmod"

# Per-case harness arguments: fills the ARGS array. $1 = case name.
set_case_args() {
  case "$1" in
    hello)          ARGS=(--program "$BIN_DIR/hello.bin"          --load-addr 0      --steps 1000000) ;;
    fib)            ARGS=(--program "$BIN_DIR/fib.bin"            --load-addr 0      --steps 10000000) ;;
    galaxy_examples) ARGS=(--program "$BIN_DIR/galaxy_examples.bin" --load-addr 4096 --steps 5000000) ;;
    hi)             ARGS=(--program "$BIN_DIR/hi.bin"             --load-addr 0      --steps 1000000) ;;
    galaxy_fixed)   ARGS=(--program "$BIN_DIR/galaxy_fixed.bin"   --load-addr 0      --steps 1000000) ;;
    galaxy)         ARGS=(--program "$BIN_DIR/galaxy.bin"         --load-addr 65536 --r15 65536 --steps 5000000) ;;
    bouncer)        ARGS=(--program "$BIN_DIR/bouncer.bin"        --load-addr 0      --steps 20000000) ;;
    counter)        ARGS=(--program "$BIN_DIR/counter.bin"        --load-addr 0      --steps 40000000) ;;
    selfmod)        ARGS=(--program "$BIN_DIR/selfmod.bin"        --load-addr 0      --steps 100000) ;;
    *) echo "run.sh: unknown case $1" >&2; return 1 ;;
  esac
}

# Assemble / stage every program binary into $BIN_DIR.
prepare_bins() {
  mkdir -p "$BIN_DIR"
  # Assembled from .nova with the repo assembler.
  python3 "$NOVAS" "$ROOT/examples/hello.nova"            -o "$BIN_DIR/hello.bin"        >/dev/null || return 1
  python3 "$NOVAS" "$ROOT/examples/fib.nova"              -o "$BIN_DIR/fib.bin"          >/dev/null || return 1
  python3 "$NOVAS" "$FIX_DIR/hi.nova"                     -o "$BIN_DIR/hi.bin"           >/dev/null || return 1
  python3 "$NOVAS" "$FIX_DIR/galaxy_fixed.nova"           -o "$BIN_DIR/galaxy_fixed.bin" >/dev/null || return 1
  python3 "$NOVAS" "$FIX_DIR/bouncer.nova"                -o "$BIN_DIR/bouncer.bin"      >/dev/null || return 1
  python3 "$NOVAS" "$FIX_DIR/counter.nova"                -o "$BIN_DIR/counter.bin"      >/dev/null || return 1
  python3 "$NOVAS" "$FIX_DIR/selfmod.nova"                -o "$BIN_DIR/selfmod.bin"      >/dev/null || return 1
  # Generated binaries: the checked-in .nova files for both galaxy programs
  # are PLACEHOLDER TEMPLATES (PUSH64 0xDEADBEEF... addresses patched by
  # gen_galaxy.py, data appended after the code). novas.py alone cannot
  # produce them — assembling the template yields a binary that faults on
  # its first byte. The canonical artifacts are the generator-produced .bins,
  # staged verbatim. See README.md.
  cp "$FIX_DIR/examples_galaxy.bin" "$BIN_DIR/galaxy_examples.bin" || return 1
  cp "$FIX_DIR/galaxy.bin"       "$BIN_DIR/galaxy.bin"          || return 1
  # bench is a SPEED-ONLY workload (never a golden — see README.md): staged
  # here so cmd_speed can time it; it is deliberately NOT in $CASES.
  cp "$FIX_DIR/bench.bin"        "$BIN_DIR/bench.bin"           || return 1
}

# swiftc discovery (macOS CI: Xcode's swiftc is on PATH; xcrun is the fallback).
if command -v swiftc >/dev/null 2>&1; then
  SWIFTC=(swiftc)
elif command -v xcrun >/dev/null 2>&1; then
  SWIFTC=(xcrun swiftc)
else
  echo "run.sh: no swiftc found (need Xcode / Command Line Tools)" >&2
  exit 2
fi

# build_harness <baseline|current> <output-binary>
build_harness() {
  local kind="$1" out="$2" cpu mem
  if [ "$kind" = "baseline" ]; then
    cpu="$HARNESS_DIR/baseline/NovaCPU.swift"
    mem="$HARNESS_DIR/baseline/NovaMemory.swift"
  else
    cpu="$ROOT/vm-app/NovaVM/VM/NovaCPU.swift"
    mem="$ROOT/vm-app/NovaVM/VM/NovaMemory.swift"
  fi
  echo "== Building harness against $kind core -> $out"
  echo "interpreter" > "$out.engine"
  "${SWIFTC[@]}" -O -o "$out" "$HARNESS_DIR/main.swift" "$cpu" "$mem"
}

# build_harness_dir <variant-dir> <output-binary>
# Builds the harness against a variant core: the directory's
# NovaCPU.swift, plus its NovaMemory.swift when it carries one,
# otherwise the current vm-app NovaMemory.swift (variants that only
# change the CPU share the shipping memory core).
# JIT variants (v0.0.71 J1, design §7.1): when the directory carries
# a NovaJIT.swift it is added to the swiftc line, the build defines
# NOVA_JIT_ENGINE (which enables the harness's --engine jit hooks in
# main.swift), and a "<binary>.engine" marker records "jit" so
# run_one passes --engine jit for this binary. Other variants are
# built exactly as before and get an "interpreter" marker.
build_harness_dir() {
  local dir="$1" out="$2" cpu mem
  cpu="$dir/NovaCPU.swift"
  if [ -f "$dir/NovaMemory.swift" ]; then
    mem="$dir/NovaMemory.swift"
  else
    mem="$ROOT/vm-app/NovaVM/VM/NovaMemory.swift"
  fi
  local extra_src="" extra_def=""
  if [ -f "$dir/NovaJIT.swift" ]; then
    extra_src="$dir/NovaJIT.swift"
    extra_def="-D NOVA_JIT_ENGINE"
    echo "jit" > "$out.engine"
  else
    echo "interpreter" > "$out.engine"
  fi
  echo "== Building harness against variant core $dir -> $out"
  # extra_def/extra_src are intentionally unquoted (single tokens,
  # empty for non-JIT variants).
  "${SWIFTC[@]}" -O $extra_def -o "$out" "$HARNESS_DIR/main.swift" "$cpu" "$mem" $extra_src
}

# run_one <harness-binary> <case> <outdir>
# Writes <outdir>/<case>.{console,cycles,halt} plus .meta/.stdout/.stderr logs.
run_one() {
  local bin="$1" name="$2" out="$3"
  mkdir -p "$out"
  set_case_args "$name" || return 1
  # JIT binaries (see build_harness_dir's .engine marker) run with
  # --engine jit; every other binary's invocation is unchanged.
  if [ -f "$bin.engine" ] && [ "$(cat "$bin.engine")" = "jit" ]; then
    ARGS+=(--engine jit)
  fi
  "$bin" "${ARGS[@]}" --console-out "$out/$name.console" --meta-out "$out/$name.meta" \
      >"$out/$name.stdout" 2>"$out/$name.stderr"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "run.sh: harness failed for $name (rc=$rc)" >&2
    cat "$out/$name.stderr" >&2
    return 1
  fi
  # Surface the JIT probe result in the gate log (JIT binaries only).
  if [ -f "$bin.engine" ] && [ "$(cat "$bin.engine")" = "jit" ]; then
    echo "  [$name] $(grep '^jit_probe=' "$out/$name.meta" | head -1) $(grep '^engine_active=' "$out/$name.meta" | head -1)"
    echo "  [$name] $(grep '^jit_stats=' "$out/$name.meta" | head -1)"
  fi
  grep '^cycles=' "$out/$name.meta" | cut -d= -f2  > "$out/$name.cycles"
  grep '^halt='   "$out/$name.meta" | cut -d= -f2- > "$out/$name.halt"
  return 0
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1;
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
  else echo "n/a"; fi
}

cmd_baseline() {
  mkdir -p "$BUILD_DIR" "$GOLDEN_DIR"
  build_harness baseline "$BUILD_DIR/nova-harness-baseline" || return 1
  prepare_bins || return 1
  local fail=0 name
  printf '%-18s %-28s %-12s %-8s %s\n' "PROGRAM" "HALT" "CYCLES" "BYTES" "CONSOLE SHA256"
  for name in $CASES; do
    if run_one "$BUILD_DIR/nova-harness-baseline" "$name" "$GOLDEN_DIR"; then
      printf '%-18s %-28s %-12s %-8s %s\n' "$name" \
        "$(cat "$GOLDEN_DIR/$name.halt")" "$(cat "$GOLDEN_DIR/$name.cycles")" \
        "$(wc -c < "$GOLDEN_DIR/$name.console" | tr -d ' ')" "$(sha256_of "$GOLDEN_DIR/$name.console")"
    else
      echo "BASELINE FAILED: $name"; fail=1
    fi
  done
  # Logs are build artifacts, not goldens — keep them out of the golden dir.
  mkdir -p "$BUILD_DIR/baseline-logs"
  mv "$GOLDEN_DIR"/*.meta "$GOLDEN_DIR"/*.stdout "$GOLDEN_DIR"/*.stderr "$BUILD_DIR/baseline-logs/" 2>/dev/null || true
  [ $fail -eq 0 ] && echo "== Goldens written to $GOLDEN_DIR"
  return $fail
}

cmd_gate() {
  if ! ls "$GOLDEN_DIR"/*.cycles >/dev/null 2>&1; then
    echo "run.sh: no committed goldens in $GOLDEN_DIR — run 'run.sh baseline' first and commit the result." >&2
    return 2
  fi
  mkdir -p "$BUILD_DIR"
  build_harness current "$BUILD_DIR/nova-harness-current" || return 1
  prepare_bins || return 1
  local out="$BUILD_DIR/gate-out" fail=0 name status
  rm -rf "$out"; mkdir -p "$out"
  printf '%-18s %-10s %s\n' "PROGRAM" "RESULT" "DETAIL"
  for name in $CASES; do
    status="PASS"; local detail=""
    if [ ! -f "$GOLDEN_DIR/$name.cycles" ]; then
      status="FAIL"; detail="no golden committed"
    elif ! run_one "$BUILD_DIR/nova-harness-current" "$name" "$out"; then
      status="FAIL"; detail="harness run failed (see $out/$name.stderr)"
    else
      cmp -s "$GOLDEN_DIR/$name.console" "$out/$name.console" || { status="FAIL"; detail="console differs"; }
      cmp -s "$GOLDEN_DIR/$name.cycles"  "$out/$name.cycles"  || { status="FAIL"; detail="${detail:+$detail; }cycles: golden=$(cat "$GOLDEN_DIR/$name.cycles") got=$(cat "$out/$name.cycles")"; }
      cmp -s "$GOLDEN_DIR/$name.halt"    "$out/$name.halt"    || { status="FAIL"; detail="${detail:+$detail; }halt: golden=$(cat "$GOLDEN_DIR/$name.halt") got=$(cat "$out/$name.halt")"; }
    fi
    printf '%-18s %-10s %s\n' "$name" "$status" "$detail"
    [ "$status" = "FAIL" ] && fail=1
  done
  if [ $fail -eq 0 ]; then echo "== GATE: all programs match the golden baseline"; else echo "== GATE: MISMATCHES FOUND"; fi
  return $fail
}

cmd_speed() {
  mkdir -p "$BUILD_DIR"
  build_harness baseline "$BUILD_DIR/nova-harness-baseline" || return 1
  build_harness current  "$BUILD_DIR/nova-harness-current"  || return 1
  prepare_bins || return 1
  local reps=5
  echo "== Speed: compute-bound (fib, runs to WFI) — best of $reps"
  set_case_args fib
  python3 "$HARNESS_DIR/speed.py" $reps "baseline fib" "$BUILD_DIR/nova-harness-baseline" -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  python3 "$HARNESS_DIR/speed.py" $reps "current  fib" "$BUILD_DIR/nova-harness-current"  -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  echo "== Speed: print-heavy (galaxy, ~9 KB console) — best of $reps"
  set_case_args galaxy
  python3 "$HARNESS_DIR/speed.py" $reps "baseline galaxy" "$BUILD_DIR/nova-harness-baseline" -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  python3 "$HARNESS_DIR/speed.py" $reps "current  galaxy" "$BUILD_DIR/nova-harness-current"  -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  echo "== Speed: bench (speed-only, ~50.5M instructions, bare at 0x0, halts WFI) — best of $reps"
  echo "   bench is NOT a golden: its printed rates derive from RDTIME (wall"
  echo "   clock), so its console bytes are non-deterministic by design. Only"
  echo "   its cycle count is deterministic, and only IPS is reported here."
  ARGS=(--program "$BIN_DIR/bench.bin" --load-addr 0 --steps 200000000)
  python3 "$HARNESS_DIR/speed.py" $reps "baseline bench" "$BUILD_DIR/nova-harness-baseline" -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  python3 "$HARNESS_DIR/speed.py" $reps "current  bench" "$BUILD_DIR/nova-harness-current"  -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || return 1
  echo "Note: ips = guest cycles / best wall time of the whole harness process"
  echo "(includes VM allocation + program load). Short runs are noise-prone;"
  echo "compare baseline vs current ratios, not absolute numbers."
}

cmd_build() {
  mkdir -p "$BUILD_DIR"
  build_harness current "$BUILD_DIR/nova-harness-current"
}

# gate-variant <dir>: like gate, but against the variant core in <dir>
# (which may also be given as a bare variant name under variants/).
cmd_gate_variant() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "usage: $0 gate-variant <variant-dir>" >&2
    return 2
  fi
  if [ ! -f "$dir/NovaCPU.swift" ]; then
    if [ -f "$HARNESS_DIR/variants/$dir/NovaCPU.swift" ]; then
      dir="$HARNESS_DIR/variants/$dir"
    else
      echo "run.sh: no NovaCPU.swift in variant dir: $dir" >&2
      return 2
    fi
  fi
  dir="$(cd "$dir" && pwd)"
  local vname
  vname="$(basename "$dir")"
  if ! ls "$GOLDEN_DIR"/*.cycles >/dev/null 2>&1; then
    echo "run.sh: no committed goldens in $GOLDEN_DIR — run 'run.sh baseline' first and commit the result." >&2
    return 2
  fi
  mkdir -p "$BUILD_DIR"
  build_harness_dir "$dir" "$BUILD_DIR/nova-harness-variant-$vname" || return 1
  prepare_bins || return 1
  local out="$BUILD_DIR/gate-variant-$vname-out" fail=0 cname status detail
  rm -rf "$out"; mkdir -p "$out"
  echo "== Gate variant: $vname ($dir)"
  printf '%-18s %-10s %s\n' "PROGRAM" "RESULT" "DETAIL"
  for cname in $CASES; do
    status="PASS"; detail=""
    if [ ! -f "$GOLDEN_DIR/$cname.cycles" ]; then
      status="FAIL"; detail="no golden committed"
    elif ! run_one "$BUILD_DIR/nova-harness-variant-$vname" "$cname" "$out"; then
      status="FAIL"; detail="harness run failed (see $out/$cname.stderr)"
    else
      cmp -s "$GOLDEN_DIR/$cname.console" "$out/$cname.console" || { status="FAIL"; detail="console differs"; }
      cmp -s "$GOLDEN_DIR/$cname.cycles"  "$out/$cname.cycles"  || { status="FAIL"; detail="${detail:+$detail; }cycles: golden=$(cat "$GOLDEN_DIR/$cname.cycles") got=$(cat "$out/$cname.cycles")"; }
      cmp -s "$GOLDEN_DIR/$cname.halt"    "$out/$cname.halt"    || { status="FAIL"; detail="${detail:+$detail; }halt: golden=$(cat "$GOLDEN_DIR/$cname.halt") got=$(cat "$out/$cname.halt")"; }
    fi
    printf '%-18s %-10s %s\n' "$cname" "$status" "$detail"
    [ "$status" = "FAIL" ] && fail=1
  done
  if [ $fail -eq 0 ]; then echo "== GATE ($vname): all programs match the golden baseline"; else echo "== GATE ($vname): MISMATCHES FOUND"; fi
  # J2 evidence step (jit variant only): run the speed-only bench
  # workload once under --engine jit with the just-built binary and
  # print its console + meta verbatim. bench is NOT a golden (its
  # printed rates derive from RDTIME, wall-clock), but its section
  # counts are deterministic. This step is evidence, not a gate: its
  # result never changes the gate's exit status.
  if [ "$vname" = "jit" ]; then
    local bbin="$BUILD_DIR/nova-harness-variant-$vname"
    local bout="$BUILD_DIR/bench-jit-out"
    mkdir -p "$bout"
    echo "== BENCH under --engine jit (evidence only, not gated)"
    "$bbin" --program "$BIN_DIR/bench.bin" --load-addr 0 --steps 200000000 \
        --engine jit --console-out "$bout/bench.console" --meta-out "$bout/bench.meta" \
        >"$bout/bench.stdout" 2>"$bout/bench.stderr" || true
    echo "--- bench stdout: $(cat "$bout/bench.stdout" 2>/dev/null)"
    echo "--- bench stderr: $(cat "$bout/bench.stderr" 2>/dev/null)"
    echo "--- bench meta:"
    cat "$bout/bench.meta" 2>/dev/null || true
    echo "--- bench console:"
    cat "$bout/bench.console" 2>/dev/null || true
    echo "--- end bench"
    # J4 firmware-mode smoke (design §7.2, evidence only — never
    # changes the gate's exit status): boot the app's embedded
    # NovaShell firmware (bytes extracted from NovaFirmware.swift)
    # with a scripted `help` line (--input-hex 68656c700a) under
    # --timer-interval 100000 on
    # BOTH engines and diff console/cycles/halt/pc. The shell is
    # interactive and has no golden; the claim is only that the
    # two engines agree with each other.
    echo "== FIRMWARE SMOKE under both engines (evidence only, not gated)"
    local fdir="$BUILD_DIR/fw-smoke-out"
    mkdir -p "$fdir/sandbox-a" "$fdir/sandbox-b"
    if build_harness current "$BUILD_DIR/nova-harness-current"; then
      if python3 - "$ROOT/vm-app/NovaVM/VM/NovaFirmware.swift" "$fdir/novash.bin" <<'FWPYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"novaShellBytes[^=]*=\s*\[(.*?)\n\]", src, re.S)
if not m:
    sys.exit(1)
vals = re.findall(r"0x[0-9a-fA-F]+", m.group(1))
open(sys.argv[2], "wb").write(bytes(int(v, 16) for v in vals))
print(f"extracted {len(vals)} firmware bytes")
FWPYEOF
      then
        "$BUILD_DIR/nova-harness-current" --firmware "$fdir/novash.bin" \
            --timer-interval 100000 --input-hex 68656c700a --steps 20000000 \
            --sandbox "$fdir/sandbox-a" \
            --console-out "$fdir/interp.console" --meta-out "$fdir/interp.meta" \
            >"$fdir/interp.stdout" 2>"$fdir/interp.stderr" || true
        "$bbin" --firmware "$fdir/novash.bin" --engine jit \
            --timer-interval 100000 --input-hex 68656c700a --steps 20000000 \
            --sandbox "$fdir/sandbox-b" \
            --console-out "$fdir/jit.console" --meta-out "$fdir/jit.meta" \
            >"$fdir/jit.stdout" 2>"$fdir/jit.stderr" || true
        echo "--- interp meta:"; cat "$fdir/interp.meta" 2>/dev/null || true
        echo "--- jit meta:"; cat "$fdir/jit.meta" 2>/dev/null || true
        if cmp -s "$fdir/interp.console" "$fdir/jit.console" \
           && cmp -s <(grep -E '^(cycles|halt|pc)=' "$fdir/interp.meta") <(grep -E '^(cycles|halt|pc)=' "$fdir/jit.meta"); then
          echo "FIRMWARE-SMOKE: engines AGREE (console + cycles + halt + pc identical)"
        else
          echo "FIRMWARE-SMOKE: engines DIFFER (see fw-smoke-out artifacts in build/)"
          echo "--- interp console (first 400 bytes):"; head -c 400 "$fdir/interp.console" 2>/dev/null || true; echo
          echo "--- jit console (first 400 bytes):"; head -c 400 "$fdir/jit.console" 2>/dev/null || true; echo
        fi
      else
        echo "FIRMWARE-SMOKE: SKIPPED (could not extract firmware bytes)"
      fi
    else
      echo "FIRMWARE-SMOKE: SKIPPED (current-core harness build failed)"
    fi
  fi
  return $fail
}

# speed-all: baseline + current + every variants/*/ core, timed on
# bench and galaxy with the same budgets as speed mode. Variants are
# auto-discovered by glob — new variant dirs need no script edits.
cmd_speed_all() {
  mkdir -p "$BUILD_DIR"
  build_harness baseline "$BUILD_DIR/nova-harness-baseline" || return 1
  build_harness current  "$BUILD_DIR/nova-harness-current"  || return 1
  prepare_bins || return 1
  local reps=5 fail=0 i vdir vname
  local labels=("baseline" "current")
  local bins=("$BUILD_DIR/nova-harness-baseline" "$BUILD_DIR/nova-harness-current")
  for vdir in "$HARNESS_DIR"/variants/*/; do
    [ -d "$vdir" ] || continue
    [ -f "$vdir/NovaCPU.swift" ] || continue
    vname="$(basename "$vdir")"
    if build_harness_dir "$vdir" "$BUILD_DIR/nova-harness-variant-$vname"; then
      labels+=("variant:$vname")
      bins+=("$BUILD_DIR/nova-harness-variant-$vname")
    else
      echo "== speed-all: variant $vname FAILED TO BUILD (skipped)"
      fail=1
    fi
  done
  # J4 speed-plumbing fix: speed.py invokes the binary directly and
  # so bypassed run_one's --engine logic — the jit binary was timed
  # running its interpreter fallback. speed.py forwards its args
  # verbatim, so the fix is to hand it the engine args here, per
  # binary, from the same .engine marker run_one reads. The jit
  # binary is timed TWICE per workload — D3 console callout on and
  # off (the J4 D3 A/B); every other binary is timed once, exactly
  # as before.
  echo "== Speed-all: bench (speed-only, ~50.5M instructions, bare at 0x0, halts WFI) — best of $reps"
  ARGS=(--program "$BIN_DIR/bench.bin" --load-addr 0 --steps 200000000)
  for i in "${!labels[@]}"; do
    if [ -f "${bins[$i]}.engine" ] && [ "$(cat "${bins[$i]}.engine")" = "jit" ]; then
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]}(d3=on) bench" "${bins[$i]}" -- "${ARGS[@]}" --engine jit --jit-d3 on --console-out "{console}" --meta-out "{meta}" || fail=1
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]}(d3=off) bench" "${bins[$i]}" -- "${ARGS[@]}" --engine jit --jit-d3 off --console-out "{console}" --meta-out "{meta}" || fail=1
    else
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]} bench" "${bins[$i]}" -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || fail=1
    fi
  done
  echo "== Speed-all: galaxy (print-heavy, ~9 KB console, pinned context) — best of $reps"
  set_case_args galaxy
  for i in "${!labels[@]}"; do
    if [ -f "${bins[$i]}.engine" ] && [ "$(cat "${bins[$i]}.engine")" = "jit" ]; then
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]}(d3=on) galaxy" "${bins[$i]}" -- "${ARGS[@]}" --engine jit --jit-d3 on --console-out "{console}" --meta-out "{meta}" || fail=1
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]}(d3=off) galaxy" "${bins[$i]}" -- "${ARGS[@]}" --engine jit --jit-d3 off --console-out "{console}" --meta-out "{meta}" || fail=1
    else
      python3 "$HARNESS_DIR/speed.py" $reps "${labels[$i]} galaxy" "${bins[$i]}" -- "${ARGS[@]}" --console-out "{console}" --meta-out "{meta}" || fail=1
    fi
  done
  echo "Note: bench is NOT a golden (its printed rates derive from RDTIME);"
  echo "only IPS is meaningful. Compare ratios within a column, not absolutes."
  return $fail
}

case "${1:-}" in
  baseline)     cmd_baseline ;;
  gate)         cmd_gate ;;
  speed)        cmd_speed ;;
  build)        cmd_build ;;
  speed-all)    cmd_speed_all ;;
  gate-variant) cmd_gate_variant "${2:-}" ;;
  *) echo "usage: $0 {baseline|gate|speed|build|speed-all|gate-variant <dir>}" >&2; exit 2 ;;
esac
