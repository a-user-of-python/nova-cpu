# NOVA Microcode Specification

**Version:** 2.0
**Purpose:** Defines how complex NOVA instructions decompose into micro-operations.

---

## 1. Micro-Architecture Overview

The NOVA VM (and any hardware implementation) executes each instruction as a sequence of **micro-operations** (uops). Simple instructions (ADD, DUP, PUSH8) are single-uop. Complex instructions (ENTER, CALL, MEMCPY, SHA256C, trap entry) expand into multi-uop sequences.

### 1.1 Micro-Operation Set

Each uop is a register transfer. Notation: `DST ← SRC`.

**Stack uops:**
| Uop | Meaning |
|-----|---------|
| `DPUSH Rn` | `mem[DSP−8] ← Rn; DSP ← DSP−8`; trap if `DSP−8 < DSLIM` |
| `DPOP Rn` | `Rn ← mem[DSP]; DSP ← DSP+8`; trap if empty |
| `CPUSH Rn` | Push Rn to call stack (checks CSLIM) |
| `CPOP Rn` | Pop call stack to Rn |
| `VPUSH128 Rn: Rm` | Push 128-bit pair to vector stack (checks VSLIM) |
| `VPOP128 Rn: Rm` | Pop 128-bit pair from vector stack |

**ALU uops:**
| Uop | Meaning |
|-----|---------|
| `ALU op, Rd, Ra, Rb` | `Rd ← Ra op Rb` (op ∈ ADD/SUB/AND/OR/XOR/SHL/SHR/SAR/MUL) |
| `ALU1 op, Rd, Ra` | `Rd ← op Ra` (op ∈ NOT/NEG/CLZ/CTZ/POPCNT/REV8) |
| `CMP Ra, Rb` | Set NZCV from `Ra − Rb` |

**Memory uops:**
| Uop | Meaning |
|-----|---------|
| `LD64 Rd, [Ra+imm]` | `Rd ← mem64[Ra+imm]` (with MMU + alignment check) |
| `ST64 [Ra+imm], Rb` | `mem64[Ra+imm] ← Rb` |
| `LD128 Vd, [Ra]` | 128-bit vector load |
| `ST128 [Ra], Vs` | 128-bit vector store |

**Control uops:**
| Uop | Meaning |
|-----|---------|
| `FETCH Rd` | `Rd ← mem8[PC]; PC ← PC+1` |
| `FETCH16/32/64 Rd` | Multi-byte little-endian fetch, PC advances |
| `JUMP Rn` | `PC ← Rn` |
| `BRANCH cond, off` | `if cond(NZCV): PC ← PC+off` |
| `TRAP cause` | Enter trap sequence (see §3) |

**Special:**
| Uop | Meaning |
|-----|---------|
| `T0 ← … / T1 ← …` | Scratch temporaries (microcode-only) |
| `HALT` | End of micro-program; resume fetch |

---

## 2. Instruction Micro-Programs

### 2.1 `ENTER N` (opcode 0x14)
Builds a stack frame with N local slots.
```
CPUSH FP            ; save old frame pointer to call stack
FP ← DSP            ; new frame base = current stack top
T0 ← N              ; slot count
LOOP_ENTER:
  CMP T0, 0
  BRANCH EQ, DONE
  DPUSH ZR          ; push zero-initialized slot (ZR reads 0)
  ALU SUB, T0, T0, 1
  JUMP LOOP_ENTER
DONE:
  HALT
```
Cost: 3 + N uops.

### 2.2 `LEAVE` (opcode 0x15)
```
DSP ← FP            ; drop locals
CPOP FP             ; restore caller frame pointer
HALT
```

### 2.3 `CALL off16` (opcode 0xA8)
```
FETCH16 T0                  ; T0 = signed offset
T1 ← PC                     ; T1 = return address (PC already past offset)
CPUSH T1                    ; save return
ALU ADD, T1, PC, T0         ; T1 = target
JUMP T1
HALT
```

### 2.4 `RET` (opcode 0xAB)
```
CPOP T0
JUMP T0
HALT
```

### 2.5 `PUSH64 imm` (opcode 0x04)
```
FETCH64 T0
DPUSH T0
HALT
```

### 2.5a `PUSHR n` / `POPR n` (opcodes 0x19/0x1A)
```
; PUSHR n:
FETCH T0                    ; T0 = register index
CMP T0, 16
BRANCH GEU, ILLEGAL          ; trap if n >= 16
DPUSH R[T0]                 ; R[T0] = register file read
HALT
; POPR n:
FETCH T0
CMP T0, 16
BRANCH GEU, ILLEGAL
DPOP T1
R[T0] ← T1                  ; R[T0] = popped value
HALT
```

### 2.5b `PUSHALL` / `POPALL` (opcodes 0x1B/0x1C)
```
; PUSHALL: dump entire register file to data stack
T0 ← 0
PUSHALL_LOOP:
  CMP T0, 16
  BRANCH GEU, DONE
  DPUSH R[T0]
  ALU ADD, T0, T0, 1
  JUMP PUSHALL_LOOP
DONE:
  HALT
; POPALL: restore entire register file from data stack
T0 ← 15
POPALL_LOOP:
  CMP T0, 0
  BRANCH LT, DONE2
  DPOP T1
  R[T0] ← T1
  ALU SUB, T0, T0, 1
  JUMP POPALL_LOOP
DONE2:
  HALT
```
*Note: context switches use PUSHALL/POPALL to save/restore all programmer-visible
register state in 2 instructions.*

### 2.6 `ADD` (opcode 0x40)
```
DPOP T0             ; a
DPOP T1             ; b
ALU ADD, T0, T1, T0 ; T0 = b + a
DPUSH T0
HALT
```

### 2.7 `LOAD64` (opcode 0x83)
```
DPOP T0                     ; address
LD64 T1, [T0+0]             ; MMU translate + check
DPUSH T1
HALT
```

### 2.8 `MEMCPY` (opcode 0x8F)
Stack: `n dst src →` (src on top).
```
DPOP T0             ; src
DPOP T1             ; dst
DPOP T2             ; n (byte count)
CMP T2, 0
BRANCH EQ, DONE
LOOP:
  LD64 T3, [T0+0]   ; 8-byte chunks; remainder handled below
  ST64 [T1+0], T3
  ALU ADD, T0, T0, 8
  ALU ADD, T1, T1, 8
  ALU SUB, T2, T2, 8
  CMP T2, 0
  BRANCH GT, LOOP
; byte remainder (T2 in −8..−1 → 0..7 remaining)
  ALU ADD, T2, T2, 8
  CMP T2, 0
  BRANCH EQ, DONE
TAIL:
  FETCH T3 (byte)   ; LD8 T3, [T0]
  ST8 [T1], T3
  ALU ADD, T0, T0, 1
  ALU ADD, T1, T1, 1
  ALU SUB, T2, T2, 1
  CMP T2, 0
  BRANCH GT, TAIL
DONE:
  HALT
```

### 2.9 `SHA256C` (opcode 0xF3)
Pops 8×64-bit (512-bit block) then 4×64-bit (256-bit state); pushes 4×64-bit new state. Implemented as a **single multi-cycle uop** in hardware, or 64 rounds of the compression function in microcode:
```
; T0..T7 = message schedule workspace, S0..S7 = state
DPOP S7 … DPOP S0   ; state (8 pops)
DPOP W15 … DPOP W0  ; block (8 pops of 64-bit = 512 bits)
; 64 rounds: each does σ/Ch/Maj + adds
ROUND i = 0..63:
  …(standard SHA-256 round, using ALU uops)…
DPUSH S0 … DPUSH S7 ; push new state (note: pushed S0 first = deepest)
HALT
```
*VM implementations SHOULD use a native crypto intrinsic here (e.g. Apple CryptoKit digest) rather than 64 micro-rounds — the micro-program defines semantics, not performance.*

### 2.10 `AESENC` (opcode 0xF0)
Stack: `k s → c` where s and k are each 2×64-bit (128-bit = 2 pops each).
```
DPOP T1 ; s_hi … (full 128-bit state into T0:T1)
DPOP T0
DPOP T3 ; k_hi
DPOP T2 ; k_lo → round key T2:T3
; One AES round: SubBytes, ShiftRows, MixColumns, AddRoundKey
CRYPTO AESROUND, T0:T1, T2:T3
DPUSH T0
DPUSH T1
HALT
```
`CRYPTO` is a single complex uop (S-box + GF math). VM uses hardware AES if available.

### 2.11 `VADD.4S` (opcode 0xE2)
```
VPOP128 T0:T1       ; a (128-bit)
VPOP128 T2:T3       ; b
VALU VADD4S, T0:T1, T2:T3, T0:T1   ; lane-wise 32-bit add
VPUSH128 T0:T1
HALT
```

### 2.12 `ECALL` (opcode 0xC0)
```
TRAP 8              ; cause 8 = Environment call (U-mode); CPU adjusts by privilege
HALT
```

---

## 3. Trap Entry Micro-Program

On any trap (instruction fault, ECALL, interrupt, stack overflow):
```
; 1. Save state to exception stack
EPUSH STATUS        ; exception stack push (checks ESLIM; double-fault if overflow)
EPUSH PC
EPUSH CAUSE         ; CAUSE already set by trap source
EPUSH TVAL
; 2. Elevate privilege
STATUS.PPRIV ← STATUS.PRIV
STATUS.PRIV ← target_level(cause)
STATUS.PIE ← STATUS.IE
STATUS.IE ← 0
; 3. Vector
T0 ← TRAPBASE[target_level]
ALU ADD, T0, T0, cause*16
JUMP T0
HALT
```

`MRET` reverses it:
```
EPOP TVAL
EPOP CAUSE
EPOP PC
EPOP STATUS         ; restores PRIV, IE from saved bits
JUMP PC             ; via restored PC value
HALT
```

---

## 4. Microcode ROM Layout (reference)

| Address Range | Contents |
|---------------|----------|
| `0x0000–0x00FF` | Single-uop instructions (direct dispatch) |
| `0x0100–0x03FF` | Multi-uop sequences (ENTER, CALL, MEMCPY, …) |
| `0x0400–0x04FF` | Trap entry/exit |
| `0x0500–0x05FF` | Crypto multi-round (SHA-256) |
| `0x0600–0x06FF` | Reset / init sequence |

The VM app implements this as a `switch` over opcodes with inline uop sequences — no separate ROM needed, but the decomposition above is normative for what each instruction MUST do observably.

---

*End of Microcode Specification v2.0*
