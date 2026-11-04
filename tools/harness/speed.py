#!/usr/bin/env python3
"""speed.py — time nova-harness runs and report instructions/sec.

Usage: speed.py REPS LABEL BINARY -- <harness args...>
Reads cycles= from the meta file the harness writes (the harness is invoked
with --console-out/--meta-out pointing at temp files supplied by run.sh via
the placeholders {console} and {meta} in the args).
Prints one line: LABEL  cycles=N  best_wall=Ss  ips=N
"""
import subprocess, sys, tempfile, time, os

def main():
    reps = int(sys.argv[1])
    label = sys.argv[2]
    binary = sys.argv[3]
    assert sys.argv[4] == "--"
    args = sys.argv[5:]
    best = None
    cycles = None
    with tempfile.TemporaryDirectory() as td:
        console = os.path.join(td, "console.bin")
        meta = os.path.join(td, "meta.txt")
        real_args = [a.replace("{console}", console).replace("{meta}", meta) for a in args]
        for _ in range(reps):
            t0 = time.perf_counter()
            r = subprocess.run([binary] + real_args, capture_output=True, text=True)
            dt = time.perf_counter() - t0
            if r.returncode != 0:
                print(f"{label}: harness failed rc={r.returncode}: {r.stderr.strip()}")
                return 1
            for line in open(meta).read().splitlines():
                if line.startswith("cycles="):
                    cycles = int(line.split("=", 1)[1])
            if best is None or dt < best:
                best = dt
    ips = int(cycles / best) if cycles and best else 0
    print(f"{label:<28s} cycles={cycles:<12d} best_wall={best:.4f}s  ips={ips:,}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
