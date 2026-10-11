# NOVA CPU Architecture Specification

**Version:** 2.0 (Stack Machine Redesign)
**Designed:** 2026-10-11
**Classification:** 64-bit Stack Architecture, Variable-Length Instructions

---

## 1. Overview

NOVA is a 64-bit **stack-based** processor architecture. Unlike RISC designs with large register files, NOVA uses hardware-managed stacks as its primary computational model. Instructions are variable-length (1–9 bytes), zero-operand for ALU ops, with explicit stack manipulation primitives.

**Design goals:**
- Zero-operand ALU: arithmetic pops operands, pushes results — no register encoding overhead
- Hardware stacks: data stack, call stack, and exception stack managed by CPU
- Variable-length instructions: 1-byte common ops, longer only when immediates/addresses needed
- Modern features: SIMD vector stack, hardware crypto, MMU with paging, 4 privilege levels
- Deterministic, VM-friendly semantics

**Why a stack machine:**
- Denser code than RISC (no register fields in common instructions)
- Simpler compiler backend (expression evaluation maps directly to stack ops)
- Natural fit for VM implementation and JIT compilation
- Smaller architectural state to save/restore on context switches

---

## 2. Programmer's Model

### 2.1 Stacks

NOVA has four hardware stacks, each with a dedicated pointer register:

| Stack | Pointer | Width | Purpose |
|-------|---------|-------|----------|
| Data Stack (DS) | DSP | 64-bit entries | Operand stack for computation |
| Call Stack (CS) | CSP | 64-bit entries | Return addresses + frame markers |
| Exception Stack (ES) | ESP | 64-bit entries | Trap frames (saved state) |
| Vector Stack (VS) | VSP | 128-bit entries | SIMD operands |

Each stack pointer holds a **virtual address** pointing to the top element. `PUSH` decrements then writes; `POP` reads then increments. (Stacks grow downward, like most architectures.)

**Stack bounds:** Each stack has a configurable limit register (`DSLIM`, `CSLIM`, `ESLIM`, `VSLIM`). Push past the limit → `StackOverflow` trap. Pop past the base → `StackUnderflow` trap.

### 2.2 Registers

NOVA has **few** registers — most state lives on stacks:

| Register | Width | Purpose |
|----------|-------|---------|
| DSP | 64 | Data stack pointer |
| CSP | 64 | Call stack pointer |
| ESP | 64 | Exception stack pointer |
| VSP | 64 | Vector stack pointer (byte address into 128-bit entries) |
| PC | 64 | Program counter (byte address, 1-byte aligned) |
| FP | 64 | Frame pointer (points into data stack at current frame base) |
| STATUS | 64 | Processor status (privilege, flags, interrupt mask) |
| CAUSE | 64 | Trap cause |
| EPC | 64 | Exception program counter |
| TVAL | 64 | Trap value (fault address / opcode) |
| SATP | 64 | Page-table root + ASID |
| CYCLE | 64 | Cycle counter (read-only) |
| TIME | 64 | Wall-clock timer (read-only) |
| VENDOR | 64 | `0x4E564F41` ("NOVA") (read-only) |
| DSLIM/CSLIM/ESLIM/VSLIM | 64 | Stack limit registers |

**Scratch registers** (for microcode and firmware only, not general use):
- `T0`, `T1` — 64-bit temporaries, clobbered across calls

### 2.2a General-Purpose Registers

NOVA also has **16 general-purpose 64-bit registers** (`R0–R15`) that programs
can touch directly. They're the fast scratch space — no memory round-trip, no
stack juggling for hot values, loop counters, and pointers:

| Registers | Convention |
|-----------|------------|
| R0–R7 | Caller-saved temporaries |
| R8–R11 | Callee-saved (must preserve across CALL) |
| R12 | Global pointer (optional) |
| R13 | Thread pointer (optional) |
| R14–R15 | Reserved |

Access via `PUSHR n` (push R[n] onto the data stack) and `POPR n` (pop stack top
into R[n]). For full visibility, `PUSHALL` dumps all 16 registers onto the stack
at once (R0 first, R15 on top) and `POPALL` restores them — a complete register
context switch in two instructions. The stack remains the primary computational
model; registers are for values you want to keep close without shuffling the stack.

### 2.3 STATUS Register Layout

```
Bit  0:     IE     - Global interrupt enable
Bit  1:     PIE    - Previous interrupt enable
Bits 2-3:   PRIV   - Current privilege (0=User, 1=Supervisor, 2=Hypervisor, 3=Machine)
Bits 4-5:   PPRIV  - Previous privilege
Bit  6:     FS     - Floating-point enabled
Bit  7:     VS     - Vector stack enabled
Bits 8-11:  NZCV   - Condition flags (Negative, Zero, Carry, oVerflow)
             (set by CMP, TST; consumed by conditional branches)
Bits 12-15: DSDEPTH[3:0] - low bits of data-stack depth (for fast checks)
Bits 16-63: Reserved
```

**Condition flags** are set by `CMP` (compare top two stack items) and `TST` (test top of stack), and consumed by `BZ`, `BNZ`, `BLT`, `BGE`, etc.

### 2.4 Local Variable Frames

`ENTER n` allocates a frame: pushes current FP to call stack, sets FP=DSP, then reserves `n` 64-bit slots on the data stack (DSP -= 8*n). Locals are accessed via `LOADL i` (push `FP[i]`) and `STORL i` (`FP[i] = pop()`).

`LEAVE` reverses: DSP=FP, FP=pop from call stack, then `RET`.

---

## 3. Instruction Encoding

Instructions are **variable-length**, 1 to 9 bytes. The first byte is the opcode; some opcodes are followed by immediate bytes.

```
Byte 0:    opcode
Bytes 1..:  optional immediate (1, 2, 4, or 8 bytes, little-endian)
```

**Opcode space layout** (first byte):

| Range | Category |
|-------|----------|
| `0x00–0x3F` | Stack manipulation (PUSH, POP, DUP, SWAP, ROT, …) |
| `0x40–0x7F` | Integer arithmetic & logic (zero-operand) |
| `0x80–0x9F` | Memory (LOAD, STORE with addressing modes) |
| `0xA0–0xBF` | Control flow (branches, calls, returns) |
| `0xC0–0xCF` | System (traps, CSR access, fences) |
| `0xD0–0xDF` | Floating-point (pops/pushes bit patterns) |
| `0xE0–0xEF` | Vector/SIMD (operates on vector stack) |
| `0xF0–0xFF` | Crypto & misc (AES, SHA, RDRAND, prefix escapes) |

**`0xFF`** is an escape prefix: `0xFF <ext-opcode>` opens a 256-entry extended space for future expansion.

**Immediate sizes** are encoded in the opcode itself:
- `PUSH8` (`0x01`): 1-byte signed immediate follows
- `PUSH16` (`0x02`): 2-byte signed immediate follows
- `PUSH32` (`0x03`): 4-byte signed immediate follows
- `PUSH64` (`0x04`): 8-byte immediate follows

---

## 4. Memory Model

### 4.1 Address Space

- **64-bit virtual addresses**, little-endian
- **48-bit physical addresses**
- Page size **4 KB**, with 2 MB and 1 GB superpages
- Same 3-level page table format as v1.0 spec (kept — it's orthogonal to the execution model)

### 4.2 Memory Ordering

Weak ordering (RVWMO-compatible). `FENCE` for explicit barriers. Atomics use LR/SC-style reservation on the data stack top.

### 4.3 Privilege Levels

Same four levels (User/Supervisor/Hypervisor/Machine). Stack limit registers and page tables are per-privilege where appropriate. `ECALL` traps upward.

---

## 5. Modern Features (Stack-Adapted)

### 5.1 Vector Stack

Instead of 32 vector registers, NOVA has a **128-bit-wide vector stack**. `VADD` pops two 128-bit entries, pushes the result. Lane widths selected by opcode suffix (`.16B`, `.8H`, `.4S`, `.2D`). Predication via a mask popped from the data stack.

### 5.2 Cryptography

- `AESENC`: pops (round key, state), pushes encrypted state
- `AESDEC`: pops (round key, state), pushes decrypted state
- `SHA256C`: pops (state, block), pushes compressed state
- `RDRAND`: pushes 64-bit hardware random

### 5.3 Atomics

`AMOADD`: pops (address, value), atomically adds, pushes old value. LR/SC pair: `LR` pops address, pushes value + sets reservation; `SC` pops (address, value), pushes success flag.

### 5.4 Performance Monitoring

8 programmable counters, same events as v1.0. `RDPMC n` pushes counter `n`.

### 5.5 Debug

4 hardware breakpoints, 2 watchpoints, `EBREAK` traps. Trace buffer records (PC, opcode) pairs.

### 5.6 Power

`WFI` halts until interrupt. Same per-core controls.

---

## 6. Calling Convention (NOVA ABI)

Stack-based — no argument registers:

1. Caller pushes arguments left-to-right onto data stack
2. `CALL addr` pushes return address onto **call stack**, jumps
3. Callee uses `ENTER n` to build frame, accesses args above FP
4. Return value(s) left on data stack top
5. `LEAVE` + `RET` restore caller state
6. Caller cleans arguments with `POPN n` or `DROP`

**Example:**
```
    PUSH64  40        ; arg2
    PUSH64  2         ; arg1
    CALL    add       ; call stack: [retaddr]
add:
    ENTER   0         ; FP = DSP
    LOADL   1         ; push arg1 (FP[1])
    LOADL   0         ; push arg2 (FP[0])
    ADD               ; pop, pop, push sum
    LEAVE
    RET               ; return, sum on stack top
```

---

## 7. Exception Model

Same trap/interrupt cause codes as v1.0. On trap:
1. Push STATUS, PC, and trap info onto **exception stack**
2. Set PRIV to trap target level, disable interrupts
3. PC = trap vector

`MRET`/`SRET`/`HRET` pop the exception frame and resume.

**New stack-specific traps:**

| Code | Name | Cause |
|------|------|-------|
| 15 | StackOverflow | Push past DSLIM/CSLIM/VSLIM |
| 16 | StackUnderflow | Pop from empty stack |

---

*End of Architecture Specification v2.0*
