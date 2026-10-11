# NOVA Instruction Set Reference (Stack Machine)

**Version:** 2.0
**Encoding:** Variable-length, 1–9 bytes, little-endian immediates

Notation: `S` = data stack. `a`, `b` = top two items (`a` = top). `PUSH x` pushes x. `a b → c` means pop a,b push c.

---

## 0x00–0x3F: Stack Manipulation

| Opcode | Mnemonic | Bytes | Stack Effect | Description |
|--------|----------|-------|--------------|-------------|
| `0x00` | NOP | 1 | `→` | No operation |
| `0x01` | PUSH8 | 2 | `→ n` | Push sign-extended 8-bit immediate |
| `0x02` | PUSH16 | 3 | `→ n` | Push sign-extended 16-bit immediate |
| `0x03` | PUSH32 | 5 | `→ n` | Push sign-extended 32-bit immediate |
| `0x04` | PUSH64 | 9 | `→ n` | Push 64-bit immediate |
| `0x05` | POP | 1 | `a →` | Discard top |
| `0x06` | POPN | 2 | `… →` | Discard top N items (N = next byte) |
| `0x07` | DUP | 1 | `a → a a` | Duplicate top |
| `0x08` | DUP2 | 1 | `a b → a b a b` | Duplicate top two |
| `0x09` | SWAP | 1 | `a b → b a` | Swap top two |
| `0x0A` | ROT | 1 | `a b c → b c a` | Rotate top three |
| `0x0B` | ROTR | 1 | `a b c → c a b` | Rotate top three reverse |
| `0x0C` | OVER | 1 | `a b → a b a` | Copy second item to top |
| `0x0D` | TUCK | 1 | `a b → b a b` | Tuck top under second |
| `0x0E` | PICK | 2 | `… → n` | Copy Nth item to top (N = next byte, 0 = top) |
| `0x0F` | ROLL | 2 | `… →` | Rotate N items (N = next byte) |
| `0x10` | DEPTH | 1 | `→ d` | Push data-stack depth |
| `0x11` | DSPGET | 1 | `→ dsp` | Push DSP value |
| `0x12` | DSPSET | 1 | `a →` | Set DSP = a (privileged) |
| `0x13` | FPGET | 1 | `→ fp` | Push FP value |
| `0x14` | ENTER | 2 | `→` | Build frame: push FP to call stack, FP=DSP, reserve N slots (N = next byte) |
| `0x15` | LEAVE | 1 | `→` | Tear down frame: DSP=FP, FP=pop call stack |
| `0x16` | LOADL | 2 | `→ v` | Push local FP[N] (N = next byte) |
| `0x17` | STORL | 2 | `v →` | Pop into local FP[N] (N = next byte) |
| `0x18` | LOADARG | 2 | `→ v` | Push argument N above frame (N = next byte) |
| `0x19` | PUSHR | 2 | `→ v` | Push general register R[N] (N = next byte, 0–15) |
| `0x1A` | POPR | 2 | `v →` | Pop stack top into R[N] (N = next byte, 0–15) |

## 0x40–0x7F: Integer Arithmetic & Logic (zero-operand)

All pop operands, push result. Signed unless noted.

| Opcode | Mnemonic | Stack Effect | Description |
|--------|----------|--------------|-------------|
| `0x40` | ADD | `a b → c` | c = b + a |
| `0x41` | SUB | `a b → c` | c = b − a |
| `0x42` | MUL | `a b → c` | c = b × a (low 64) |
| `0x43` | MULH | `a b → c` | c = high 64 of b × a (signed) |
| `0x44` | DIV | `a b → c` | c = b ÷ a (signed; div-by-zero traps) |
| `0x45` | DIVU | `a b → c` | c = b ÷ a (unsigned) |
| `0x46` | REM | `a b → c` | c = b mod a (signed) |
| `0x47` | REMU | `a b → c` | c = b mod a (unsigned) |
| `0x48` | AND | `a b → c` | c = b & a |
| `0x49` | OR | `a b → c` | c = b \| a |
| `0x4A` | XOR | `a b → c` | c = b ^ a |
| `0x4B` | NOT | `a → c` | c = ~a |
| `0x4C` | NEG | `a → c` | c = −a |
| `0x4D` | SHL | `a b → c` | c = b << (a & 63) |
| `0x4E` | SHR | `a b → c` | c = b >> (a & 63), logical |
| `0x4F` | SAR | `a b → c` | c = b >> (a & 63), arithmetic |
| `0x50` | INC | `a → c` | c = a + 1 |
| `0x51` | DEC | `a → c` | c = a − 1 |
| `0x52` | CMP | `a b →` | Set NZCV from (b − a); pushes nothing |
| `0x53` | TST | `a → a` | Set NZCV from a; keeps a |
| `0x54` | EQ | `a b → c` | c = (b == a) ? 1 : 0 |
| `0x55` | NE | `a b → c` | c = (b != a) ? 1 : 0 |
| `0x56` | LT | `a b → c` | c = (b < a) ? 1 : 0, signed |
| `0x57` | LTU | `a b → c` | c = (b < a) ? 1 : 0, unsigned |
| `0x58` | MIN | `a b → c` | c = min(b,a), signed |
| `0x59` | MAX | `a b → c` | c = max(b,a), signed |
| `0x5A` | CLZ | `a → c` | Count leading zeros |
| `0x5B` | CTZ | `a → c` | Count trailing zeros |
| `0x5C` | POPCNT | `a → c` | Population count |
| `0x5D` | REV8 | `a → c` | Byte-reverse 64-bit |
| `0x5E` | EXT8 | `a → c` | Sign-extend low 8 bits |
| `0x5F` | EXT16 | `a → c` | Sign-extend low 16 bits |
| `0x60` | EXT32 | `a → c` | Sign-extend low 32 bits |

## 0x80–0x9F: Memory

| Opcode | Mnemonic | Bytes | Stack Effect | Description |
|--------|----------|-------|--------------|-------------|
| `0x80` | LOAD8 | 1 | `addr → v` | Push sign-extended byte at addr |
| `0x81` | LOAD16 | 1 | `addr → v` | Push sign-extended halfword |
| `0x82` | LOAD32 | 1 | `addr → v` | Push sign-extended word |
| `0x83` | LOAD64 | 1 | `addr → v` | Push doubleword |
| `0x84` | LOADU8 | 1 | `addr → v` | Push zero-extended byte |
| `0x85` | LOADU16 | 1 | `addr → v` | Push zero-extended halfword |
| `0x86` | LOADU32 | 1 | `addr → v` | Push zero-extended word |
| `0x87` | STORE8 | 1 | `v addr →` | Store low byte |
| `0x88` | STORE16 | 1 | `v addr →` | Store low halfword |
| `0x89` | STORE32 | 1 | `v addr →` | Store low word |
| `0x8A` | STORE64 | 1 | `v addr →` | Store doubleword |
| `0x8B` | LOADO | 2 | `base → v` | Push mem[base + next_byte] (small offset) |
| `0x8C` | STOREO | 2 | `v base →` | mem[base + next_byte] = v |
| `0x8D` | LOADX | 1 | `idx base → v` | Push mem[base + idx] (indexed) |
| `0x8E` | STOREX | 1 | `v idx base →` | mem[base + idx] = v |
| `0x8F` | MEMCPY | 1 | `n dst src →` | Copy n bytes src→dst |
| `0x90` | MEMSET | 1 | `n v dst →` | Fill n bytes at dst with byte v |
| `0x91` | MEMCMP | 1 | `n p2 p1 → c` | Compare n bytes; c = −1/0/1 |

Atomics (`0x98–0x9F`):

| Opcode | Mnemonic | Stack Effect | Description |
|--------|----------|--------------|-------------|
| `0x98` | LR | `addr → v` | Load-reserved 64-bit |
| `0x99` | SC | `v addr → ok` | Store-conditional; ok = 1 if success |
| `0x9A` | AMOADD | `v addr → old` | Atomic add, push old |
| `0x9B` | AMOSWAP | `v addr → old` | Atomic swap, push old |
| `0x9C` | AMOAND | `v addr → old` | Atomic AND, push old |
| `0x9D` | AMOOR | `v addr → old` | Atomic OR, push old |

## 0xA0–0xBF: Control Flow

| Opcode | Mnemonic | Bytes | Stack Effect | Description |
|--------|----------|-------|--------------|-------------|
| `0xA0` | JMP | 3 | `→` | PC += sign-extended 16-bit offset |
| `0xA1` | JMP32 | 5 | `→` | PC += sign-extended 32-bit offset |
| `0xA2` | BZ | 3 | `a →` | Branch if a == 0 (pop) |
| `0xA3` | BNZ | 3 | `a →` | Branch if a != 0 (pop) |
| `0xA4` | BLT | 3 | `→` | Branch if N != V (uses NZCV, no pop) |
| `0xA5` | BGE | 3 | `→` | Branch if N == V |
| `0xA6` | BEQ | 3 | `→` | Branch if Z set |
| `0xA7` | BNE | 3 | `→` | Branch if Z clear |
| `0xA8` | CALL | 3 | `→` | Push PC+3 to call stack, PC += offset16 |
| `0xA9` | CALL32 | 5 | `→` | Push PC+5 to call stack, PC += offset32 |
| `0xAA` | CALLI | 1 | `addr →` | Indirect call: pop addr, push ret, PC = addr |
| `0xAB` | RET | 1 | `→` | PC = pop call stack |
| `0xAC` | JMPI | 1 | `addr →` | PC = pop |
| `0xAD` | LOOP | 3 | `n → n'` | Decrement top; if result != 0, branch (keeps counter) |
| `0xAE` | TRAP | 2 | `→` | Software trap with 8-bit cause code |

## 0xC0–0xCF: System

| Opcode | Mnemonic | Bytes | Description |
|--------|----------|-------|-------------|
| `0xC0` | ECALL | 1 | Environment call (trap up one privilege level) |
| `0xC1` | EBREAK | 1 | Breakpoint trap |
| `0xC2` | MRET | 1 | Return from Machine trap (pop exception frame) |
| `0xC3` | SRET | 1 | Return from Supervisor trap |
| `0xC4` | HRET | 1 | Return from Hypervisor trap |
| `0xC5` | WFI | 1 | Wait for interrupt (sleep) |
| `0xC6` | CSRGET | 2 | Push CSR[N] (N = next byte) |
| `0xC7` | CSRSET | 2 | Pop into CSR[N] (privileged) |
| `0xC8` | FENCE | 1 | Full memory barrier |
| `0xC9` | FENCEI | 1 | Instruction barrier (flush I-cache) |
| `0xCA` | RDPMC | 2 | Push performance counter N |
| `0xCB` | RDTIME | 1 | Push TIME register |
| `0xCC` | RDCYCLE | 1 | Push CYCLE register |
| `0xCD` | TLBFLUSH | 1 | Flush TLB (privileged) |

CSR numbers for `CSRGET`/`CSRSET`: `0`=STATUS, `1`=CAUSE, `2`=EPC, `3`=TVAL, `4`=SATP, `5`=DSLIM, `6`=CSLIM, `7`=ESLIM, `8`=VSLIM.

## 0xD0–0xDF: Floating-Point

FP values are 32/64-bit bit patterns on the data stack. `S` = single, `D` = double.

| Opcode | Mnemonic | Stack Effect | Description |
|--------|----------|--------------|-------------|
| `0xD0` | FADD.S | `a b → c` | c = b + a (float) |
| `0xD1` | FADD.D | `a b → c` | c = b + a (double) |
| `0xD2` | FSUB.S | `a b → c` | c = b − a (float) |
| `0xD3` | FSUB.D | `a b → c` | c = b − a (double) |
| `0xD4` | FMUL.S | `a b → c` | c = b × a (float) |
| `0xD5` | FMUL.D | `a b → c` | c = b × a (double) |
| `0xD6` | FDIV.S | `a b → c` | c = b ÷ a (float) |
| `0xD7` | FDIV.D | `a b → c` | c = b ÷ a (double) |
| `0xD8` | FSQRT.D | `a → c` | c = sqrt(a) (double) |
| `0xD9` | F2I | `a → c` | Double bits → int64 (truncate) |
| `0xDA` | I2F | `a → c` | int64 → double bits |
| `0xDB` | F2S | `a → c` | Double → float (narrow) |
| `0xDC` | S2F | `a → c` | Float → double (widen) |
| `0xDD` | FCMP.D | `a b →` | Set NZCV from double compare |
| `0xDE` | FMIN.D | `a b → c` | c = min(b,a) |
| `0xDF` | FMAX.D | `a b → c` | c = max(b,a) |

## 0xE0–0xEF: Vector/SIMD (vector stack)

Vector stack entries are 128-bit. Suffix selects lane width.

| Opcode | Mnemonic | Vector-Stack Effect | Description |
|--------|----------|---------------------|-------------|
| `0xE0` | VPUSH | `→ v` | Push 128-bit immediate? No — pops 2×64 from data stack, pushes 128-bit vector |
| `0xE1` | VPOP | `v →` | Pop 128-bit vector, push low/high 64-bit halves to data stack |
| `0xE2` | VADD.4S | `a b → c` | 4 × 32-bit add |
| `0xE3` | VADD.2D | `a b → c` | 2 × 64-bit add |
| `0xE4` | VSUB.4S | `a b → c` | 4 × 32-bit sub |
| `0xE5` | VMUL.4S | `a b → c` | 4 × 32-bit mul (low 32) |
| `0xE6` | VAND | `a b → c` | 128-bit AND |
| `0xE7` | VOR | `a b → c` | 128-bit OR |
| `0xE8` | VXOR | `a b → c` | 128-bit XOR |
| `0xE9` | VSHL.4S | `n v → c` | Shift each 32-bit lane left by n (n from data stack) |
| `0xEA` | VLOAD | `addr → v` | Push 128-bit mem[addr] (addr from data stack) |
| `0xEB` | VSTORE | `v addr →` | mem[addr] = pop vector |
| `0xEC` | VCMP.4S | `a b → m` | Push 4-bit lane mask to data stack |
| `0xED` | VSEL | `m a b → c` | Blend: per-lane select by mask m (data stack) |

## 0xF0–0xFF: Crypto & Extended

| Opcode | Mnemonic | Bytes | Stack Effect | Description |
|--------|----------|-------|--------------|-------------|
| `0xF0` | AESENC | 1 | `k s → c` | One AES round: state s with round key k |
| `0xF1` | AESDEC | 1 | `k s → c` | One AES inverse round |
| `0xF2` | AESKEY | 1 | `k r → k'` | AES key expansion step (r = round const) |
| `0xF3` | SHA256C | 1 | `b s → s'` | SHA-256 compression: state s, block b (block = 2 pops: 512 bits as 4×128 vector-stack? Simplified: pops 8×64 from data stack) |
| `0xF4` | RDRAND | 1 | `→ r` | Push 64-bit hardware random |
| `0xF5` | CPUID | 1 | `n → v` | Push CPU info leaf n |
| `0xFF` | EXT | 2 | — | Escape: second byte selects extended op (reserved) |

`CPUID` leaves: `0` → vendor `0x4E564F41`; `1` → arch version; `2` → feature bits (bit0=FP, bit1=SIMD, bit2=crypto, bit3=virt).

---

## Instruction Length Summary

| Pattern | Length | Example |
|---------|--------|---------|
| Single byte | 1 | ADD, DUP, RET |
| Opcode + 1B imm | 2 | PUSH8, PICK, ENTER |
| Opcode + 2B imm | 3 | PUSH16, JMP, BZ, CALL |
| Opcode + 4B imm | 5 | PUSH32, JMP32, CALL32 |
| Opcode + 8B imm | 9 | PUSH64 |

Average instruction length for typical code: ~1.6 bytes (vs 4 bytes fixed for RISC).

---

*End of ISA Reference v2.0*
