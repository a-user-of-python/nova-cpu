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
#              (fib) and a print-heavy program (galaxy), fixed budgets,
#              reporting instructions/sec for each.
#   build      Build the harness against the current core only (smoke check).
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
CASES="hello fib galaxy_examples hi galaxy_fixed galaxy bouncer counter"

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
  # Generated binaries: the checked-in .nova files for both galaxy programs
  # are PLACEHOLDER TEMPLATES (PUSH64 0xDEADBEEF... addresses patched by
  # gen_galaxy.py, data appended after the code). novas.py alone cannot
  # produce them — assembling the template yields a binary that faults on
  # its first byte. The canonical artifacts are the generator-produced .bins,
  # staged verbatim. See README.md.
  cp "$FIX_DIR/examples_galaxy.bin" "$BIN_DIR/galaxy_examples.bin" || return 1
  cp "$FIX_DIR/galaxy.bin"       "$BIN_DIR/galaxy.bin"          || return 1
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
  "${SWIFTC[@]}" -O -o "$out" "$HARNESS_DIR/main.swift" "$cpu" "$mem"
}

# run_one <harness-binary> <case> <outdir>
# Writes <outdir>/<case>.{console,cycles,halt} plus .meta/.stdout/.stderr logs.
run_one() {
  local bin="$1" name="$2" out="$3"
  mkdir -p "$out"
  set_case_args "$name" || return 1
  "$bin" "${ARGS[@]}" --console-out "$out/$name.console" --meta-out "$out/$name.meta" \
      >"$out/$name.stdout" 2>"$out/$name.stderr"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "run.sh: harness failed for $name (rc=$rc)" >&2
    cat "$out/$name.stderr" >&2
    return 1
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
  echo "Note: ips = guest cycles / best wall time of the whole harness process"
  echo "(includes VM allocation + program load). Short runs are noise-prone;"
  echo "compare baseline vs current ratios, not absolute numbers."
}

cmd_build() {
  mkdir -p "$BUILD_DIR"
  build_harness current "$BUILD_DIR/nova-harness-current"
}

case "${1:-}" in
  baseline) cmd_baseline ;;
  gate)     cmd_gate ;;
  speed)    cmd_speed ;;
  build)    cmd_build ;;
  *) echo "usage: $0 {baseline|gate|speed|build}" >&2; exit 2 ;;
esac
