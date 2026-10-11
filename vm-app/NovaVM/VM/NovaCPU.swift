// NovaCPU.swift — NOVA stack-machine CPU emulator
// Optimized for Apple Silicon (M3+) withContiguousArray storage,
// inlinable hot paths, and minimal ARC traffic in the fetch loop.

import Foundation

// MARK: - Trap Causes
enum NovaTrap: UInt64 {
    case instrAddrMisaligned = 0
    case instrAccessFault    = 1
    case illegalInstruction  = 2
    case breakpoint          = 3
    case loadAddrMisaligned  = 4
    case loadAccessFault     = 5
    case storeAddrMisaligned = 6
    case storeAccessFault    = 7
    case ecallU              = 8
    case ecallS              = 9
    case ecallH              = 10
    case ecallM              = 11
    case instrPageFault      = 12
    case loadPageFault       = 13
    case storePageFault      = 14
    case stackOverflow       = 15
    case stackUnderflow      = 16
}

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
        memory.write64(nsp, v)
        dsp = nsp
    }

    @inline(__always) func dpop() throws -> UInt64 {
        // Underflow check: DSP must be below stack base.
        // Stack base tracked by memory object.
        if dsp >= memory.dataStackBase { throw NovaTrap.stackUnderflow }
        let v = memory.read64(dsp)
        dsp = dsp &+ 8
        return v
    }

    @inline(__always) func cpush(_ v: UInt64) throws {
        let nsp = csp &- 8
        if nsp < cslim { throw NovaTrap.stackOverflow }
        memory.write64(nsp, v)
        csp = nsp
    }

    @inline(__always) func cpop() throws -> UInt64 {
        if csp >= memory.callStackBase { throw NovaTrap.stackUnderflow }
        let v = memory.read64(csp)
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
        let opcode = memory.read8(pc)
        pc &+= 1
        cycle &+= 1

        switch opcode {
        // ---- Stack manipulation ----
        case 0x00: break // NOP
        case 0x01: // PUSH8
            let imm = Int64(Int8(bitPattern: memory.read8(pc))); pc &+= 1
            try dpush(UInt64(bitPattern: imm))
        case 0x02: // PUSH16
            let imm = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            try dpush(UInt64(bitPattern: imm))
        case 0x03: // PUSH32
            let imm = Int64(Int32(bitPattern: memory.read32(pc))); pc &+= 4
            try dpush(UInt64(bitPattern: imm))
        case 0x04: // PUSH64
            let imm = memory.read64(pc); pc &+= 8
            try dpush(imm)
        case 0x05: // POP
            _ = try dpop()
        case 0x06: // POPN
            let n = memory.read8(pc); pc &+= 1
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
            let n = memory.read8(pc); pc &+= 1
            let addr = dsp &+ UInt64(n) &* 8
            try dpush(memory.read64(addr))
        case 0x10: // DEPTH
            let depth = (memory.dataStackBase &- dsp) / 8
            try dpush(depth)
        case 0x14: // ENTER n
            let n = memory.read8(pc); pc &+= 1
            try cpush(fp)
            fp = dsp
            for _ in 0..<n { try dpush(0) }
        case 0x15: // LEAVE
            dsp = fp
            fp = try cpop()
        case 0x16: // LOADL n
            let n = memory.read8(pc); pc &+= 1
            try dpush(memory.read64(fp &- UInt64(n) &* 8))
        case 0x17: // STORL n
            let n = memory.read8(pc); pc &+= 1
            let v = try dpop()
            memory.write64(fp &- UInt64(n) &* 8, v)

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

        // ---- Memory ----
        case 0x80: // LOAD8
            let addr = try dpop()
            try dpush(UInt64(bitPattern: Int64(Int8(bitPattern: memory.read8(addr)))))
        case 0x83: // LOAD64
            let addr = try dpop()
            try dpush(memory.read64(addr))
        case 0x84: // LOADU8
            try dpush(UInt64(memory.read8(try dpop())))
        case 0x8A: // STORE64
            let addr = try dpop(); let v = try dpop()
            memory.write64(addr, v)
        case 0x8F: // MEMCPY: n dst src →  (src top)
            let src = try dpop(); let dst = try dpop(); let n = try dpop()
            memory.copyBytes(from: src, to: dst, count: n)

        // ---- Control flow ----
        case 0xA0: // JMP off16
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xA1: // JMP32
            let off = Int64(Int32(bitPattern: memory.read32(pc))); pc &+= 4
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xA2: // BZ
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            if (try dpop()) == 0 { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA3: // BNZ
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            if (try dpop()) != 0 { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA6: // BEQ (uses Z flag)
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            if flagZ { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA7: // BNE
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            if !flagZ { pc = UInt64(Int64(bitPattern: pc) &+ off) }
        case 0xA8: // CALL off16
            let off = Int64(Int16(bitPattern: memory.read16(pc))); pc &+= 2
            try cpush(pc)
            pc = UInt64(Int64(bitPattern: pc) &+ off)
        case 0xAB: // RET
            pc = try cpop()
        case 0xAC: // JMPI
            pc = try dpop()
        case 0xAA: // CALLI
            let addr = try dpop()
            try cpush(pc)
            pc = addr

        // ---- System ----
        case 0xC0: // ECALL
            throw NovaTrap.ecallU
        case 0xC1: // EBREAK
            throw NovaTrap.breakpoint
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
            case 0: try dpush(0x4E564F41) // "NOVA"
            case 1: try dpush(0x0200)     // version 2.0
            case 2: try dpush(0b0111)     // FP|SIMD|crypto
            default: try dpush(0)
            }

        default:
            tval = UInt64(opcode)
            throw NovaTrap.illegalInstruction
        }
    }

    // MARK: - Run loop

    func run(maxSteps: UInt64 = .max) {
        running = true
        var steps: UInt64 = 0
        while running && steps < maxSteps {
            do {
                try step()
            } catch let trap as NovaTrap {
                trapHandler?(trap, tval)
                // Default: halt on unhandled trap
                if trapHandler == nil { running = false }
            } catch {
                running = false
            }
            steps &+= 1
        }
    }
}
