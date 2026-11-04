// NovaJIT.swift — NOVA v0.0.71 Phase 2 JIT engine (harness variant "jit").
//
// Lane J1 built the scaffolding below; lane J2 added the first real
// codegen (AArch64 emitter + block compiler for the stack and
// integer-ALU groups + the full §5 exactness trampoline — see the
// JitBlockCompiler / runTrampoline sections and agent_notes/
// v071-j2.md). Everything outside those two groups still ends a
// block before the instruction and is single-stepped via step().
// This file contains:
//   * the engine-indicator types the design names (agent_notes/
//     v071-jit-design.md §2.3): NovaEnginePreference, NovaActiveEngine,
//     JitStats, JitAvailability / JitAllocPath / JitUnavailableReason;
//   * the executable-memory allocator (JitCodeMemory) implementing the
//     design's allocation paths with W^X discipline (§1 spike, §2.2);
//   * the runtime probe (NovaJIT.probe()): at engine start it allocates
//     one page via the first workable path, writes the spike's
//     2-instruction `const42` smoke test, flips it executable by that
//     path's discipline, CALLS it, and only trusts the path if it
//     returns 42. The result is recorded in NovaJIT.lastProbe;
//   * the JitState shared state block (§5.1, fixed layout below) and
//     its sync-in/sync-out bridges to NovaCPU's object state;
//   * the Swift trampoline interface later lanes drive
//     (NovaJIT.runTrampoline). In J1 it compiled zero blocks and
//     declined every run; J2's trampoline (below) drives runs for
//     real, with guest-visible behaviour bit-identical to the
//     shipped hotloop interpreter by the §5 exactness design.
// The interpreter files are not modified by this file; the only CPU
// additions live in this variant's NovaCPU.swift and are enumerated
// in its banner.
//
// Allocation path order (§2.2, settled for macOS by the §1 spike):
//   macOS: W^X mprotect -> MAP_JIT -> plain RWX (last resort; the
//          spike showed plain RWX refused outright, errno 13).
//   iOS:   MAP_JIT -> W^X mprotect -> plain RWX (the design's default
//          until D1 is device-tested; the order is data, not code
//          shape — see NovaJIT.preferenceOrder).

import Foundation
#if canImport(Darwin)
import Darwin
#endif

@_silgen_name("sys_icache_invalidate")
private func novaJitSysICacheInvalidate(_ start: UnsafeMutableRawPointer, _ len: Int)

/// The probe's smoke-test function shape: `mov w0, #42; ret`.
private typealias JitFnConst = @convention(c) () -> Int32

/// Shape of a compiled block's entry point (design §5.1): generated
/// code receives the JitState pointer and returns a JitExitReason
/// raw value. Generated code honours this exact signature.
typealias JitBlockFunction = @convention(c) (UnsafeMutableRawPointer) -> UInt64

// MARK: - Engine indicator surface (design §2.3)

/// What the host asked for. Setting `.jit` never guarantees JIT runs;
/// `NovaCPU.activeEngine` reports what a run actually used.
enum NovaEnginePreference {
    case interpreter
    case jit
}

/// What a run actually used. `.jit` is only ever reported for a run
/// the JIT trampoline really drove.
enum NovaActiveEngine {
    case interpreterHotloop
    case jit(path: JitAllocPath)

    var label: String {
        switch self {
        case .interpreterHotloop: return "interpreterHotloop"
        case .jit(let path): return "jit(path: \(path.label))"
        }
    }
}

/// JIT counters for a diagnostics surface (design §2.3). In J1 all
/// were zero (no codegen). J2 populates them for real:
/// `nativeInstructions` counts guest instructions whose bodies ran
/// in generated code (the sum of block deltas), `singleSteps` counts
/// instructions the trampoline executed through `step()` on the
/// JIT's behalf (foreign/bail instructions, 0-instruction heads, the
/// signed DIV/REM overflow bail), `invalidations` counts whole-cache
/// drops (rules J4/J5/J7 plus the STORL J1 exit), `faultExits` /
/// `limitExits` count block returns of those reasons.
struct JitStats {
    var blocksCompiled: UInt64 = 0
    var blockEntries: UInt64 = 0
    var invalidations: UInt64 = 0
    var singleSteps: UInt64 = 0
    var faultExits: UInt64 = 0
    var limitExits: UInt64 = 0
    var nativeInstructions: UInt64 = 0
}

// MARK: - Availability probe types (design §2.2)

/// An executable-memory allocation path that executed the smoke test.
enum JitAllocPath {
    /// mmap RW, write, mprotect to RX to execute (never RWX).
    case wxTransition
    /// mmap with MAP_JIT; pthread_jit_write_protect_np toggles
    /// write (0) vs execute (1) mode.
    case mapJit
    /// mmap RWX, write and execute in place. Last resort only.
    case plainRWX

    var label: String {
        switch self {
        case .wxTransition: return "wxTransition"
        case .mapJit: return "mapJit"
        case .plainRWX: return "plainRWX"
        }
    }
}

enum JitUnavailableReason {
    /// Every path's mmap failed; carries the last errno seen.
    case allocationFailed(errno: Int32)
    /// A path allocated but the smoke test did not return 42.
    case smokeTestFailed
    /// Non-arm64 build: the JIT is AArch64-only (design §2.1).
    case unsupportedArchitecture
    /// Sentinel for "probe() has not run yet in this process".
    /// probe() itself never returns this; it exists only so
    /// NovaJIT.lastProbe has an honest value before the first probe
    /// (the design names lastProbe as a non-optional JitAvailability,
    /// which otherwise has no pre-probe value — see J1 note).
    case notProbedYet

    var label: String {
        switch self {
        case .allocationFailed(let e): return "allocationFailed(errno: \(e))"
        case .smokeTestFailed: return "smokeTestFailed"
        case .unsupportedArchitecture: return "unsupportedArchitecture"
        case .notProbedYet: return "notProbedYet"
        }
    }
}

enum JitAvailability {
    case available(path: JitAllocPath)
    case unavailable(reason: JitUnavailableReason)

    var label: String {
        switch self {
        case .available(let path): return "available(path: \(path.label))"
        case .unavailable(let reason): return "unavailable(reason: \(reason.label))"
        }
    }
}

// MARK: - Exit reasons (design §5.2)

/// Why generated code returned to the trampoline. Raw values are the
/// generated-code return contract for J2+; J1 only defines them.
enum JitExitReason: UInt64 {
    case next = 0        // block finished; dispatch at state.nextPc
    case fault = 1       // trap; exitAux = NovaTrap rawValue
    case wfi = 2         // WFI executed; run ends
    case singleStep = 3  // bail BEFORE the instruction at state.pc
    case invalidated = 4 // J1 store overlapped cached code; cache dropped
    case timerLimit = 5  // §5.3 limit register stopped the block (timer)
    case budgetLimit = 6 // §5.3 limit register stopped the block (budget)
}

// MARK: - Compiled block record (design §3)

/// Cache entry metadata. The cache itself is per-run (rule J6) and
/// lives in the trampoline from J2 on; J1 defines the record shape.
struct CompiledBlock {
    var guestPC: UInt64 = 0
    var byteLength: Int = 0
    var instructionCount: Int = 0
    var poolOffset: Int = 0
    /// J2: true when compilation stopped at the 64-instruction cap
    /// (the trampoline re-dispatches at endPc, no single-step); false
    /// when the block ends BEFORE a foreign/bail instruction or an
    /// instruction the compiler must not touch (decode fault, stack
    /// region overlap) — the trampoline single-steps that instruction
    /// through step() next.
    var endIsCap: Bool = false
    /// Guest pc the block's .next exit leaves in state.pc (== the
    /// first instruction NOT executed by the block).
    var endPc: UInt64 = 0
}

// MARK: - JitState (design §5.1 — fixed layout, all UInt64 slots)
//
//  off  field            off  field            off  field
//    0  ramBase          104  tval             216  r11
//    8  ramSize          112  savedStatus      224  r12
//   16  maxStart16       120  flags            232  r13
//   24  maxStart32       128  r0               240  r14
//   32  maxStart64       136  r1               248  r15
//   40  cycle            144  r2               256  nextPc
//   48  pc               152  r3               264  lastDelta
//   56  dsp              160  r4               272  exitAux
//   64  csp              168  r5               280  codeLo
//   72  fp               176  r6               288  codeHi
//   80  status           184  r7               296  entryStatus
//   88  epc              192  r8
//   96  cause            200  r9               total: 304 bytes
//                        208  r10
//
// flags packing (J1 choice, the design says only "N/Z/C/V packed
// bits"): bit 3 = N, bit 2 = Z, bit 1 = C, bit 0 = V.
struct JitState {
    var ramBase: UInt64 = 0
    var ramSize: UInt64 = 0
    var maxStart16: UInt64 = 0
    var maxStart32: UInt64 = 0
    var maxStart64: UInt64 = 0
    var cycle: UInt64 = 0
    var pc: UInt64 = 0
    var dsp: UInt64 = 0
    var csp: UInt64 = 0
    var fp: UInt64 = 0
    var status: UInt64 = 0
    var epc: UInt64 = 0
    var cause: UInt64 = 0
    var tval: UInt64 = 0
    var savedStatus: UInt64 = 0
    var flags: UInt64 = 0
    var r0: UInt64 = 0
    var r1: UInt64 = 0
    var r2: UInt64 = 0
    var r3: UInt64 = 0
    var r4: UInt64 = 0
    var r5: UInt64 = 0
    var r6: UInt64 = 0
    var r7: UInt64 = 0
    var r8: UInt64 = 0
    var r9: UInt64 = 0
    var r10: UInt64 = 0
    var r11: UInt64 = 0
    var r12: UInt64 = 0
    var r13: UInt64 = 0
    var r14: UInt64 = 0
    var r15: UInt64 = 0
    var nextPc: UInt64 = 0
    var lastDelta: UInt64 = 0
    var exitAux: UInt64 = 0
    var codeLo: UInt64 = 0
    var codeHi: UInt64 = 0
    var entryStatus: UInt64 = 0
    // J2 appended slots (offsets 304…344). The design's layout above
    // (offsets 0…296) is UNCHANGED; these carry the per-dispatch
    // values generated code needs that §5.1 did not slot: the unified
    // limit for this entry, the stack limits/bases the push/pop
    // checks compare against (they are memory-layout constants for
    // the whole run), and the exit reason a limit exit must return
    // (budget vs timer is a per-dispatch decision, so it cannot be
    // baked into a cached block).
    var jitLimit: UInt64 = 0        // 304
    var dslim: UInt64 = 0           // 312
    var cslim: UInt64 = 0           // 320
    var dataStackBase: UInt64 = 0   // 328
    var callStackBase: UInt64 = 0   // 336
    var limitReason: UInt64 = 0     // 344

    static let flagN: UInt64 = 1 << 3
    static let flagZ: UInt64 = 1 << 2
    static let flagC: UInt64 = 1 << 1
    static let flagV: UInt64 = 1 << 0

    /// Copy the CPU's object state in (trampoline entry). ramBase is
    /// NOT set here: it is the guest-RAM buffer pointer, valid only
    /// inside NovaMemory.withHotBuffer, so the trampoline (J2+) fills
    /// it for the duration of the run. maxStart* are recomputed from
    /// the RAM size with NovaMemory's own arithmetic (size - 2/4/8;
    /// the size is clamped >= 64 MB, so these cannot underflow).
    mutating func syncIn(from cpu: NovaCPU) {
        let size = UInt64(cpu.memory.totalSize)
        ramSize = size
        maxStart16 = size - 2
        maxStart32 = size - 4
        maxStart64 = size - 8
        cycle = cpu.cycle
        pc = cpu.pc
        dsp = cpu.dsp
        csp = cpu.csp
        fp = cpu.fp
        status = cpu.status
        epc = cpu.epc
        cause = cpu.cause
        tval = cpu.tval
        savedStatus = cpu.savedStatusForMret
        var f: UInt64 = 0
        if cpu.flagN { f |= Self.flagN }
        if cpu.flagZ { f |= Self.flagZ }
        if cpu.flagC { f |= Self.flagC }
        if cpu.flagV { f |= Self.flagV }
        flags = f
        r0 = cpu.regs[0]; r1 = cpu.regs[1]; r2 = cpu.regs[2]; r3 = cpu.regs[3]
        r4 = cpu.regs[4]; r5 = cpu.regs[5]; r6 = cpu.regs[6]; r7 = cpu.regs[7]
        r8 = cpu.regs[8]; r9 = cpu.regs[9]; r10 = cpu.regs[10]; r11 = cpu.regs[11]
        r12 = cpu.regs[12]; r13 = cpu.regs[13]; r14 = cpu.regs[14]; r15 = cpu.regs[15]
        entryStatus = cpu.status
        // J2 appended slots: run-constant stack limits/bases.
        dslim = cpu.dslim
        cslim = cpu.cslim
        dataStackBase = cpu.memory.dataStackBase
        callStackBase = cpu.memory.callStackBase
    }

    /// Copy back to the CPU's object state (every trampoline exit —
    /// the same sync-on-every-exit discipline hotRun documents).
    func syncOut(to cpu: NovaCPU) {
        cpu.cycle = cycle
        cpu.pc = pc
        cpu.dsp = dsp
        cpu.csp = csp
        cpu.fp = fp
        cpu.status = status
        cpu.epc = epc
        cpu.cause = cause
        cpu.tval = tval
        cpu.savedStatusForMret = savedStatus
        cpu.flagN = (flags & Self.flagN) != 0
        cpu.flagZ = (flags & Self.flagZ) != 0
        cpu.flagC = (flags & Self.flagC) != 0
        cpu.flagV = (flags & Self.flagV) != 0
        cpu.regs = [r0, r1, r2, r3, r4, r5, r6, r7,
                    r8, r9, r10, r11, r12, r13, r14, r15]
    }
}

// MARK: - Executable-memory allocator (design §1/§2.2)
//
// One allocation of executable memory under one path's discipline.
// Write and execute modes are explicit and mutually exclusive for
// the W^X and MAP_JIT paths (the pool is never RWX at execute time
// on those paths); plain RWX has no modes by definition.
final class JitCodeMemory {
    let base: UnsafeMutableRawPointer
    let byteCount: Int          // page-rounded allocation size
    let path: JitAllocPath
    private var inWriteMode: Bool

    /// errno from the most recent failed allocate() (0 if none).
    static private(set) var lastAllocationErrno: Int32 = 0

    private init(base: UnsafeMutableRawPointer, byteCount: Int, path: JitAllocPath) {
        self.base = base
        self.byteCount = byteCount
        self.path = path
        // W^X and plain-RWX allocations come up writable; a MAP_JIT
        // RWX allocation comes up in execute mode until
        // pthread_jit_write_protect_np(0) is called, so treat it as
        // NOT in write mode and let beginWrite() flip it.
        self.inWriteMode = (path != .mapJit)
    }

    deinit {
        munmap(base, byteCount)
    }

    // Darwin mmap flag values not all surfaced to Swift (as in the spike).
    private static let mapPrivate: Int32 = 0x0002
    private static let mapAnon: Int32 = 0x1000
    private static let mapJit: Int32 = 0x0800
    static let pageSize = 4096

    static func allocate(byteCount requested: Int, path: JitAllocPath) -> JitCodeMemory? {
        let size = ((max(requested, 1) + pageSize - 1) / pageSize) * pageSize
        let p: UnsafeMutableRawPointer?
        switch path {
        case .wxTransition:
            p = mmap(nil, size, PROT_READ | PROT_WRITE,
                     mapPrivate | mapAnon, -1, 0)
        case .mapJit:
            p = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                     mapPrivate | mapAnon | mapJit, -1, 0)
        case .plainRWX:
            p = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                     mapPrivate | mapAnon, -1, 0)
        }
        guard let base = p, base != UnsafeMutableRawPointer(bitPattern: -1) else {
            lastAllocationErrno = errno
            return nil
        }
        return JitCodeMemory(base: base, byteCount: size, path: path)
    }

    /// Enter write mode (pool must not be executed until
    /// beginExecute() is called again).
    func beginWrite() {
        switch path {
        case .wxTransition:
            if !inWriteMode {
                _ = mprotect(base, byteCount, PROT_READ | PROT_WRITE)
                inWriteMode = true
            }
        case .mapJit:
            if !inWriteMode {
                pthread_jit_write_protect_np(0) // 0 = writes allowed
                inWriteMode = true
            }
        case .plainRWX:
            break // always writable
        }
    }

    /// Enter execute mode (pool must not be written until
    /// beginWrite() is called again).
    func beginExecute() {
        switch path {
        case .wxTransition:
            if inWriteMode {
                _ = mprotect(base, byteCount, PROT_READ | PROT_EXEC)
                inWriteMode = false
            }
        case .mapJit:
            if inWriteMode {
                pthread_jit_write_protect_np(1) // 1 = execute allowed
                inWriteMode = false
            }
        case .plainRWX:
            break // always executable
        }
    }

    /// Copy machine code into the pool. Caller must be in write mode
    /// (beginWrite()). Invalidates the icache over the written range,
    /// as the spike does after every write.
    func write(_ bytes: [UInt8], at offset: Int) {
        precondition(offset >= 0 && offset + bytes.count <= byteCount,
                     "JitCodeMemory.write out of pool bounds")
        bytes.withUnsafeBytes { src in
            if let sp = src.baseAddress {
                (base + offset).copyMemory(from: sp, byteCount: bytes.count)
            }
        }
        novaJitSysICacheInvalidate(base + offset, bytes.count)
    }
}

// MARK: - JitState field offsets (design §5.1 + J2 appended slots)
//
// Generated code addresses JitState fields by baked byte offset, so
// the offsets are verified against MemoryLayout at every trampoline
// entry (J1 note, awkwardness 4): if Swift's layout ever disagrees
// with this table the trampoline declines the whole run before any
// guest instruction executes and the interpreter drives it instead.
// The compiler below uses ONLY these constants for state access.
enum JitOff {
    static let ramBase = 0
    static let ramSize = 8
    static let maxStart16 = 16
    static let maxStart32 = 24
    static let maxStart64 = 32
    static let cycle = 40
    static let pc = 48
    static let dsp = 56
    static let csp = 64
    static let fp = 72
    static let status = 80
    static let epc = 88
    static let cause = 96
    static let tval = 104
    static let savedStatus = 112
    static let flags = 120
    static let regs = 128           // r0; rN at regs + 8*N
    static let nextPc = 256
    static let lastDelta = 264
    static let exitAux = 272
    static let codeLo = 280
    static let codeHi = 288
    static let entryStatus = 296
    static let jitLimit = 304
    static let dslim = 312
    static let cslim = 320
    static let dataStackBase = 328
    static let callStackBase = 336
    static let limitReason = 344

    static func verifyLayout() -> Bool {
        func off(_ kp: PartialKeyPath<JitState>) -> Int {
            return MemoryLayout<JitState>.offset(of: kp) ?? -1
        }
        return off(\JitState.ramBase) == ramBase
            && off(\JitState.ramSize) == ramSize
            && off(\JitState.maxStart16) == maxStart16
            && off(\JitState.maxStart32) == maxStart32
            && off(\JitState.maxStart64) == maxStart64
            && off(\JitState.cycle) == cycle
            && off(\JitState.pc) == pc
            && off(\JitState.dsp) == dsp
            && off(\JitState.csp) == csp
            && off(\JitState.fp) == fp
            && off(\JitState.status) == status
            && off(\JitState.epc) == epc
            && off(\JitState.cause) == cause
            && off(\JitState.tval) == tval
            && off(\JitState.savedStatus) == savedStatus
            && off(\JitState.flags) == flags
            && off(\JitState.r0) == regs
            && off(\JitState.r1) == regs + 8
            && off(\JitState.r7) == regs + 56
            && off(\JitState.r15) == regs + 120
            && off(\JitState.nextPc) == nextPc
            && off(\JitState.lastDelta) == lastDelta
            && off(\JitState.exitAux) == exitAux
            && off(\JitState.codeLo) == codeLo
            && off(\JitState.codeHi) == codeHi
            && off(\JitState.entryStatus) == entryStatus
            && off(\JitState.jitLimit) == jitLimit
            && off(\JitState.dslim) == dslim
            && off(\JitState.cslim) == cslim
            && off(\JitState.dataStackBase) == dataStackBase
            && off(\JitState.callStackBase) == callStackBase
            && off(\JitState.limitReason) == limitReason
    }
}

// MARK: - AArch64 emitter (J2)
//
// Minimal word emitter with symbolic labels. Every encoding helper
// below was cross-checked against clang's AArch64 assembler during
// development (37/37 forms byte-identical). Branch offsets are
// patched in resolve(); an out-of-range branch makes resolve() fail
// and the compiler degrades that head to single-stepping (rule J7).
final class JitEmitter {
    var words: [UInt32] = []
    private var labelPos: [Int: Int] = [:]
    private var patches: [(at: Int, label: Int, isCond: Bool)] = []
    private var nextLabel = 1

    func newLabel() -> Int {
        let id = nextLabel
        nextLabel += 1
        return id
    }
    func place(_ label: Int) { labelPos[label] = words.count }
    func emit(_ w: UInt32) { words.append(w) }

    // Branches. Cond codes: eq 0, ne 1, hs 2, lo 3, mi 4, pl 5,
    // vs 6, vc 7, hi 8, ls 9, ge 10, lt 11, gt 12, le 13.
    func b(_ label: Int) {
        patches.append((at: words.count, label: label, isCond: false))
        emit(0x14000000)
    }
    func bcond(_ cond: UInt32, _ label: Int) {
        patches.append((at: words.count, label: label, isCond: true))
        emit(0x54000000 | cond)
    }
    func resolve() -> [UInt32]? {
        for p in patches {
            guard let target = labelPos[p.label] else { return nil }
            let off = target - p.at
            if p.isCond {
                guard off >= -(1 << 18) && off < (1 << 18) else { return nil }
                words[p.at] |= (UInt32(bitPattern: Int32(off)) & 0x7FFFF) << 5
            } else {
                guard off >= -(1 << 25) && off < (1 << 25) else { return nil }
                words[p.at] |= UInt32(bitPattern: Int32(off)) & 0x03FF_FFFF
            }
        }
        return words
    }

    // Data movement / arithmetic helpers (register numbers 0…31,
    // 31 = XZR/SP as the encoding dictates).
    func movz(_ rd: Int, _ imm: UInt32, hw: Int = 0) {
        emit(0xD2800000 | (UInt32(hw) << 21) | (imm << 5) | UInt32(rd))
    }
    func movk(_ rd: Int, _ imm: UInt32, hw: Int) {
        emit(0xF2800000 | (UInt32(hw) << 21) | (imm << 5) | UInt32(rd))
    }
    func loadImm64(_ rd: Int, _ value: UInt64) {
        movz(rd, UInt32(value & 0xFFFF), hw: 0)
        for hw in 1...3 {
            let chunk = UInt32((value >> UInt64(hw * 16)) & 0xFFFF)
            if chunk != 0 { movk(rd, chunk, hw: hw) }
        }
    }
    func movReg(_ rd: Int, _ rm: Int) { orrReg(rd, 31, rm) }
    func addImm(_ rd: Int, _ rn: Int, _ imm: Int) {
        emit(0x91000000 | (UInt32(imm) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func subImm(_ rd: Int, _ rn: Int, _ imm: Int) {
        emit(0xD1000000 | (UInt32(imm) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func subsImm(_ rd: Int, _ rn: Int, _ imm: Int) {
        emit(0xF1000000 | (UInt32(imm) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func cmpImm(_ rn: Int, _ imm: Int) { subsImm(31, rn, imm) }
    func addReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x8B000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func subReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0xCB000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func subsReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0xEB000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func cmpReg(_ rn: Int, _ rm: Int) { subsReg(31, rn, rm) }
    func andReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x8A000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func orrReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0xAA000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func eorReg(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0xCA000000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func mvn(_ rd: Int, _ rm: Int) {
        emit(0xAA200000 | (UInt32(rm) << 16) | (UInt32(31) << 5) | UInt32(rd))
    }
    func mul(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9B007C00 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func smulh(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9B407C00 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func sdiv(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9AC00C00 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func udiv(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9AC00800 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func lslv(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9AC02000 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func lsrv(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9AC02400 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func asrv(_ rd: Int, _ rn: Int, _ rm: Int) {
        emit(0x9AC02800 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }
    func rev(_ rd: Int, _ rn: Int) {
        emit(0xDAC00C00 | (UInt32(rn) << 5) | UInt32(rd))
    }
    func ldrOff(_ rt: Int, _ rn: Int, _ byteOff: Int) {
        emit(0xF9400000 | (UInt32(byteOff / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
    }
    func strOff(_ rt: Int, _ rn: Int, _ byteOff: Int) {
        emit(0xF9000000 | (UInt32(byteOff / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
    }
    func stpPre(_ rt1: Int, _ rt2: Int, off: Int) {
        let imm7 = UInt32((off / 8) & 0x7F)
        emit(0xA9800000 | (imm7 << 15) | (UInt32(rt2) << 10) | (UInt32(31) << 5) | UInt32(rt1))
    }
    func ldpPost(_ rt1: Int, _ rt2: Int, off: Int) {
        let imm7 = UInt32((off / 8) & 0x7F)
        emit(0xA8C00000 | (imm7 << 15) | (UInt32(rt2) << 10) | (UInt32(31) << 5) | UInt32(rt1))
    }
    func ret() { emit(0xD65F03C0) }
}

// MARK: - Block compiler (J2: stack + integer ALU groups only)
//
// Register discipline (design §5.1): x19 = JitState*, x20 = delta,
// x21/x22/x23 = dsp/csp/fp, x24 = limit, x25 = ramBase,
// x26 = dslim, x27 = dataStackBase, x28 = cslim. Scratch: x9–x11
// (stack sequences; never hold a guest value across one), x13 = a /
// result, x14 = b, x15 = c / addr / flags accumulator, x16 = loop
// counter for POPN/ENTER. Guest values NEVER live in x9–x11.
//
// Codegen rule (design §6): checks and mutations are emitted in
// step()'s exact statement order for each opcode; a fault exit is
// reachable only where step() can throw, with every earlier
// mutation already committed and the faulting access uncommitted.
// Fault exits present pc = the faulting instruction's nextPC,
// exactly the interpreter's "pc past the operand, cycle counted"
// fault state. Delta is incremented by the per-instruction boundary
// sequence BEFORE the body, mirroring step()'s fetch increment.

private enum JitStubKind {
    case fault(trap: UInt64, pc: UInt64)
    case limit(pc: UInt64)
    case singleStep(pc: UInt64)
    case invalidated(pc: UInt64)
}

final class JitBlockCompiler {
    let em = JitEmitter()
    private let buf: UnsafeMutablePointer<UInt8>
    private let ramSize: UInt64
    private let dslim: UInt64
    private let dataBase: UInt64
    private let cslim: UInt64
    private let callBase: UInt64
    private let vslim: UInt64
    private let vectorBase: UInt64

    private var stubs: [(label: Int, kind: JitStubKind)] = []
    private var faultLabels: [UInt64: Int] = [:]   // trap raw -> label, per instruction
    private var faultPc: UInt64 = 0                // nextPC of the instruction being emitted
    private let foldLabel: Int

    // AArch64 condition codes used below.
    private let ccEQ: UInt32 = 0, ccNE: UInt32 = 1, ccHS: UInt32 = 2, ccLO: UInt32 = 3
    private let ccPL: UInt32 = 5, ccVC: UInt32 = 7, ccHI: UInt32 = 8, ccLS: UInt32 = 9
    private let ccLT: UInt32 = 11

    init(buf: UnsafeMutablePointer<UInt8>, ramSize: UInt64,
         dslim: UInt64, dataBase: UInt64, cslim: UInt64, callBase: UInt64,
         vslim: UInt64, vectorBase: UInt64) {
        self.buf = buf
        self.ramSize = ramSize
        self.dslim = dslim
        self.dataBase = dataBase
        self.cslim = cslim
        self.callBase = callBase
        self.vslim = vslim
        self.vectorBase = vectorBase
        self.foldLabel = em.newLabel()
    }

    private func stubLabel(_ kind: JitStubKind) -> Int {
        let label = em.newLabel()
        stubs.append((label: label, kind: kind))
        return label
    }
    /// Fault-exit label for `trap` in the current instruction
    /// (faultPc must already hold the instruction's nextPC).
    private func faultLabel(_ trap: NovaTrap) -> Int {
        if let l = faultLabels[trap.rawValue] { return l }
        let l = stubLabel(.fault(trap: trap.rawValue, pc: faultPc))
        faultLabels[trap.rawValue] = l
        return l
    }

    // ---- Boundary sequence (design §5.2/§5.3) ----
    // Check only: if limit == 0, exit via a limit stub naming this
    // instruction's pc. Commit (separately, for the DIV peek bail):
    // limit -= 1, delta += 1.
    private func boundaryCheckOnly(insnPc: UInt64) {
        let l = stubLabel(.limit(pc: insnPc))
        em.cmpImm(24, 0)
        em.bcond(ccEQ, l)
    }
    private func boundaryCommit() {
        em.subImm(24, 24, 1)
        em.addImm(20, 20, 1)
    }
    private func boundary(insnPc: UInt64) {
        boundaryCheckOnly(insnPc: insnPc)
        boundaryCommit()
    }

    // ---- Stack primitives (mirrors of dpush/dpop/cpush/cpop) ----
    // Value in x13 (dpush/cpush) or loaded into `dest` (pops).
    // Sequences use x9–x11 only for checks/addressing, so a push's
    // value register may be x13, x14 or x15.
    private func emitDPush() { emitDPushVal(13) }
    private func emitDPushVal(_ vreg: Int) {
        em.subImm(10, 21, 8)                                  // nsp
        em.cmpReg(10, 26)                                     // nsp < dslim?
        em.bcond(ccLO, faultLabel(.stackOverflow))
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(10, 9)
        em.bcond(ccHI, faultLabel(.storeAccessFault))
        em.addReg(11, 25, 10)
        em.strOff(vreg, 11, 0)
        em.movReg(21, 10)
    }
    private func emitDPop(dest: Int) {
        em.cmpReg(21, 27)                                     // dsp >= dataBase?
        em.bcond(ccHS, faultLabel(.stackUnderflow))
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(21, 9)
        em.bcond(ccHI, faultLabel(.loadAccessFault))
        em.addReg(10, 25, 21)
        em.ldrOff(dest, 10, 0)
        em.addImm(21, 21, 8)
    }
    private func emitCPush() {
        em.subImm(10, 22, 8)
        em.cmpReg(10, 28)                                     // nsp < cslim?
        em.bcond(ccLO, faultLabel(.stackOverflow))
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(10, 9)
        em.bcond(ccHI, faultLabel(.storeAccessFault))
        em.addReg(11, 25, 10)
        em.strOff(13, 11, 0)
        em.movReg(22, 10)
    }
    private func emitCPop(dest: Int) {
        em.ldrOff(9, 19, JitOff.callStackBase)
        em.cmpReg(22, 9)                                      // csp >= callBase?
        em.bcond(ccHS, faultLabel(.stackUnderflow))
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(22, 9)
        em.bcond(ccHI, faultLabel(.loadAccessFault))
        em.addReg(10, 25, 22)
        em.ldrOff(dest, 10, 0)
        em.addImm(22, 22, 8)
    }
    /// Checked guest load64: addr in x15 -> value in x13.
    private func emitLoad64() {
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(15, 9)
        em.bcond(ccHI, faultLabel(.loadAccessFault))
        em.addReg(10, 25, 15)
        em.ldrOff(13, 10, 0)
    }
    /// Checked guest store64: addr in x15, value in x13.
    private func emitStore64() {
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(15, 9)
        em.bcond(ccHI, faultLabel(.storeAccessFault))
        em.addReg(10, 25, 15)
        em.strOff(13, 10, 0)
    }

    /// CMP/TST flag capture: host NZCV (set by the preceding subs)
    /// is packed into JitState.flags (bit3 N, bit2 Z, bit1 C,
    /// bit0 V — the JitState packing). Only flag-neutral
    /// instructions (movz/orr/branches) intervene, so the host
    /// flags survive until read.
    private func emitCaptureFlags() {
        em.movz(15, 0)
        let l1 = em.newLabel()
        em.bcond(ccVC, l1)                                    // V clear -> skip
        em.movz(9, 1)
        em.orrReg(15, 15, 9)
        em.place(l1)
        let l2 = em.newLabel()
        em.bcond(ccLO, l2)                                    // C clear (lo) -> skip
        em.movz(9, 2)
        em.orrReg(15, 15, 9)
        em.place(l2)
        let l3 = em.newLabel()
        em.bcond(ccNE, l3)                                    // Z clear -> skip
        em.movz(9, 4)
        em.orrReg(15, 15, 9)
        em.place(l3)
        let l4 = em.newLabel()
        em.bcond(ccPL, l4)                                    // N clear -> skip
        em.movz(9, 8)
        em.orrReg(15, 15, 9)
        em.place(l4)
        em.strOff(15, 19, JitOff.flags)
    }

    /// SWAR popcount of x13 (algorithm verified against Python's
    /// bit_count on 100k random values). Uses x9–x11; the shift
    /// amount register is x11, freed after each shift.
    private func emitPopcnt() {
        em.movz(11, 1)
        em.lsrv(9, 13, 11)                                    // x >> 1
        em.loadImm64(10, 0x5555_5555_5555_5555)
        em.andReg(9, 9, 10)
        em.subReg(13, 13, 9)                                  // x -= (x>>1) & 0x5555…
        em.movz(11, 2)
        em.lsrv(9, 13, 11)                                    // x >> 2
        em.loadImm64(10, 0x3333_3333_3333_3333)
        em.andReg(9, 9, 10)
        em.andReg(11, 13, 10)
        em.addReg(13, 11, 9)                                  // x = (x & 0x3333…) + ((x>>2) & 0x3333…)
        em.movz(11, 4)
        em.lsrv(9, 13, 11)                                    // x >> 4
        em.addReg(9, 9, 13)
        em.loadImm64(10, 0x0F0F_0F0F_0F0F_0F0F)
        em.andReg(13, 9, 10)                                  // x = (x + (x>>4)) & 0x0F0F…
        em.loadImm64(10, 0x0101_0101_0101_0101)
        em.mul(13, 13, 10)
        em.movz(11, 56)
        em.lsrv(13, 13, 11)                                   // count = (x * 0x0101…) >> 56
    }

    /// Set x13 = boolean of condition `cond` for the just-emitted
    /// compare (movz does not disturb host flags).
    private func emitBoolFromFlags(cond: UInt32) {
        em.movz(13, 1)
        let done = em.newLabel()
        em.bcond(cond, done)
        em.movz(13, 0)
        em.place(done)
    }

    private func inStackRegion(pc: UInt64, len: UInt64) -> Bool {
        func overlaps(_ lo: UInt64, _ hi: UInt64) -> Bool {
            return pc < hi && lo < pc &+ len
        }
        return overlaps(dslim, dataBase) || overlaps(cslim, callBase)
            || overlaps(vslim, vectorBase)
    }

    /// Operand length (excluding the opcode byte) for a compiled
    /// opcode, or nil if the opcode is NOT in the J2 groups (stack
    /// 0x00–0x1E, ALU 0x40–0x60 as implemented by step(), minus the
    /// exclusions applied in compile()).
    private func operandLength(_ opcode: UInt8) -> Int? {
        switch opcode {
        case 0x01, 0x06, 0x0E, 0x14, 0x16, 0x17, 0x18, 0x19, 0x1A:
            return 1
        case 0x02: return 2
        case 0x03: return 4
        case 0x04: return 8
        case 0x00, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
             0x10, 0x11, 0x13, 0x15, 0x1B, 0x1C, 0x1D:
            return 0
        case 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
             0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51,
             0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x5C, 0x5D, 0x5E,
             0x5F, 0x60:
            return 0
        default:
            return nil
        }
    }

    /// Compile the block at `head`. Returns nil when the head itself
    /// is not compilable (0 instructions); otherwise a block whose
    /// code is in `words` after a successful resolve().
    func compile(head: UInt64) -> (block: CompiledBlock, words: [UInt32])? {
        // ---- Prologue ----
        em.stpPre(29, 30, off: -16)
        em.stpPre(19, 20, off: -16)
        em.stpPre(21, 22, off: -16)
        em.stpPre(23, 24, off: -16)
        em.stpPre(25, 26, off: -16)
        em.stpPre(27, 28, off: -16)
        em.movReg(19, 0)
        em.ldrOff(21, 19, JitOff.dsp)
        em.ldrOff(22, 19, JitOff.csp)
        em.ldrOff(23, 19, JitOff.fp)
        em.ldrOff(24, 19, JitOff.jitLimit)
        em.ldrOff(25, 19, JitOff.ramBase)
        em.ldrOff(26, 19, JitOff.dslim)
        em.ldrOff(27, 19, JitOff.dataStackBase)
        em.ldrOff(28, 19, JitOff.cslim)
        em.movReg(20, 31)                                     // delta = 0

        var pc = head
        var count = 0
        var endIsCap = false
        while count < 64 {
            let insnPc = pc
            // Decode-fault / head checks: the interpreter reproduces
            // these states itself, so the block ends BEFORE here.
            if insnPc >= ramSize { break }
            let opcode = buf[Int(insnPc)]
            // J2 exclusions ending the block BEFORE the instruction:
            // 0x0F ROLL (design bail), 0x12 DSPSET / 0x1E CSPSET
            // (stack-pointer moves; single-stepped + J5 flush in J2 —
            // design's terminating treatment is J3), and everything
            // outside the two groups.
            if opcode == 0x0F || opcode == 0x12 || opcode == 0x1E { break }
            guard let oplen = operandLength(opcode) else { break }
            let total = UInt64(1 + oplen)
            if insnPc &+ total > ramSize { break }              // operand would fault at fetch
            if inStackRegion(pc: insnPc, len: total) { break }  // rule J2 premise
            let nextPc = insnPc &+ total
            faultPc = nextPc
            faultLabels = [:]
            emitInstruction(opcode: opcode, insnPc: insnPc, nextPc: nextPc)
            pc = nextPc
            count += 1
            if count == 64 { endIsCap = true }
        }
        if count == 0 { return nil }

        var block = CompiledBlock()
        block.guestPC = head
        block.byteLength = Int(pc &- head)
        block.instructionCount = count
        block.endIsCap = endIsCap
        block.endPc = pc

        // ---- Normal (.next) exit stub, fallen into ----
        em.loadImm64(9, pc)
        em.strOff(9, 19, JitOff.pc)
        em.movz(0, 0)                                         // reason .next
        em.b(foldLabel)

        // ---- Per-site exit stubs ----
        for stub in stubs {
            em.place(stub.label)
            switch stub.kind {
            case .fault(let trap, let fpc):
                em.loadImm64(9, fpc)
                em.strOff(9, 19, JitOff.pc)
                em.movz(9, UInt32(trap))
                em.strOff(9, 19, JitOff.exitAux)
                em.movz(0, 1)                                 // reason .fault
                em.b(foldLabel)
            case .limit(let lpc):
                em.loadImm64(9, lpc)
                em.strOff(9, 19, JitOff.pc)
                em.ldrOff(0, 19, JitOff.limitReason)          // .timerLimit / .budgetLimit
                em.b(foldLabel)
            case .singleStep(let spc):
                em.loadImm64(9, spc)
                em.strOff(9, 19, JitOff.pc)
                em.movz(0, 3)                                 // reason .singleStep
                em.b(foldLabel)
            case .invalidated(let ipc):
                em.loadImm64(9, ipc)
                em.strOff(9, 19, JitOff.pc)
                em.movz(0, 4)                                 // reason .invalidated
                em.b(foldLabel)
            }
        }

        // ---- Common fold + epilogue (design §5.2) ----
        em.place(foldLabel)
        em.ldrOff(9, 19, JitOff.cycle)
        em.addReg(9, 9, 20)
        em.strOff(9, 19, JitOff.cycle)
        em.strOff(21, 19, JitOff.dsp)
        em.strOff(22, 19, JitOff.csp)
        em.strOff(23, 19, JitOff.fp)
        em.strOff(20, 19, JitOff.lastDelta)
        em.ldrOff(9, 19, JitOff.pc)
        em.strOff(9, 19, JitOff.nextPc)
        em.ldpPost(27, 28, off: 16)
        em.ldpPost(25, 26, off: 16)
        em.ldpPost(23, 24, off: 16)
        em.ldpPost(21, 22, off: 16)
        em.ldpPost(19, 20, off: 16)
        em.ldpPost(29, 30, off: 16)
        em.ret()

        guard let resolved = em.resolve() else { return nil }
        return (block: block, words: resolved)
    }

    // ---- Per-opcode emission. faultPc/faultLabels are set up by
    // compile() before each call; `boundary` has already accounted
    // the instruction unless noted (signed DIV/REM peek bail). ----
    private func emitInstruction(opcode: UInt8, insnPc: UInt64, nextPc: UInt64) {
        func imm8() -> UInt8 { return buf[Int(insnPc) + 1] }
        func imm16() -> UInt16 {
            return UInt16(buf[Int(insnPc) + 1]) | (UInt16(buf[Int(insnPc) + 2]) << 8)
        }
        func imm32() -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(buf[Int(insnPc) + 1 + i]) << UInt32(i * 8) }
            return v
        }
        func imm64() -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(buf[Int(insnPc) + 1 + i]) << UInt64(i * 8) }
            return v
        }

        switch opcode {
        // ---- Stack group ----
        case 0x00: // NOP
            boundary(insnPc: insnPc)
        case 0x01: // PUSH8 (sign-extended)
            boundary(insnPc: insnPc)
            em.loadImm64(13, UInt64(bitPattern: Int64(Int8(bitPattern: imm8()))))
            emitDPush()
        case 0x02: // PUSH16
            boundary(insnPc: insnPc)
            em.loadImm64(13, UInt64(bitPattern: Int64(Int16(bitPattern: imm16()))))
            emitDPush()
        case 0x03: // PUSH32
            boundary(insnPc: insnPc)
            em.loadImm64(13, UInt64(bitPattern: Int64(Int32(bitPattern: imm32()))))
            emitDPush()
        case 0x04: // PUSH64
            boundary(insnPc: insnPc)
            em.loadImm64(13, imm64())
            emitDPush()
        case 0x05: // POP
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
        case 0x06: // POPN n
            boundary(insnPc: insnPc)
            let n = imm8()
            if n > 0 {
                em.movz(16, UInt32(n))
                let loopL = em.newLabel()
                let doneL = em.newLabel()
                em.place(loopL)
                em.cmpImm(16, 0)
                em.bcond(ccEQ, doneL)
                emitDPop(dest: 13)
                em.subImm(16, 16, 1)
                em.b(loopL)
                em.place(doneL)
            }
        case 0x07: // DUP
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPush(); emitDPush()
        case 0x08: // DUP2: a b -> a b a b (a = top)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            emitDPushVal(14); emitDPushVal(13); emitDPushVal(14); emitDPushVal(13)
        case 0x09: // SWAP
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            emitDPushVal(13); emitDPushVal(14)
        case 0x0A: // ROT: a b c -> b c a (a = top)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14); emitDPop(dest: 15)
            emitDPushVal(14); emitDPushVal(13); emitDPushVal(15)
        case 0x0B: // ROTR: a b c -> c a b
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14); emitDPop(dest: 15)
            emitDPushVal(13); emitDPushVal(15); emitDPushVal(14)
        case 0x0C: // OVER: a b -> a b a
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            emitDPushVal(14); emitDPushVal(13); emitDPushVal(14)
        case 0x0D: // TUCK: a b -> b a b
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            emitDPushVal(13); emitDPushVal(14); emitDPushVal(13)
        case 0x0E: // PICK n
            boundary(insnPc: insnPc)
            em.addImm(15, 21, Int(imm8()) * 8)
            emitLoad64()
            emitDPush()
        case 0x10: // DEPTH
            boundary(insnPc: insnPc)
            em.subReg(13, 27, 21)
            em.movz(9, 3)
            em.lsrv(13, 13, 9)
            emitDPush()
        case 0x11: // DSPGET
            boundary(insnPc: insnPc)
            em.movReg(13, 21)
            emitDPush()
        case 0x13: // FPGET
            boundary(insnPc: insnPc)
            em.movReg(13, 23)
            emitDPush()
        case 0x14: // ENTER n
            boundary(insnPc: insnPc)
            em.movReg(13, 23)
            emitCPush()
            em.movReg(23, 21)                                 // fp = dsp
            let n = imm8()
            if n > 0 {
                em.movReg(13, 31)                             // value 0
                em.movz(16, UInt32(n))
                let loopL = em.newLabel()
                let doneL = em.newLabel()
                em.place(loopL)
                em.cmpImm(16, 0)
                em.bcond(ccEQ, doneL)
                emitDPush()
                em.subImm(16, 16, 1)
                em.b(loopL)
                em.place(doneL)
            }
        case 0x15: // LEAVE
            boundary(insnPc: insnPc)
            em.movReg(21, 23)                                 // dsp = fp (before cpop, as step())
            emitCPop(dest: 13)
            em.movReg(23, 13)                                 // fp = popped
        case 0x16: // LOADL n
            boundary(insnPc: insnPc)
            em.subImm(15, 23, (Int(imm8()) + 1) * 8)
            emitLoad64()
            emitDPush()
        case 0x17: // STORL n (+ rule J1 interval check after the store)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.subImm(15, 23, (Int(imm8()) + 1) * 8)
            emitStore64()
            let noInv = em.newLabel()
            em.ldrOff(9, 19, JitOff.codeLo)
            em.addImm(10, 15, 8)
            em.cmpReg(10, 9)
            em.bcond(ccLS, noInv)                             // addr+8 <= codeLo: no overlap
            em.ldrOff(9, 19, JitOff.codeHi)
            em.cmpReg(15, 9)
            em.bcond(ccHS, noInv)                             // addr >= codeHi: no overlap
            em.b(stubLabel(.invalidated(pc: nextPc)))
            em.place(noInv)
        case 0x18: // LOADARG n
            boundary(insnPc: insnPc)
            em.addImm(15, 23, Int(imm8()) * 8)
            emitLoad64()
            emitDPush()
        case 0x19: // PUSHR n
            boundary(insnPc: insnPc)
            let n = imm8()
            if n >= 16 {
                em.movz(9, UInt32(n))
                em.strOff(9, 19, JitOff.tval)
                em.b(faultLabel(.illegalInstruction))
            } else {
                em.ldrOff(13, 19, JitOff.regs + Int(n) * 8)
                emitDPush()
            }
        case 0x1A: // POPR n
            boundary(insnPc: insnPc)
            let n = imm8()
            if n >= 16 {
                em.movz(9, UInt32(n))
                em.strOff(9, 19, JitOff.tval)
                em.b(faultLabel(.illegalInstruction))
            } else {
                emitDPop(dest: 13)
                em.strOff(13, 19, JitOff.regs + Int(n) * 8)
            }
        case 0x1B: // PUSHALL — R0 first, R15 on top
            boundary(insnPc: insnPc)
            for i in 0..<16 {
                em.ldrOff(13, 19, JitOff.regs + i * 8)
                emitDPush()
            }
        case 0x1C: // POPALL — top of stack -> R15 … R0
            boundary(insnPc: insnPc)
            for i in (0..<16).reversed() {
                emitDPop(dest: 13)
                em.strOff(13, 19, JitOff.regs + i * 8)
            }
        case 0x1D: // CSPGET
            boundary(insnPc: insnPc)
            em.movReg(13, 22)
            emitDPush()

        // ---- Integer ALU group ----
        case 0x40: // ADD
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.addReg(13, 14, 13)
            emitDPush()
        case 0x41: // SUB
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.subReg(13, 14, 13)
            emitDPush()
        case 0x42: // MUL
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.mul(13, 14, 13)
            emitDPush()
        case 0x43: // MULH (signed high)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.smulh(13, 14, 13)
            emitDPush()
        case 0x44: // DIV (signed) — peek-guarded (design §6.1 / D2)
            emitSignedDivRem(insnPc: insnPc, nextPc: nextPc, isRem: false)
        case 0x46: // REM (signed)
            emitSignedDivRem(insnPc: insnPc, nextPc: nextPc, isRem: true)
        case 0x45: // DIVU
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpImm(13, 0)
            em.bcond(ccEQ, faultLabel(.illegalInstruction))
            em.udiv(13, 14, 13)
            emitDPush()
        case 0x47: // REMU
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpImm(13, 0)
            em.bcond(ccEQ, faultLabel(.illegalInstruction))
            em.udiv(15, 14, 13)
            em.mul(15, 15, 13)
            em.subReg(13, 14, 15)
            emitDPush()
        case 0x48: // AND
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.andReg(13, 14, 13)
            emitDPush()
        case 0x49: // OR
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.orrReg(13, 14, 13)
            emitDPush()
        case 0x4A: // XOR
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.eorReg(13, 14, 13)
            emitDPush()
        case 0x4B: // NOT
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.mvn(13, 13)
            emitDPush()
        case 0x4C: // NEG
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.subReg(13, 31, 13)
            emitDPush()
        case 0x4D: // SHL (register shifts mask the count to 6 bits,
            // exactly the interpreter's `& 63`)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.lslv(13, 14, 13)
            emitDPush()
        case 0x4E: // SHR
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.lsrv(13, 14, 13)
            emitDPush()
        case 0x4F: // SAR
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.asrv(13, 14, 13)
            emitDPush()
        case 0x50: // INC
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.addImm(13, 13, 1)
            emitDPush()
        case 0x51: // DEC
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.subImm(13, 13, 1)
            emitDPush()
        case 0x52: // CMP — flags only, no push
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.subsReg(15, 14, 13)
            emitCaptureFlags()
        case 0x53: // TST — flags for (a - 0), value pushed back
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.subsReg(15, 13, 31)
            emitCaptureFlags()
            emitDPush()
        case 0x54: // EQ
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpReg(14, 13)
            emitBoolFromFlags(cond: ccEQ)
            emitDPush()
        case 0x55: // NE
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpReg(14, 13)
            emitBoolFromFlags(cond: ccNE)
            emitDPush()
        case 0x56: // LT (signed)
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpReg(14, 13)
            emitBoolFromFlags(cond: ccLT)
            emitDPush()
        case 0x57: // LTU
            boundary(insnPc: insnPc)
            emitDPop(dest: 13); emitDPop(dest: 14)
            em.cmpReg(14, 13)
            emitBoolFromFlags(cond: ccLO)
            emitDPush()
        case 0x5C: // POPCNT
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            emitPopcnt()
            emitDPush()
        case 0x5D: // REV8
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.rev(13, 13)
            emitDPush()
        case 0x5E: // EXT8 — sign-extend low 8 bits via shift pair
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.movz(9, 56)
            em.lslv(13, 13, 9)
            em.asrv(13, 13, 9)
            emitDPush()
        case 0x5F: // EXT16
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.movz(9, 48)
            em.lslv(13, 13, 9)
            em.asrv(13, 13, 9)
            emitDPush()
        case 0x60: // EXT32
            boundary(insnPc: insnPc)
            emitDPop(dest: 13)
            em.movz(9, 32)
            em.lslv(13, 13, 9)
            em.asrv(13, 13, 9)
            emitDPush()
        default:
            // Unreachable: compile() only calls for grouped opcodes.
            boundary(insnPc: insnPc)
        }
    }

    /// Signed DIV/REM with the design D2 peek bail: BEFORE the
    /// boundary commit, peek both operands (no pops). The pair
    /// (dividend INT64_MIN, divisor -1) exits .singleStep with pc at
    /// the instruction and delta excluding it, so the trampoline's
    /// step() reproduces the interpreter's host behaviour exactly.
    /// Any state in which peeking itself would fault falls through
    /// to the normal body, whose pops fault in step()'s order.
    private func emitSignedDivRem(insnPc: UInt64, nextPc: UInt64, isRem: Bool) {
        boundaryCheckOnly(insnPc: insnPc)
        let body = em.newLabel()
        // Peek slot 0 (divisor, on top): must be readable and == -1.
        em.cmpReg(21, 27)
        em.bcond(ccHS, body)                                  // underflow -> body faults
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(21, 9)
        em.bcond(ccHI, body)                                  // unreadable -> body faults
        em.addReg(10, 25, 21)
        em.ldrOff(13, 10, 0)                                  // a = divisor
        em.loadImm64(9, 0xFFFF_FFFF_FFFF_FFFF)
        em.cmpReg(13, 9)
        em.bcond(ccNE, body)
        // Peek slot 1 (dividend): must be readable and == INT64_MIN.
        em.addImm(10, 21, 8)
        em.cmpReg(10, 27)
        em.bcond(ccHS, body)
        em.ldrOff(9, 19, JitOff.maxStart64)
        em.cmpReg(10, 9)
        em.bcond(ccHI, body)
        em.addReg(10, 25, 10)
        em.ldrOff(14, 10, 0)                                  // b = dividend
        em.loadImm64(9, 0x8000_0000_0000_0000)
        em.cmpReg(14, 9)
        em.bcond(ccNE, body)
        em.b(stubLabel(.singleStep(pc: insnPc)))              // bail BEFORE the instruction
        em.place(body)
        boundaryCommit()
        emitDPop(dest: 13); emitDPop(dest: 14)
        em.cmpImm(13, 0)
        em.bcond(ccEQ, faultLabel(.illegalInstruction))
        if isRem {
            em.sdiv(15, 14, 13)
            em.mul(15, 15, 13)
            em.subReg(13, 14, 15)
        } else {
            em.sdiv(13, 14, 13)
        }
        emitDPush()
    }
}

// MARK: - NovaJIT: probe + trampoline interface

final class NovaJIT {

    /// Result of the most recent probe() in this process. Re-probed
    /// at every run() entry with JIT requested — never trusted across
    /// runs, because a debugger (StikDebug) can attach or detach
    /// between runs (design §2.2).
    static private(set) var lastProbe: JitAvailability =
        .unavailable(reason: .notProbedYet)

    /// The probe's winning allocation, kept mapped for the current
    /// run (per-run lifetime, rule J6). J2's code pool is built with
    /// the same allocator; in J1 this page holds only the smoke test.
    static private(set) var activePool: JitCodeMemory?

    /// Per-platform allocation preference order (design §2.2 / D1).
    static var preferenceOrder: [JitAllocPath] {
#if os(iOS)
        return [.mapJit, .wxTransition, .plainRWX]
#else
        return [.wxTransition, .mapJit, .plainRWX]
#endif
    }

    /// The spike's smoke test, byte-identical on arm64:
    /// mov w0, #42 (0x52800540); ret (0xD65F03C0), little-endian.
    private static let const42Code: [UInt8] =
        [0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6]

    /// Runtime gate (design §2.2): try each path in preference
    /// order; for the first that allocates, write const42, flip to
    /// executable state by that path's discipline, call it, and
    /// require 42. Only a path that EXECUTES counts. On total
    /// failure the result is .unavailable and the caller silently
    /// runs the interpreter — no error, no trap, no console output.
    static func probe() -> JitAvailability {
#if arch(arm64)
        activePool = nil // release any previous run's pool first (J6)
        var sawAllocation = false
        var lastErrno: Int32 = 0
        for path in preferenceOrder {
            guard let pool = JitCodeMemory.allocate(
                    byteCount: JitCodeMemory.pageSize, path: path) else {
                lastErrno = JitCodeMemory.lastAllocationErrno
                continue
            }
            sawAllocation = true
            if smokeTest(pool) {
                activePool = pool
                lastProbe = .available(path: path)
                return lastProbe
            }
            // pool deinitializes here (pages unmapped) before the
            // next path is tried.
        }
        lastProbe = .unavailable(reason: sawAllocation
                                 ? .smokeTestFailed
                                 : .allocationFailed(errno: lastErrno))
        return lastProbe
#else
        lastProbe = .unavailable(reason: .unsupportedArchitecture)
        return lastProbe
#endif
    }

    /// Write const42 into `pool`, flip it executable, call it.
    private static func smokeTest(_ pool: JitCodeMemory) -> Bool {
#if arch(arm64)
        pool.beginWrite()
        pool.write(const42Code, at: 0)
        pool.beginExecute()
        let fn = unsafeBitCast(pool.base, to: JitFnConst.self)
        return fn() == 42
#else
        _ = pool
        return false
#endif
    }

    /// The trampoline interface later lanes drive from
    /// NovaCPU.run()'s dispatch point. Contract: return true iff the
    /// trampoline drove the whole run (object state fully synced on
    /// return, exactly as hotRun leaves it); return false to decline
    /// and let run() fall through to the shipped hotloop body.
    ///
    /// J2: the trampoline compiles and executes blocks of the
    /// stack + integer-ALU groups (see JitBlockCompiler). Every
    /// other instruction is executed by one real step() call from
    /// here, with the same step accounting and trap handling as
    /// run()'s bail path, followed by a whole-cache flush (rule
    /// J5). Declining happens ONLY before any guest instruction
    /// executes (layout verification or pool allocation failure),
    /// so a declined run is bit-identical to the interpreter's.
    static func runTrampoline(cpu: NovaCPU, maxSteps: UInt64) -> Bool {
#if arch(arm64)
        guard JitOff.verifyLayout() else { return false }
        guard case .available(let path) = lastProbe else { return false }
        // Per-run code pool (rule J6): 4 MiB of executable memory on
        // the probe's winning path. Exhaustion is a flush + recycle
        // (rule J7), never a failure.
        guard let pool = JitCodeMemory.allocate(byteCount: 4 * 1024 * 1024,
                                                path: path) else {
            return false
        }

        var stats = JitStats()
        // JitState lives behind a stable heap pointer for the whole
        // run: generated code receives exactly this address, and the
        // trampoline reads back the fields its exit stubs wrote.
        let statePtr = UnsafeMutablePointer<JitState>.allocate(capacity: 1)
        statePtr.initialize(to: JitState())
        defer {
            statePtr.deinitialize(count: 1)
            statePtr.deallocate()
        }
        var cache: [UInt64: CompiledBlock] = [:]
        var codeLo: UInt64 = 0
        var codeHi: UInt64 = 0
        var poolOffset = 0
        var failedHeads = Set<UInt64>()
        var stepsUsed: UInt64 = 0
        var finished = false

        cpu.running = true

        func flushCache(countStat: Bool) {
            if !cache.isEmpty {
                cache.removeAll()
                codeLo = 0
                codeHi = 0
                if countStat { stats.invalidations += 1 }
            }
            // Bytes may have changed (the flush points are exactly
            // the points where host/interpreter writes are known to
            // have happened), so heads that failed compilation get
            // retried against fresh bytes.
            failedHeads.removeAll()
        }

        // One interpreter step on the JIT's behalf (foreign/bail
        // instruction), accounted exactly like run()'s bail path:
        // the step counts whether it traps or not, traps go through
        // the interpreter's own handleTrapAfterStep, and the whole
        // cache is flushed afterwards (rule J5).
        func singleStep() {
            do {
                try cpu.step()
            } catch let trap as NovaTrap {
                cpu.jitHandleTrapAfterStep(trap)
            } catch {
                cpu.running = false
            }
            stepsUsed &+= 1
            stats.singleSteps += 1
            flushCache(countStat: true)
        }

        cpu.memory.withHotBuffer { (buf: UnsafeMutablePointer<UInt8>) in
            let ramSize = UInt64(cpu.memory.totalSize)
            while !finished && cpu.running && stepsUsed < maxSteps {
                // State authority: after a block, cpu was syncOut'ed
                // from `state`; after a step()/trap, cpu holds the
                // interpreter's own state. Re-syncing `state` from
                // cpu at every dispatch is therefore always correct.
                statePtr.pointee.syncIn(from: cpu)
                statePtr.pointee.ramBase = UInt64(UInt(bitPattern: buf))

                let interval = cpu.memory.timerInterval
                let armed = interval > 0 && (statePtr.pointee.status & 1) != 0

                // Defensive timer corner (design §5.3): an armed
                // timer whose countdown is already 0 cannot enter a
                // block (timerAllow would underflow). Emulate the
                // firing exactly as hotRun's timer path does: reset
                // the countdown, count one step, flush (J4), vector.
                if armed && cpu.memory.timerCount == 0 {
                    cpu.memory.timerCount = interval
                    stepsUsed &+= 1
                    stats.limitExits += 1
                    flushCache(countStat: true)
                    cpu.jitHandleTrapAfterStep(.timerInterrupt)
                    continue
                }

                let head = statePtr.pointee.pc
                var block = cache[head]

                if block == nil && !failedHeads.contains(head) {
                    let compiler = JitBlockCompiler(
                        buf: buf, ramSize: ramSize,
                        dslim: cpu.dslim, dataBase: cpu.memory.dataStackBase,
                        cslim: cpu.cslim, callBase: cpu.memory.callStackBase,
                        vslim: cpu.vslim, vectorBase: cpu.memory.vectorStackBase)
                    if let compiled = compiler.compile(head: head) {
                        var bytes: [UInt8] = []
                        bytes.reserveCapacity(compiled.words.count * 4)
                        for w in compiled.words {
                            bytes.append(UInt8(w & 0xFF))
                            bytes.append(UInt8((w >> 8) & 0xFF))
                            bytes.append(UInt8((w >> 16) & 0xFF))
                            bytes.append(UInt8((w >> 24) & 0xFF))
                        }
                        if poolOffset + bytes.count > pool.byteCount {
                            // Rule J7: flush + recycle the pool.
                            flushCache(countStat: true)
                            poolOffset = 0
                        }
                        pool.beginWrite()
                        pool.write(bytes, at: poolOffset)
                        var nb = compiled.block
                        nb.poolOffset = poolOffset
                        poolOffset += bytes.count
                        cache[head] = nb
                        if cache.count == 1 {
                            codeLo = head
                            codeHi = head &+ UInt64(nb.byteLength)
                        } else {
                            if head < codeLo { codeLo = head }
                            let hi = head &+ UInt64(nb.byteLength)
                            if hi > codeHi { codeHi = hi }
                        }
                        stats.blocksCompiled += 1
                        block = nb
                    } else {
                        // Head not compilable (foreign instruction,
                        // decode fault, stack region) or an internal
                        // emitter failure: single-step it. Emitter
                        // failures degrade this head for the rest of
                        // the run (rule J7); a merely-foreign head
                        // costs one compile attempt per dispatch —
                        // it is reached again only after a flush or a
                        // block that ends before it, and J5 flushes
                        // follow every single-step anyway.
                        failedHeads.insert(head)
                    }
                }

                guard let blk = block else {
                    singleStep()
                    continue
                }

                // ---- Dispatch the block (design §5.3) ----
                let timerAllow: UInt64 = armed ? (cpu.memory.timerCount &- 1) : UInt64.max
                let budgetAllow = maxSteps &- stepsUsed
                let limit = min(UInt64(blk.instructionCount), timerAllow, budgetAllow)
                let limitKind: JitExitReason =
                    budgetAllow <= timerAllow ? .budgetLimit : .timerLimit
                statePtr.pointee.jitLimit = limit
                statePtr.pointee.limitReason = limitKind.rawValue
                statePtr.pointee.entryStatus = statePtr.pointee.status
                statePtr.pointee.codeLo = codeLo
                statePtr.pointee.codeHi = codeHi
                statePtr.pointee.lastDelta = 0

                pool.beginExecute()
                let fn = unsafeBitCast(pool.base + blk.poolOffset,
                                       to: JitBlockFunction.self)
                let reasonRaw = fn(UnsafeMutableRawPointer(statePtr))
                let reason = JitExitReason(rawValue: reasonRaw) ?? .next
                let delta = statePtr.pointee.lastDelta
                stats.blockEntries += 1
                stats.nativeInstructions += delta
                stepsUsed &+= delta
                // Settle the guest timer (design §5.3): every begun
                // instruction (delta includes a faulting one, and
                // excludes a bailed one) decremented the countdown
                // once in step()'s check. delta <= timerAllow when
                // armed, so this cannot underflow.
                if armed {
                    cpu.memory.timerCount &-= delta
                }
                statePtr.pointee.syncOut(to: cpu)
                cpu.jitSetStats(stats)

                switch reason {
                case .next:
                    if blk.endIsCap {
                        // Re-dispatch at endPc as a fresh head.
                        continue
                    }
                    // Block ended BEFORE a foreign instruction:
                    // single-step it unless the budget just ran out.
                    if stepsUsed < maxSteps && cpu.running {
                        singleStep()
                    }
                case .singleStep:
                    // Bail BEFORE the instruction at state.pc (the
                    // signed DIV/REM overflow pair): delta excluded
                    // it, so step() redoes its timer check + fetch.
                    singleStep()
                case .fault:
                    stats.faultExits += 1
                    // Rule J4: flush BEFORE handling the trap.
                    flushCache(countStat: true)
                    let trap = NovaTrap(rawValue: statePtr.pointee.exitAux) ?? .illegalInstruction
                    cpu.jitHandleTrapAfterStep(trap)
                    cpu.jitSetStats(stats)
                case .timerLimit:
                    stats.limitExits += 1
                    cpu.memory.timerCount = interval
                    stepsUsed &+= 1        // the firing pseudo-step (hotRun parity)
                    flushCache(countStat: true)
                    cpu.jitHandleTrapAfterStep(.timerInterrupt)
                    cpu.jitSetStats(stats)
                case .budgetLimit:
                    stats.limitExits += 1
                    finished = true         // running stays true: step-budget halt
                case .invalidated:
                    // STORL wrote into the cached-code interval
                    // (rule J1): drop the whole cache and
                    // re-dispatch at state.pc (already the next
                    // instruction; the store completed).
                    flushCache(countStat: true)
                    cpu.jitSetStats(stats)
                case .wfi:
                    // Not produced by J2 blocks (WFI is foreign and
                    // single-stepped); handled for contract totality.
                    cpu.running = false
                    finished = true
                }
            }
        }
        cpu.jitSetStats(stats)
        return true
#else
        _ = cpu
        _ = maxSteps
        return false
#endif
    }
}
