# NOVA — Custom Stack-Machine CPU Architecture

**NOVA** is a from-scratch 64-bit stack-machine CPU architecture — not RISC, not CISC, not ARM, not x86. A completely original design with variable-length instructions, hardware-managed stacks, and modern features (SIMD, crypto, MMU, virtualization).

This repo contains:
- **docs/** — Architecture specification, firmware notes
- **isa/** — Complete instruction set reference with opcode map
- **microcode/** — Micro-operation decomposition for every complex instruction
- **vm-app/** — iOS VM app (Swift/SwiftUI) that emulates NOVA on Apple Silicon
- **novas.py** — NOVA assembler (assembly → binary)
- **examples/** — Example NOVA programs

## Quick Start

```bash
# Assemble a program
python3 novas.py examples/hello.nova -o hello.bin

# The iOS app loads .bin files via the Files app
```

## Architecture Highlights

- **Stack-based**: zero-operand ALU, 4 hardware stacks (data, call, exception, vector)
- **Variable-length instructions**: 1–9 bytes (avg ~1.6 bytes vs 4 for RISC)
- **Modern features**: 128-bit SIMD vector stack, AES/SHA-2 crypto, 4 privilege levels, MMU with 4KB/2MB/1GB pages, hardware performance counters, debug/trace
- **Deterministic**: VM-friendly, no undefined behavior

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full specification.

## iOS VM App

The `vm-app/` directory contains a SwiftUI app that:
- Opens to a blank menu with a firmware toggle
- Loads NOVA binaries via the Files app
- Runs the VM on a background thread with a live console
- Supports custom firmware or the built-in default
- Optimized for Apple Silicon M3+

## Documentation

Full documentation is published at the GitHub Pages site (see `docs/` branch).

---

*Designed and built with Muse. "Built with Muse"*
