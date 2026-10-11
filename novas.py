#!/usr/bin/env python3
"""NOVA assembler — stack-machine assembly to binary.
Usage: python3 novas.py program.nova -o program.bin

Assembly syntax:
    ; comment
    label:
    PUSH8 42 / PUSH16 / PUSH32 / PUSH64 <imm>
    ADD SUB MUL DIV AND OR XOR NOT NEG ...   (zero-operand)
    JMP label / JMP32 label
    BZ label / BNZ label / BEQ label / BNE label / BLT label / BGE label
    CALL label / CALL32 label / RET
    LOAD64 / STORE64 / LOAD8 / STORE8 ...
    ENTER n / LEAVE / LOADL n / STORL n
    ECALL / EBREAK / WFI / RDTIME / RDCYCLE / RDRAND / CPUID
    FADD.D / FSUB.D / FMUL.D / FDIV.D ...
    .word <value>  — emit raw 64-bit word
"""

import sys, struct, re

# opcode table: mnemonic -> (opcode_byte, imm_size)
OPS = {
    'NOP': (0x00, 0),
    'PUSH8': (0x01, 1), 'PUSH16': (0x02, 2), 'PUSH32': (0x03, 4), 'PUSH64': (0x04, 8),
    'POP': (0x05, 0), 'DUP': (0x07, 0), 'DUP2': (0x08, 0),
    'SWAP': (0x09, 0), 'ROT': (0x0A, 0), 'ROTR': (0x0B, 0),
    'OVER': (0x0C, 0), 'TUCK': (0x0D, 0), 'DEPTH': (0x10, 0),
    'ENTER': (0x14, 1), 'LEAVE': (0x15, 0),
    'LOADL': (0x16, 1), 'STORL': (0x17, 1), 'LOADARG': (0x18, 1),
    'ADD': (0x40, 0), 'SUB': (0x41, 0), 'MUL': (0x42, 0), 'MULH': (0x43, 0),
    'DIV': (0x44, 0), 'DIVU': (0x45, 0), 'REM': (0x46, 0),
    'AND': (0x48, 0), 'OR': (0x49, 0), 'XOR': (0x4A, 0),
    'NOT': (0x4B, 0), 'NEG': (0x4C, 0),
    'SHL': (0x4D, 0), 'SHR': (0x4E, 0), 'SAR': (0x4F, 0),
    'INC': (0x50, 0), 'DEC': (0x51, 0),
    'CMP': (0x52, 0), 'TST': (0x53, 0),
    'EQ': (0x54, 0), 'NE': (0x55, 0), 'LT': (0x56, 0), 'LTU': (0x57, 0),
    'MIN': (0x58, 0), 'MAX': (0x59, 0),
    'CLZ': (0x5A, 0), 'CTZ': (0x5B, 0), 'POPCNT': (0x5C, 0), 'REV8': (0x5D, 0),
    'LOAD8': (0x80, 0), 'LOAD16': (0x81, 0), 'LOAD32': (0x82, 0), 'LOAD64': (0x83, 0),
    'LOADU8': (0x84, 0), 'STORE8': (0x87, 0), 'STORE16': (0x88, 0),
    'STORE32': (0x89, 0), 'STORE64': (0x8A, 0),
    'MEMCPY': (0x8F, 0), 'MEMSET': (0x90, 0),
    'LR': (0x98, 0), 'SC': (0x99, 0),
    'AMOADD': (0x9A, 0), 'AMOSWAP': (0x9B, 0),
    'JMP': (0xA0, 2), 'JMP32': (0xA1, 4),
    'BZ': (0xA2, 2), 'BNZ': (0xA3, 2),
    'BLT': (0xA4, 2), 'BGE': (0xA5, 2), 'BEQ': (0xA6, 2), 'BNE': (0xA7, 2),
    'CALL': (0xA8, 2), 'CALL32': (0xA9, 4),
    'CALLI': (0xAA, 0), 'RET': (0xAB, 0), 'JMPI': (0xAC, 0),
    'ECALL': (0xC0, 0), 'EBREAK': (0xC1, 0), 'WFI': (0xC5, 0),
    'FENCE': (0xC8, 0),
    'RDTIME': (0xCB, 0), 'RDCYCLE': (0xCC, 0),
    'FADD.D': (0xD1, 0), 'FSUB.D': (0xD3, 0), 'FMUL.D': (0xD5, 0), 'FDIV.D': (0xD7, 0),
    'F2I': (0xD9, 0), 'I2F': (0xDA, 0),
    'RDRAND': (0xF4, 0), 'CPUID': (0xF5, 0),
    'PICK': (0x0E, 1), 'POPN': (0x06, 1),
    'AESENC': (0xF0, 0), 'AESDEC': (0xF1, 0),
    'VADD.4S': (0xE2, 0), 'VADD.2D': (0xE3, 0),
}

def parse_int(s):
    s = s.strip()
    if s.startswith('0x'): return int(s, 16)
    if s.startswith('0b'): return int(s, 2)
    return int(s)

def assemble(src):
    lines = []
    for raw in src.split('\n'):
        line = raw.split(';')[0].strip()
        if line: lines.append(line)
    # Pass 1: labels
    labels = {}
    addr = 0
    items = []  # (addr, kind, payload)
    for line in lines:
        if line.endswith(':'):
            labels[line[:-1].strip()] = addr
            continue
        parts = line.split()
        mn = parts[0].upper()
        if mn == '.WORD':
            items.append((addr, 'word', parse_int(parts[1])))
            addr += 8
            continue
        if mn not in OPS:
            raise SyntaxError(f"Unknown mnemonic: {mn}")
        opc, isz = OPS[mn]
        items.append((addr, 'insn', (mn, opc, isz, parts[1:])))
        addr += 1 + isz
    # Pass 2: emit
    out = bytearray()
    for (a, kind, payload) in items:
        if kind == 'word':
            out += struct.pack('<Q', payload & 0xFFFFFFFFFFFFFFFF)
            continue
        mn, opc, isz, args = payload
        out.append(opc)
        if isz == 0: continue
        arg = args[0] if args else '0'
        # Branch/call → label or numeric offset
        if mn in ('JMP','JMP32','BZ','BNZ','BLT','BGE','BEQ','BNE','CALL','CALL32'):
            insn_len = 1 + isz
            if arg in labels:
                target = labels[arg]
                off = target - (a + insn_len)
            else:
                off = parse_int(arg)
            out += off.to_bytes(isz, 'little', signed=True)
        else:
            v = parse_int(arg)
            # PUSH64 allows full unsigned 64-bit range (e.g. MMIO addresses)
            signed = not (mn == 'PUSH64' and v >= 0)
            if mn == 'PUSH64' and v > 0xFFFFFFFFFFFFFFFF:
                raise ValueError(f"PUSH64 value out of range: {arg}")
            if mn == 'PUSH64':
                out += (v & 0xFFFFFFFFFFFFFFFF).to_bytes(isz, 'little', signed=False)
            else:
                out += v.to_bytes(isz, 'little', signed=True)
    return bytes(out)

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    src = open(sys.argv[1]).read()
    out_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == '-o' else 'a.out.bin'
    if '-o' in sys.argv:
        out_path = sys.argv[sys.argv.index('-o')+1]
    binary = assemble(src)
    open(out_path, 'wb').write(binary)
    print(f"Assembled {len(binary)} bytes → {out_path}")

if __name__ == '__main__':
    main()
