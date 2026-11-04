// NovaJIT.swift — NOVA v0.0.71 Phase 2 JIT engine (harness variant "jit").
//
// Lane J1 — SCAFFOLDING ONLY. This file contains:
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
//     (NovaJIT.runTrampoline). In J1 it compiles ZERO blocks and
//     declines every run, so every run routes to the shipped hotloop
//     interpreter and guest-visible behaviour is bit-identical to it.
//
// NO guest-instruction codegen exists in this lane (that is J2–J4).
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
/// raw value. No blocks exist in J1; the type is the contract J2
/// will emit against.
typealias JitBlockFunction = @convention(c) (UnsafeMutableRawPointer) -> UInt64

// MARK: - Engine indicator surface (design §2.3)

/// What the host asked for. Setting `.jit` never guarantees JIT runs;
/// `NovaCPU.activeEngine` reports what a run actually used.
enum NovaEnginePreference {
    case interpreter
    case jit
}

/// What a run actually used. `.jit` is only ever reported for a run
/// the JIT trampoline really drove (never in J1: zero blocks).
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

/// JIT counters for a diagnostics surface (design §2.3). All zero in
/// J1 — no blocks are compiled, entered, invalidated or single-stepped
/// by the JIT; interpreter steps driven by hotloop are NOT counted
/// here (these counters describe JIT activity only).
struct JitStats {
    var blocksCompiled: UInt64 = 0
    var blockEntries: UInt64 = 0
    var invalidations: UInt64 = 0
    var singleSteps: UInt64 = 0
    var faultExits: UInt64 = 0
    var limitExits: UInt64 = 0
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
    /// J1: zero blocks are compiled — there is no emitter, no block
    /// cache and no generated code — so this ALWAYS declines. That
    /// is the zero-codegen gate: with the JIT engine selected, every
    /// instruction still executes in the interpreter.
    static func runTrampoline(cpu: NovaCPU, maxSteps: UInt64) -> Bool {
        _ = cpu
        _ = maxSteps
        return false
    }
}
