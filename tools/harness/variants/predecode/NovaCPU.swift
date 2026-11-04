// VARIANT: predecode — basic-block decode cache on top of the V1 core.
// Built for the golden harness only; NOT promoted into vm-app/.
// step() below is byte-identical to the V1 core. run() is reimplemented
// to execute from per-run decoded blocks; step() remains the fallback
// for bail-list instructions and undecodable bytes. See
// agent_notes/v070-agg-b.md for the invalidation rule set.
// NovaCPU.swift — NOVA stack-machine CPU emulator
// Optimized for Apple Silicon (M3+) withContiguousArray storage,
// inlinable hot paths, and minimal ARC traffic in the fetch loop.
//
// NOTE: NovaTrap is defined in NovaMemory.swift (shared).

import Foundation

// MARK: - Privilege
enum NovaPrivilege: UInt64 {
    case user = 0, supervisor = 1, hypervisor = 2, machine = 3
}

// MARK: - CPU State
final class NovaCPU {

    // Registers
    var dsp: UInt64 = 0       // Data stack pointer (byte address, grows down)
    var csp: UInt64 = 0       // Call stack pointer
    var esp: UInt64 = 0       // Exception stack pointer
    var vsp: UInt64 = 0       // Vector stack pointer
    var pc: UInt64 = 0        // Program counter
    var fp: UInt64 = 0        // Frame pointer
    var status: UInt64 = 0    // STATUS register
    var cause: UInt64 = 0
    var epc: UInt64 = 0
    var tval: UInt64 = 0
    var satp: UInt64 = 0
    var savedStatusForMret: UInt64 = 0  // Saved status for MRET (timer interrupt)
    var dslim: UInt64 = 0
    var cslim: UInt64 = 0
    var eslim: UInt64 = 0
    var vslim: UInt64 = 0
    var cycle: UInt64 = 0

    // NZCV flags (decoded from status for speed)
    var flagN = false, flagZ = false, flagC = false, flagV = false

    // Memory backing (owned by NovaMemory)
    var memory: NovaMemory!

    // Execution control
    var running = false
    var trapHandler: ((NovaTrap, UInt64) -> Void)?

    // General-purpose registers R0–R15 (programmer-visible)
    var regs: [UInt64] = Array(repeating: 0, count: 16)

    // Scratch
    private var t0: UInt64 = 0
    private var t1: UInt64 = 0

    // MARK: - Stack Primitives (inlinable hot paths)

    @inline(__always) private func checkPush(_ newSP: UInt64, limit: UInt64) throws {
        if newSP < limit { throw NovaTrap.stackOverflow }
    }

    @inline(__always) func dpush(_ v: UInt64) throws {
        let nsp = dsp &- 8
        if nsp < dslim { throw NovaTrap.stackOverflow }
        try memory.write64(nsp, v)
        dsp = nsp
    }

    @inline(__always) func dpop() throws -> UInt64 {
        // Underflow check: DSP must be below stack base.
        // Stack base tracked by memory object.
        if dsp >= memory.dataStackBase { throw NovaTrap.stackUnderflow }
        let v = try memory.read64(dsp)
        dsp = dsp &+ 8
        return v
    }

    @inline(__always) func cpush(_ v: UInt64) throws {
        let nsp = csp &- 8
        if nsp < cslim { throw NovaTrap.stackOverflow }
        try memory.write64(nsp, v)
        csp = nsp
    }

    @inline(__always) func cpop() throws -> UInt64 {
        if csp >= memory.callStackBase { throw NovaTrap.stackUnderflow }
        let v = try memory.read64(csp)
        csp = csp &+ 8
        return v
    }

    // MARK: - Flag helpers

    @inline(__always) private func setFlagsSub(_ a: UInt64, _ b: UInt64) {
        // flags for (a - b)
        let r = a &- b
        flagN = (r & 0x8000_0000_0000_0000) != 0
        flagZ = r == 0
        flagC = a >= b  // NOT borrow
        flagV = ((a ^ b) & (a ^ r) & 0x8000_0000_0000_0000) != 0
    }

    // MARK: - Main step

    func step() throws {
        // v0.0.70: resolve the implicitly-unwrapped memory reference ONCE
        // per step; the timer check, opcode fetch and every operand access
        // below go through this single reference instead of re-unwrapping
        // `memory` per access. The memory object cannot be swapped
        // mid-instruction (run() and the MMIO handlers all operate on this
        // same instance), so this changes nothing observable — faults,
        // trap vectors/tval, pc and cycle all behave exactly as before.
        let mem: NovaMemory = memory
        // Hardware timer check (for firmware scheduler).
        // MUST be before opcode fetch: when the timer fires, epc = pc must
        // point AT the interrupted instruction (not past it), otherwise MRET
        // resumes past a fetched-but-unexecuted opcode, corrupting the stack.
        // The firmware's trap handler (at the timer vector) is responsible for
        // context switching. This is hardware behavior, not app control.
        // Only fire if interrupts are enabled (bit 0 of status).
        if mem.timerInterval > 0 && (status & 1) != 0 {
            if mem.timerCount > 0 {
                mem.timerCount &-= 1
            }
            if mem.timerCount == 0 {
                // Timer fired. Reset for periodic mode.
                mem.timerCount = mem.timerInterval
                throw NovaTrap.timerInterrupt
            }
        }

        // Opcode fetch uses NovaMemory's fast path (read8 = one range
        // comparison + one byte load). It is deliberately NOT fused with
        // the operand fetches below into one wider checked read: in the
        // original code a faulting operand still leaves pc/cycle advanced
        // past the opcode byte, and trap observers can see that state —
        // fusing would change fault-visible pc/cycle. Each operand fetch
        // instead gets the same single-comparison fast path via
        // read16/read32/read64.
        let opcode = try mem.read8(pc)
        pc &+= 1
        cycle &+= 1

        switch opcode {
        // ---- Stack manipulation ----
        case 0x00: break // NOP
        case 0x01: // PUSH8
            let imm = Int64(Int8(bitPattern: try mem.read8(pc))); pc &+= 1
            try dpush(UInt64(bitPattern: imm))
        case 0x02: // PUSH16
            let imm = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            try dpush(UInt64(bitPattern: imm))
        case 0x03: // PUSH32
            let imm = Int64(Int32(bitPattern: try mem.read32(pc))); pc &+= 4
            try dpush(UInt64(bitPattern: imm))
        case 0x04: // PUSH64
            let imm = try mem.read64(pc); pc &+= 8
            try dpush(imm)
        case 0x05: // POP
            _ = try dpop()
        case 0x06: // POPN
            let n = try mem.read8(pc); pc &+= 1
            for _ in 0..<n { _ = try dpop() }
        case 0x07: // DUP
            let a = try dpop(); try dpush(a); try dpush(a)
        case 0x08: // DUP2
            let a = try dpop(); let b = try dpop()
            try dpush(b); try dpush(a); try dpush(b); try dpush(a)
        case 0x09: // SWAP
            let a = try dpop(); let b = try dpop()
            try dpush(a); try dpush(b)
        case 0x0A: // ROT: a b c → b c a (a=top)
            let a = try dpop(); let b = try dpop(); let c = try dpop()
            try dpush(b); try dpush(a); try dpush(c)
        case 0x0B: // ROTR: a b c → c a b
            let a = try dpop(); let b = try dpop(); let c = try dpop()
            try dpush(a); try dpush(c); try dpush(b)
        case 0x0C: // OVER: a b → a b a
            let a = try dpop(); let b = try dpop()
            try dpush(b); try dpush(a); try dpush(b)
        case 0x0D: // TUCK: a b → b a b
            let a = try dpop(); let b = try dpop()
            try dpush(a); try dpush(b); try dpush(a)
        case 0x0E: // PICK n
            let n = try mem.read8(pc); pc &+= 1
            let addr = dsp &+ UInt64(n) &* 8
            try dpush(try mem.read64(addr))
        case 0x0F: // ROLL n — rotate top n items (top goes to bottom of the n)
            let n = Int(try mem.read8(pc)); pc &+= 1
            if n > 1 {
                var tmp = [UInt64]()
                for _ in 0..<n { tmp.append(try dpop()) }
                // tmp[0] was top; move it to bottom: push tmp[0] first, then rest reversed
                let top = tmp[0]
                for i in (1..<n).reversed() { try dpush(tmp[i]) }
                try dpush(top)
            }
        case 0x10: // DEPTH
            let depth = (mem.dataStackBase &- dsp) / 8
            try dpush(depth)
        case 0x11: // DSPGET
            try dpush(dsp)
        case 0x12: // DSPSET (privileged: firmware use only)
            dsp = try dpop()
        case 0x13: // FPGET
            try dpush(fp)
        case 0x14: // ENTER n
            let n = try mem.read8(pc); pc &+= 1
            try cpush(fp)
            fp = dsp
            for _ in 0..<n { try dpush(0) }
        case 0x15: // LEAVE
            dsp = fp
            fp = try cpop()
        case 0x16: // LOADL n — local n lives at FP-8*(n+1)
            let n = try mem.read8(pc); pc &+= 1
            try dpush(try mem.read64(fp &- (UInt64(n) &+ 1) &* 8))
        case 0x17: // STORL n
            let n = try mem.read8(pc); pc &+= 1
            let v = try dpop()
            try mem.write64(fp &- (UInt64(n) &+ 1) &* 8, v)
        case 0x18: // LOADARG n — arg n above frame: FP+8*n (0 = last pushed)
            let n = try mem.read8(pc); pc &+= 1
            try dpush(try mem.read64(fp &+ UInt64(n) &* 8))
        case 0x19: // PUSHR n — push R[n]
            let n = try mem.read8(pc); pc &+= 1
            guard n < 16 else { tval = UInt64(n); throw NovaTrap.illegalInstruction }
            try dpush(regs[Int(n)])
        case 0x1A: // POPR n — pop into R[n]
            let n = try mem.read8(pc); pc &+= 1
            guard n < 16 else { tval = UInt64(n); throw NovaTrap.illegalInstruction }
            regs[Int(n)] = try dpop()
        case 0x1B: // PUSHALL — push R0..R15 (R0 first, R15 on top)
            for i in 0..<16 { try dpush(regs[i]) }
        case 0x1C: // POPALL — pop into R15..R0 (top of stack → R15)
            for i in (0..<16).reversed() { regs[i] = try dpop() }
        case 0x1D: // CSPGET — push call stack pointer
            try dpush(csp)
        case 0x1E: // CSPSET — pop into call stack pointer (privileged)
            csp = try dpop()

        // ---- Integer ALU ----
        case 0x40: // ADD
            let a = try dpop(); let b = try dpop()
            try dpush(b &+ a)
        case 0x41: // SUB
            let a = try dpop(); let b = try dpop()
            try dpush(b &- a)
        case 0x42: // MUL
            let a = try dpop(); let b = try dpop()
            try dpush(b &* a)
        case 0x43: // MULH (signed high)
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            let (hi, _) = b.multipliedFullWidth(by: a)
            try dpush(UInt64(bitPattern: hi))
        case 0x44: // DIV (signed)
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(UInt64(bitPattern: b / a))
        case 0x45: // DIVU
            let a = try dpop(); let b = try dpop()
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(b / a)
        case 0x46: // REM (signed)
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(UInt64(bitPattern: b % a))
        case 0x47: // REMU
            let a = try dpop(); let b = try dpop()
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(b % a)
        case 0x48: // AND
            let a = try dpop(); let b = try dpop()
            try dpush(b & a)
        case 0x49: // OR
            let a = try dpop(); let b = try dpop()
            try dpush(b | a)
        case 0x4A: // XOR
            let a = try dpop(); let b = try dpop()
            try dpush(b ^ a)
        case 0x4B: // NOT
            try dpush(~(try dpop()))
        case 0x4C: // NEG
            let a = try dpop()
            try dpush(0 &- a)
        case 0x4D: // SHL
            let a = try dpop(); let b = try dpop()
            try dpush(b &<< (a & 63))
        case 0x4E: // SHR (logical)
            let a = try dpop(); let b = try dpop()
            try dpush(b &>> (a & 63))
        case 0x4F: // SAR (arithmetic)
            let a = try dpop()
            let b = Int64(bitPattern: try dpop())
            try dpush(UInt64(bitPattern: b >> (a & 63)))
        case 0x50: // INC
            try dpush((try dpop()) &+ 1)
        case 0x51: // DEC
            try dpush((try dpop()) &- 1)
        case 0x52: // CMP
            let a = try dpop(); let b = try dpop()
            setFlagsSub(b, a)
        case 0x53: // TST
            let a = try dpop()
            setFlagsSub(a, 0)
            try dpush(a)
        case 0x54: // EQ
            let a = try dpop(); let b = try dpop()
            try dpush(b == a ? 1 : 0)
        case 0x55: // NE
            let a = try dpop(); let b = try dpop()
            try dpush(b != a ? 1 : 0)
        case 0x56: // LT (signed)
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            try dpush(b < a ? 1 : 0)
        case 0x57: // LTU
            let a = try dpop(); let b = try dpop()
            try dpush(b < a ? 1 : 0)
        case 0x5C: // POPCNT
            try dpush(UInt64((try dpop()).nonzeroBitCount))
        case 0x5D: // REV8
            try dpush((try dpop()).byteSwapped)
        case 0x5E: // EXT8 — sign-extend low 8 bits
            try dpush(UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(try dpop() & 0xFF)))))
        case 0x5F: // EXT16
            try dpush(UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(try dpop() & 0xFFFF)))))
        case 0x60: // EXT32
            try dpush(UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(try dpop() & 0xFFFFFFFF)))))

        // ---- Memory ----
        case 0x80: // LOAD8
            let addr = try dpop()
            try dpush(UInt64(bitPattern: Int64(Int8(bitPattern: try mem.read8(addr)))))
        case 0x83: // LOAD64
            let addr = try dpop()
            if addr >= 0xFFFF_FFFF_FFFF_0000 {
                try dpush(mem.mmioRead(addr))
            } else {
                try dpush(try mem.read64(addr))
            }
        case 0x84: // LOADU8
            let addr84 = try dpop()
            if addr84 >= 0xFFFF_FFFF_FFFF_0000 {
                try dpush(mem.mmioRead(addr84) & 0xFF)
            } else {
                try dpush(UInt64(try mem.read8(addr84)))
            }
        case 0x85: // LOADU16
            let addr85 = try dpop()
            try dpush(UInt64(try mem.read16(addr85)))
        case 0x86: // LOADU32
            let addr86 = try dpop()
            try dpush(UInt64(try mem.read32(addr86)))
        case 0x87: // STORE8
            let addr87 = try dpop(); let v87 = try dpop()
            if addr87 >= 0xFFFF_FFFF_FFFF_0000 {
                mem.mmioWrite(addr87, v87 & 0xFF)
            } else {
                try mem.write8(addr87, UInt8(v87 & 0xFF))
            }
        case 0x88: // STORE16
            let addr88 = try dpop(); let v88 = try dpop()
            try mem.write16(addr88, UInt16(v88 & 0xFFFF))
        case 0x89: // STORE32
            let addr89 = try dpop(); let v89 = try dpop()
            try mem.write32(addr89, UInt32(v89 & 0xFFFFFFFF))
        case 0x8A: // STORE64
            let addr = try dpop(); let v = try dpop()
            if addr >= 0xFFFF_FFFF_FFFF_0000 {
                mem.mmioWrite(addr, v)
            } else {
                try mem.write64(addr, v)
            }
        case 0x8F: // MEMCPY: n dst src →  (src top)
            let src = try dpop(); let dst = try dpop(); let n = try dpop()
            try mem.copyBytes(from: src, to: dst, count: n)

        // ---- Control flow ----
        case 0xA0: // JMP off16
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xA1: // JMP32
            let off = Int64(Int32(bitPattern: try mem.read32(pc))); pc &+= 4
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xA2: // BZ
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            if (try dpop()) == 0 { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA3: // BNZ
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            if (try dpop()) != 0 { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA6: // BEQ (uses Z flag)
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            if flagZ { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA7: // BNE
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            if !flagZ { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA8: // CALL off16
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            try cpush(pc)
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xA9: // CALL32 off32
            let off32 = Int64(Int32(bitPattern: try mem.read32(pc))); pc &+= 4
            try cpush(pc)
            pc = UInt64(Int64(bitPattern: pc) &+ off32)
        case 0xAB: // RET
            pc = try cpop()
        case 0xAC: // JMPI
            pc = try dpop()
        case 0xAA: // CALLI
            let addr = try dpop()
            try cpush(pc)
            pc = addr
        case 0xAD: // LOOP off16 — decrement top; if != 0 branch (keeps counter)
            let off = Int64(Int16(bitPattern: try mem.read16(pc))); pc &+= 2
            let n = try dpop() &- 1
            try dpush(n)
            if n != 0 { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xAE: // TRAP code
            let code = try mem.read8(pc); pc &+= 1
            tval = UInt64(code)
            throw NovaTrap.breakpoint // generic software trap

        // ---- System ----
        case 0xC0: // ECALL
            throw NovaTrap.ecallU
        case 0xC1: // EBREAK
            throw NovaTrap.breakpoint
        case 0xC2: // MRET — return from Machine trap
            // Restore PC from EPC, restore status (re-enables interrupts)
            pc = epc
            status = savedStatusForMret
        case 0xC6: // CSRGET — push CSR value (0=epc, 1=cause, 2=status)
            let cget = try mem.read8(pc); pc &+= 1
            switch cget {
            case 0: try dpush(epc)
            case 1: try dpush(cause)
            case 2: try dpush(status)
            default: throw NovaTrap.illegalInstruction
            }
        case 0xC7: // CSRSET — pop value into CSR (0=epc, 1=cause, 2=status)
            let cset = try mem.read8(pc); pc &+= 1
            let cv = try dpop()
            switch cset {
            case 0: epc = cv
            case 1: cause = cv
            case 2: status = cv
            default: throw NovaTrap.illegalInstruction
            }
        case 0xC5: // WFI — yield in VM
            running = false
        case 0xCB: // RDTIME
            try dpush(UInt64(Date().timeIntervalSince1970 * 1_000_000))
        case 0xCC: // RDCYCLE
            try dpush(cycle)

        // ---- Crypto ----
        case 0xF4: // RDRAND
            try dpush(UInt64.random(in: 0...UInt64.max))

        case 0xF5: // CPUID
            let leaf = try dpop()
            switch leaf {
            case 0: try dpush(0x4E564F41) // "NOVA" vendor
            case 1: try dpush(0x0200)     // version 2.0
            case 2: try dpush(0b0111)     // FP|SIMD|crypto
            case 3: try dpush(0x00312D61766F4E) // "Nova-1" model name (packed ASCII)
            default: try dpush(0)
            }

        default:
            tval = UInt64(opcode)
            throw NovaTrap.illegalInstruction
        }
    }

    // MARK: - Predecode block cache (variant machinery)

    /// One decoded instruction. `imm` holds the PUSH8/16/32 value already
    /// sign-extended exactly as step() computes it (or the raw PUSH64
    /// operand); `n` holds the 1-byte operand instructions; `target` is
    /// the branch/call destination precomputed as nextPC + offset with
    /// the same wrapping arithmetic step() uses. Only DECODE is cached —
    /// every operand that depends on live state (stack, memory, flags,
    /// cycle) is read at execute time in execDecoded.
    private struct DecodedInsn {
        var pc: UInt64 = 0
        var nextPC: UInt64 = 0
        var opcode: UInt8 = 0
        var imm: UInt64 = 0
        var n: UInt8 = 0
        var target: UInt64 = 0
    }

    private enum BlockFlow {
        case next   // continue with the next decoded instruction
        case exit   // pc is set (or running cleared): leave the block
        case flush  // cache was dropped during this instruction: leave the block
    }

    /// Per-run decode cache, keyed by block-head pc. Built lazily during
    /// run() and dropped when run() returns (rule (c): host-side loads
    /// between runs can therefore never go stale).
    private var blockCache: [UInt64: [DecodedInsn]] = [:]
    /// Bounding interval [cacheLo, cacheHi) covering every cached block's
    /// bytes; lets noteGuestWrite reject the common no-overlap store in
    /// O(1). Only ever widens while blocks are added; reset on clear.
    private var cacheLo: UInt64 = UInt64.max
    private var cacheHi: UInt64 = 0

    private func clearBlockCache() {
        blockCache.removeAll()
        cacheLo = UInt64.max
        cacheHi = 0
    }

    /// Invalidation rule (a): called after every successful guest RAM
    /// write executed from a decoded block (STORE8/16/32/64, STORL).
    /// If the written range intersects ANY cached block's byte range,
    /// the WHOLE cache is dropped and true is returned (the caller then
    /// abandons the current block too — the selfmod phase-1a case, where
    /// a store patches an instruction later in its own block). Whole-
    /// cache drop is deliberate: blocks are cheap to re-decode, stores
    /// into the code bounding region are rare (stack traffic lands in
    /// the stack regions, which are never cached — see fetchBlock), and
    /// a missed overlap is a correctness bug while a spare drop is only
    /// a re-decode.
    private func noteGuestWrite(_ addr: UInt64, _ len: UInt64) -> Bool {
        if blockCache.isEmpty { return false }
        // Fast reject against the bounding interval.
        if addr &+ len <= cacheLo || addr >= cacheHi { return false }
        let wLo = addr
        let wHi = addr &+ len
        for block in blockCache.values {
            guard let first = block.first, let last = block.last else { continue }
            if wLo < last.nextPC && first.pc < wHi {
                clearBlockCache()
                return true
            }
        }
        return false
    }

    /// True when [lo, hi) intersects an architectural stack region.
    /// Blocks are never cached over these ranges: dpush/cpush writes are
    /// not individually range-checked in the block executor, and this
    /// refusal is what licenses that — push targets are confined to
    /// these regions by the dpush/cpush limit checks (plus DSPSET/
    /// CSPSET flushing the cache, below), so a stack write can never
    /// intersect a cached block.
    private func inStackRegion(_ lo: UInt64, _ hi: UInt64) -> Bool {
        let mem: NovaMemory = memory
        if lo < mem.dataStackBase && dslim < hi { return true }
        if lo < mem.callStackBase && cslim < hi { return true }
        if lo < mem.vectorStackBase && vslim < hi { return true }
        return false
    }

    /// Decodes ONE instruction at `cur`. Returns nil for bail-list
    /// opcodes (the block ends before them; step() executes them with
    /// identical semantics). Throws when the instruction's bytes cannot
    /// be fully read — the block likewise ends before it, so step()
    /// reproduces the exact fault state (pc/cycle already advanced past
    /// the opcode byte, per the V1 note on unfused fetch).
    private func decodeOne(at cur: UInt64, mem: NovaMemory) throws -> (insn: DecodedInsn, terminal: Bool)? {
        var d = DecodedInsn()
        d.pc = cur
        let op = try mem.read8(cur)
        d.opcode = op
        switch op {
        case 0x00: // NOP
            d.nextPC = cur &+ 1
            return (d, false)
        case 0x01: // PUSH8
            let b = try mem.read8(cur &+ 1)
            d.imm = UInt64(bitPattern: Int64(Int8(bitPattern: b)))
            d.nextPC = cur &+ 2
            return (d, false)
        case 0x02: // PUSH16
            let v = try mem.read16(cur &+ 1)
            d.imm = UInt64(bitPattern: Int64(Int16(bitPattern: v)))
            d.nextPC = cur &+ 3
            return (d, false)
        case 0x03: // PUSH32
            let v = try mem.read32(cur &+ 1)
            d.imm = UInt64(bitPattern: Int64(Int32(bitPattern: v)))
            d.nextPC = cur &+ 5
            return (d, false)
        case 0x04: // PUSH64
            d.imm = try mem.read64(cur &+ 1)
            d.nextPC = cur &+ 9
            return (d, false)
        case 0x06, 0x0E, 0x0F, 0x14, 0x16, 0x17, 0x18, 0x19, 0x1A, 0xC6:
            // POPN, PICK, ROLL, ENTER, LOADL, STORL, LOADARG, PUSHR,
            // POPR, CSRGET — single 1-byte operand.
            d.n = try mem.read8(cur &+ 1)
            d.nextPC = cur &+ 2
            return (d, false)
        case 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
             0x10, 0x11, 0x12, 0x13, 0x15, 0x1B, 0x1C, 0x1D, 0x1E,
             0x40...0x57, 0x5C...0x60,
             0x80, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A,
             0xCC:
            // Zero-operand instructions step() implements: stack ops,
            // ALU + CMP/TST/compares + POPCNT/REV8/EXT*, LOAD/STORE,
            // RDCYCLE. (Opcodes step() does NOT implement — 0x58...0x5B,
            // 0x81/0x82, FP/SIMD/crypto, etc. — fall to default -> bail,
            // so step() produces their illegalInstruction trap exactly.)
            d.nextPC = cur &+ 1
            return (d, false)
        case 0xA0, 0xA2, 0xA3, 0xA6, 0xA7, 0xA8, 0xAD:
            // JMP, BZ, BNZ, BEQ, BNE, CALL, LOOP — signed off16.
            let off = Int64(Int16(bitPattern: try mem.read16(cur &+ 1)))
            d.nextPC = cur &+ 3
            d.target = UInt64(Int64(bitPattern: d.nextPC) &+ off)
            return (d, true)
        case 0xA1, 0xA9:
            // JMP32, CALL32 — signed off32.
            let off = Int64(Int32(bitPattern: try mem.read32(cur &+ 1)))
            d.nextPC = cur &+ 5
            d.target = UInt64(Int64(bitPattern: d.nextPC) &+ off)
            return (d, true)
        case 0xAB, 0xAC, 0xAA:
            // RET, JMPI, CALLI — destination comes from a stack at
            // execute time; the block simply ends here.
            d.nextPC = cur &+ 1
            return (d, true)
        case 0xC5: // WFI — clears `running`; block ends.
            d.nextPC = cur &+ 1
            return (d, true)
        default:
            // Bail list: ECALL, EBREAK, TRAP, MRET, CSRSET, RDTIME,
            // RDRAND, CPUID, MEMCPY, and every opcode step() treats as
            // illegal. step() executes all of them.
            return nil
        }
    }

    /// Returns the (possibly cached) decoded block starting at `head`,
    /// or nil when the first instruction cannot be block-executed
    /// (bail opcode, undecodable bytes, or stack-region code) — the
    /// caller then takes one step() and retries.
    private func fetchBlock(head: UInt64) -> [DecodedInsn]? {
        if let cached = blockCache[head] { return cached }
        let mem: NovaMemory = memory
        var insns: [DecodedInsn] = []
        var cur = head
        // Block cap: 64 instructions. Bounds decode cost per block and
        // the worst-case re-decode after an invalidation; blocks that
        // hit the cap simply continue as a fresh block at the next pc.
        while insns.count < 64 {
            let decoded: (insn: DecodedInsn, terminal: Bool)?
            do {
                decoded = try decodeOne(at: cur, mem: mem)
            } catch {
                break // undecodable bytes: block ends before this insn
            }
            guard let dec = decoded else { break } // bail opcode
            if inStackRegion(dec.insn.pc, dec.insn.nextPC) { break }
            insns.append(dec.insn)
            cur = dec.insn.nextPC
            if dec.terminal { break }
        }
        if insns.isEmpty { return nil }
        blockCache[head] = insns
        if head < cacheLo { cacheLo = head }
        let end = insns[insns.count - 1].nextPC
        if end > cacheHi { cacheHi = end }
        return insns
    }

    /// Executes one decoded instruction. Mirrors step() case-for-case
    /// for the decoded opcode set: `pc` is first set to the
    /// instruction's own pc (so a timer trap vectors with epc pointing
    /// AT the instruction, exactly as in step()), the timer check runs
    /// before anything else, `cycle` increments by exactly 1, then `pc`
    /// advances to nextPC before the body runs — so a faulting body
    /// leaves the same pc/cycle/tval step() would leave.
    private func execDecoded(_ d: DecodedInsn, mem: NovaMemory) throws -> BlockFlow {
        pc = d.pc
        // Hardware timer check — byte-for-byte the logic at the top of
        // step(): countdown per instruction, throw before fetch when it
        // reaches 0, pc still AT the interrupted instruction.
        if mem.timerInterval > 0 && (status & 1) != 0 {
            if mem.timerCount > 0 {
                mem.timerCount &-= 1
            }
            if mem.timerCount == 0 {
                mem.timerCount = mem.timerInterval
                throw NovaTrap.timerInterrupt
            }
        }
        cycle &+= 1
        pc = d.nextPC

        switch d.opcode {
        // ---- Stack manipulation ----
        case 0x00: // NOP
            return .next
        case 0x01, 0x02, 0x03, 0x04: // PUSH8/16/32/64 (imm pre-decoded)
            try dpush(d.imm)
            return .next
        case 0x05: // POP
            _ = try dpop()
            return .next
        case 0x06: // POPN
            for _ in 0..<d.n { _ = try dpop() }
            return .next
        case 0x07: // DUP
            let a = try dpop(); try dpush(a); try dpush(a)
            return .next
        case 0x08: // DUP2
            let a = try dpop(); let b = try dpop()
            try dpush(b); try dpush(a); try dpush(b); try dpush(a)
            return .next
        case 0x09: // SWAP
            let a = try dpop(); let b = try dpop()
            try dpush(a); try dpush(b)
            return .next
        case 0x0A: // ROT
            let a = try dpop(); let b = try dpop(); let c = try dpop()
            try dpush(b); try dpush(a); try dpush(c)
            return .next
        case 0x0B: // ROTR
            let a = try dpop(); let b = try dpop(); let c = try dpop()
            try dpush(a); try dpush(c); try dpush(b)
            return .next
        case 0x0C: // OVER
            let a = try dpop(); let b = try dpop()
            try dpush(b); try dpush(a); try dpush(b)
            return .next
        case 0x0D: // TUCK
            let a = try dpop(); let b = try dpop()
            try dpush(a); try dpush(b); try dpush(a)
            return .next
        case 0x0E: // PICK n
            let addr = dsp &+ UInt64(d.n) &* 8
            try dpush(try mem.read64(addr))
            return .next
        case 0x0F: // ROLL n
            let n = Int(d.n)
            if n > 1 {
                var tmp = [UInt64]()
                for _ in 0..<n { tmp.append(try dpop()) }
                let top = tmp[0]
                for i in (1..<n).reversed() { try dpush(tmp[i]) }
                try dpush(top)
            }
            return .next
        case 0x10: // DEPTH
            let depth = (mem.dataStackBase &- dsp) / 8
            try dpush(depth)
            return .next
        case 0x11: // DSPGET
            try dpush(dsp)
            return .next
        case 0x12: // DSPSET (privileged) — stack pointer is being
            // teleported; later pushes could land anywhere, so the
            // stack-region argument no longer covers them. Flush.
            dsp = try dpop()
            clearBlockCache()
            return .flush
        case 0x13: // FPGET
            try dpush(fp)
            return .next
        case 0x14: // ENTER n
            try cpush(fp)
            fp = dsp
            for _ in 0..<d.n { try dpush(0) }
            return .next
        case 0x15: // LEAVE
            dsp = fp
            fp = try cpop()
            return .next
        case 0x16: // LOADL n
            try dpush(try mem.read64(fp &- (UInt64(d.n) &+ 1) &* 8))
            return .next
        case 0x17: // STORL n
            let v = try dpop()
            let laddr = fp &- (UInt64(d.n) &+ 1) &* 8
            try mem.write64(laddr, v)
            if noteGuestWrite(laddr, 8) { return .flush }
            return .next
        case 0x18: // LOADARG n
            try dpush(try mem.read64(fp &+ UInt64(d.n) &* 8))
            return .next
        case 0x19: // PUSHR n
            guard d.n < 16 else { tval = UInt64(d.n); throw NovaTrap.illegalInstruction }
            try dpush(regs[Int(d.n)])
            return .next
        case 0x1A: // POPR n
            guard d.n < 16 else { tval = UInt64(d.n); throw NovaTrap.illegalInstruction }
            regs[Int(d.n)] = try dpop()
            return .next
        case 0x1B: // PUSHALL
            for i in 0..<16 { try dpush(regs[i]) }
            return .next
        case 0x1C: // POPALL
            for i in (0..<16).reversed() { regs[i] = try dpop() }
            return .next
        case 0x1D: // CSPGET
            try dpush(csp)
            return .next
        case 0x1E: // CSPSET (privileged) — see DSPSET.
            csp = try dpop()
            clearBlockCache()
            return .flush

        // ---- Integer ALU (bodies identical to step()) ----
        case 0x40: // ADD
            let a = try dpop(); let b = try dpop()
            try dpush(b &+ a)
            return .next
        case 0x41: // SUB
            let a = try dpop(); let b = try dpop()
            try dpush(b &- a)
            return .next
        case 0x42: // MUL
            let a = try dpop(); let b = try dpop()
            try dpush(b &* a)
            return .next
        case 0x43: // MULH
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            let (hi, _) = b.multipliedFullWidth(by: a)
            try dpush(UInt64(bitPattern: hi))
            return .next
        case 0x44: // DIV
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(UInt64(bitPattern: b / a))
            return .next
        case 0x45: // DIVU
            let a = try dpop(); let b = try dpop()
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(b / a)
            return .next
        case 0x46: // REM
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(UInt64(bitPattern: b % a))
            return .next
        case 0x47: // REMU
            let a = try dpop(); let b = try dpop()
            guard a != 0 else { throw NovaTrap.illegalInstruction }
            try dpush(b % a)
            return .next
        case 0x48: // AND
            let a = try dpop(); let b = try dpop()
            try dpush(b & a)
            return .next
        case 0x49: // OR
            let a = try dpop(); let b = try dpop()
            try dpush(b | a)
            return .next
        case 0x4A: // XOR
            let a = try dpop(); let b = try dpop()
            try dpush(b ^ a)
            return .next
        case 0x4B: // NOT
            try dpush(~(try dpop()))
            return .next
        case 0x4C: // NEG
            let a = try dpop()
            try dpush(0 &- a)
            return .next
        case 0x4D: // SHL
            let a = try dpop(); let b = try dpop()
            try dpush(b &<< (a & 63))
            return .next
        case 0x4E: // SHR
            let a = try dpop(); let b = try dpop()
            try dpush(b &>> (a & 63))
            return .next
        case 0x4F: // SAR
            let a = try dpop()
            let b = Int64(bitPattern: try dpop())
            try dpush(UInt64(bitPattern: b >> (a & 63)))
            return .next
        case 0x50: // INC
            try dpush((try dpop()) &+ 1)
            return .next
        case 0x51: // DEC
            try dpush((try dpop()) &- 1)
            return .next
        case 0x52: // CMP
            let a = try dpop(); let b = try dpop()
            setFlagsSub(b, a)
            return .next
        case 0x53: // TST
            let a = try dpop()
            setFlagsSub(a, 0)
            try dpush(a)
            return .next
        case 0x54: // EQ
            let a = try dpop(); let b = try dpop()
            try dpush(b == a ? 1 : 0)
            return .next
        case 0x55: // NE
            let a = try dpop(); let b = try dpop()
            try dpush(b != a ? 1 : 0)
            return .next
        case 0x56: // LT
            let a = Int64(bitPattern: try dpop())
            let b = Int64(bitPattern: try dpop())
            try dpush(b < a ? 1 : 0)
            return .next
        case 0x57: // LTU
            let a = try dpop(); let b = try dpop()
            try dpush(b < a ? 1 : 0)
            return .next
        case 0x5C: // POPCNT
            try dpush(UInt64((try dpop()).nonzeroBitCount))
            return .next
        case 0x5D: // REV8
            try dpush((try dpop()).byteSwapped)
            return .next
        case 0x5E: // EXT8
            try dpush(UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(try dpop() & 0xFF)))))
            return .next
        case 0x5F: // EXT16
            try dpush(UInt64(bitPattern: Int64(Int16(bitPattern: UInt16(try dpop() & 0xFFFF)))))
            return .next
        case 0x60: // EXT32
            try dpush(UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(try dpop() & 0xFFFFFFFF)))))
            return .next

        // ---- Memory ----
        case 0x80: // LOAD8
            let addr = try dpop()
            try dpush(UInt64(bitPattern: Int64(Int8(bitPattern: try mem.read8(addr)))))
            return .next
        case 0x83: // LOAD64
            let addr = try dpop()
            if addr >= 0xFFFF_FFFF_FFFF_0000 {
                try dpush(mem.mmioRead(addr))
            } else {
                try dpush(try mem.read64(addr))
            }
            return .next
        case 0x84: // LOADU8
            let addr84 = try dpop()
            if addr84 >= 0xFFFF_FFFF_FFFF_0000 {
                try dpush(mem.mmioRead(addr84) & 0xFF)
            } else {
                try dpush(UInt64(try mem.read8(addr84)))
            }
            return .next
        case 0x85: // LOADU16
            let addr85 = try dpop()
            try dpush(UInt64(try mem.read16(addr85)))
            return .next
        case 0x86: // LOADU32
            let addr86 = try dpop()
            try dpush(UInt64(try mem.read32(addr86)))
            return .next
        case 0x87: // STORE8
            let addr87 = try dpop(); let v87 = try dpop()
            if addr87 >= 0xFFFF_FFFF_FFFF_0000 {
                // MMIO write: host handlers (file/net) run synchronously
                // inside mmioWrite and can write guest RAM. Flush.
                mem.mmioWrite(addr87, v87 & 0xFF)
                clearBlockCache()
                return .flush
            }
            try mem.write8(addr87, UInt8(v87 & 0xFF))
            if noteGuestWrite(addr87, 1) { return .flush }
            return .next
        case 0x88: // STORE16
            let addr88 = try dpop(); let v88 = try dpop()
            try mem.write16(addr88, UInt16(v88 & 0xFFFF))
            if noteGuestWrite(addr88, 2) { return .flush }
            return .next
        case 0x89: // STORE32
            let addr89 = try dpop(); let v89 = try dpop()
            try mem.write32(addr89, UInt32(v89 & 0xFFFFFFFF))
            if noteGuestWrite(addr89, 4) { return .flush }
            return .next
        case 0x8A: // STORE64
            let addr = try dpop(); let v = try dpop()
            if addr >= 0xFFFF_FFFF_FFFF_0000 {
                mem.mmioWrite(addr, v)
                clearBlockCache()
                return .flush
            }
            try mem.write64(addr, v)
            if noteGuestWrite(addr, 8) { return .flush }
            return .next

        // ---- Control flow (all terminal: pc set, block left) ----
        case 0xA0, 0xA1: // JMP / JMP32
            pc = d.target
            return .exit
        case 0xA2: // BZ
            if (try dpop()) == 0 { pc = d.target }
            return .exit
        case 0xA3: // BNZ
            if (try dpop()) != 0 { pc = d.target }
            return .exit
        case 0xA6: // BEQ
            if flagZ { pc = d.target }
            return .exit
        case 0xA7: // BNE
            if !flagZ { pc = d.target }
            return .exit
        case 0xA8, 0xA9: // CALL / CALL32 (pc == nextPC == return addr)
            try cpush(pc)
            pc = d.target
            return .exit
        case 0xAB: // RET
            pc = try cpop()
            return .exit
        case 0xAC: // JMPI
            pc = try dpop()
            return .exit
        case 0xAA: // CALLI
            let addr = try dpop()
            try cpush(pc)
            pc = addr
            return .exit
        case 0xAD: // LOOP
            let n = try dpop() &- 1
            try dpush(n)
            if n != 0 { pc = d.target }
            return .exit

        // ---- System (decoded subset) ----
        case 0xC5: // WFI
            running = false
            return .exit
        case 0xC6: // CSRGET
            switch d.n {
            case 0: try dpush(epc)
            case 1: try dpush(cause)
            case 2: try dpush(status)
            default: throw NovaTrap.illegalInstruction
            }
            return .next
        case 0xCC: // RDCYCLE (cycle already counts this instruction,
            // exactly as in step(), where the fetch increment precedes
            // the case body)
            try dpush(cycle)
            return .next

        default:
            // Unreachable: decodeOne bails on every opcode not handled
            // above. If a future edit breaks that invariant, fail
            // exactly as step() would for an unknown opcode rather
            // than executing something wrong.
            tval = UInt64(d.opcode)
            throw NovaTrap.illegalInstruction
        }
    }

    // MARK: - Run loop

    /// Trap handling identical to the original V1 run(): vector
    /// timer/ECALL to the firmware handler when a vector is installed,
    /// otherwise report to trapHandler and halt if there is none.
    /// The block cache is dropped on EVERY trap (rule (b)): vectored
    /// traps resume inside firmware that may self-modify, unvectored
    /// traps run host handlers that may write guest RAM, and the
    /// file READ handler in particular stores host bytes into guest
    /// memory while the CPU is out of the interpreter.
    private func handleTrap(_ trap: NovaTrap) {
        if (trap == .timerInterrupt || trap == .ecallU) && memory.timerVector != 0 {
            epc = pc
            cause = (trap == .ecallU) ? 8 : 0x8000000000000007
            try? dpush(epc)
            try? dpush(cause)
            let savedStatus = status
            status &= ~UInt64(1)  // Disable interrupts
            savedStatusForMret = savedStatus
            pc = memory.timerVector
        } else {
            trapHandler?(trap, tval)
            if trapHandler == nil { running = false }
        }
        clearBlockCache()
    }

    func run(maxSteps: UInt64 = .max) {
        running = true
        clearBlockCache()
        var steps: UInt64 = 0
        while running && steps < maxSteps {
            if let block = fetchBlock(head: pc) {
                let mem: NovaMemory = memory
                var idx = 0
                var leaveBlock = false
                // The step budget is charged PER INSTRUCTION, exactly
                // as the V1 loop charges one step per step() call — the
                // budget-prefix goldens (bouncer/counter) depend on
                // halting mid-block at precisely maxSteps instructions.
                while running && !leaveBlock && steps < maxSteps && idx < block.count {
                    do {
                        let flow = try execDecoded(block[idx], mem: mem)
                        steps &+= 1
                        switch flow {
                        case .next:
                            idx += 1
                        case .exit, .flush:
                            leaveBlock = true
                        }
                        if idx >= block.count { leaveBlock = true }
                    } catch let trap as NovaTrap {
                        steps &+= 1
                        handleTrap(trap)
                        leaveBlock = true
                    } catch {
                        // Non-NovaTrap error (step() never throws one,
                        // but the V1 loop charges the step regardless).
                        steps &+= 1
                        running = false
                        leaveBlock = true
                    }
                }
            } else {
                // Fallback: one ordinary step() (bail instruction,
                // undecodable bytes, or stack-region code).
                do {
                    try step()
                } catch let trap as NovaTrap {
                    handleTrap(trap)
                } catch {
                    running = false
                }
                steps &+= 1
                // step() executed an instruction the block path could
                // not range-check — possibly a store to code, MEMCPY,
                // or an MMIO command whose host handler wrote guest
                // RAM. It is the rare path by design; pay for certainty
                // and drop the whole cache.
                clearBlockCache()
            }
        }
        // Per-run cache: nothing decoded survives run(), so host-side
        // loads (loadBytes / storeHostBytes between runs) are safe.
        clearBlockCache()
    }
}
