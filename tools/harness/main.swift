// main.swift — nova-harness: headless NOVA VM runner for golden-baseline testing.
//
// Compiles with ONLY the VM core (NovaCPU.swift + NovaMemory.swift) — the core
// is Foundation-only and references no app/engine/config types, so NO shim is
// needed. This file re-implements, line for line where it matters, the boot
// sequence of NovaVMEngine (vm-app/NovaVM/VM/NovaVMEngine.swift):
//
//   * 64 MB guest RAM (NovaConfig.default ramMB) via NovaMemory(totalSize:)
//   * resetCPUState(): dsp/csp/vsp/esp + limits from the memory layout,
//     fp = 0, pc = 0, status = (3 << 2) | 1  (machine privilege, IRQs on)
//   * loadProgram(): firmware at 0x0 + program at 0x1000 when --firmware is
//     given; otherwise the program is loaded at --load-addr and entered there
//     (the app's no-firmware boot() path loads at 0x0; generated binaries that
//     were built for a fixed load address pass it explicitly).
//   * Console: guest bytes arrive through memory.consoleOutput exactly as in
//     the app and are written RAW to --console-out (the app's "[TRAP ...]"
//     UI annotation is NOT guest output and is recorded in the meta file
//     instead — see README.md).
//   * Traps: a trapHandler is installed that records (trap, tval) and stops
//     the CPU, mirroring NovaVMEngine's handler (which also halts the VM).
//   * File MMIO: with --sandbox <dir>, a handler with the engine's exact
//     semantics (LIST/READ/WRITE, ".."/"/" path rejection, same clamps).
//     Without --sandbox no handler is installed and file commands return -1,
//     which is NovaMemory's own default.
//   * Network MMIO: always returns -1 (offline). The app performs real HTTP,
//     which is non-deterministic and therefore unusable for goldens.
//   * Timer: --timer-interval N arms the hardware timer exactly like the
//     engine's resetCPUState() (which uses 100000). Default is 0 (disabled)
//     in bare mode — see README.md "Boot replication decisions" for why —
//     and 100000 in --firmware mode (the firmware installs its own vector
//     and re-programs the interval via MMIO anyway).
//   * Keyboard: --input / --input-hex / --input-file bytes are pushed into
//     memory's keyboard queue before the run (memory.pushKey), the same
//     queue the app's UI feeds.
//
// Exit status: 0 = the run completed (a guest trap is DATA, recorded in the
// meta file, not a harness failure). 2 = usage / IO error.

import Foundation

// MARK: - Small helpers

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func die(_ s: String) -> Never {
    eprint("nova-harness: " + s)
    exit(2)
}

func parseNum(_ s: String) -> UInt64 {
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        guard let v = UInt64(s.dropFirst(2), radix: 16) else { die("bad number: \(s)") }
        return v
    }
    guard let v = UInt64(s) else { die("bad number: \(s)") }
    return v
}

func loadFile(_ path: String) -> Data {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        die("cannot read file: \(path)")
    }
    return d
}

// MARK: - Arguments

var programPath: String? = nil
var firmwarePath: String? = nil
var loadAddr: UInt64 = 0
var loadAddrSet = false
var entryArg: UInt64? = nil
var r15Init: UInt64? = nil
var maxSteps: UInt64 = 10_000_000
var ramMB: UInt64 = 64
var timerArg: UInt64? = nil
var inputText: String? = nil
var inputHex: String? = nil
var inputFile: String? = nil
var sandboxPath: String? = nil
var consoleOutPath: String? = nil
var metaOutPath: String? = nil
var engineArg: String = "interpreter"

let argv = CommandLine.arguments
var ai = 1
func nextVal(_ flag: String) -> String {
    ai += 1
    guard ai < argv.count else { die("missing value for \(flag)") }
    return argv[ai]
}
while ai < argv.count {
    let a = argv[ai]
    switch a {
    case "--program": programPath = nextVal(a)
    case "--firmware": firmwarePath = nextVal(a)
    case "--load-addr": loadAddr = parseNum(nextVal(a)); loadAddrSet = true
    case "--entry": entryArg = parseNum(nextVal(a))
    case "--r15": r15Init = parseNum(nextVal(a))
    case "--steps": maxSteps = parseNum(nextVal(a))
    case "--ram-mb": ramMB = parseNum(nextVal(a))
    case "--timer-interval": timerArg = parseNum(nextVal(a))
    case "--input": inputText = nextVal(a)
    case "--input-hex": inputHex = nextVal(a)
    case "--input-file": inputFile = nextVal(a)
    case "--sandbox": sandboxPath = nextVal(a)
    case "--console-out": consoleOutPath = nextVal(a)
    case "--meta-out": metaOutPath = nextVal(a)
    case "--engine": engineArg = nextVal(a)
    case "--help":
        print("usage: nova-harness --program P.bin [--firmware F.bin] [--load-addr N] [--entry N] [--r15 N] [--steps N] [--ram-mb N] [--timer-interval N] [--input TEXT] [--input-hex HEX] [--input-file F] [--sandbox DIR] [--engine interpreter|jit] --console-out FILE --meta-out FILE")
        exit(0)
    default:
        die("unknown argument: \(a)")
    }
    ai += 1
}

guard let consoleOut = consoleOutPath else { die("--console-out is required") }
guard let metaOut = metaOutPath else { die("--meta-out is required") }
guard programPath != nil || firmwarePath != nil else { die("--program or --firmware is required") }
guard ramMB >= 64 && ramMB <= 1024 else { die("--ram-mb must be in [64, 1024]") }

// MARK: - VM construction (mirrors NovaVMEngine.init)

guard engineArg == "interpreter" || engineArg == "jit" else {
    die("--engine must be interpreter or jit")
}

let memory = NovaMemory(totalSize: Int(ramMB) * 1024 * 1024)
let cpu = NovaCPU()
cpu.memory = memory

// Engine selection (v0.0.71 J1, design §7.1): default interpreter —
// every pre-J1 invocation is byte-unchanged. The JIT hooks exist
// only in the variants/jit core, so JIT-specific code is compiled
// only when run.sh defines NOVA_JIT_ENGINE (it does so exactly when
// the variant dir carries NovaJIT.swift). Asking a non-JIT binary
// for the JIT engine is a usage error, never a silent fallback.
if engineArg == "jit" {
#if NOVA_JIT_ENGINE
    cpu.requestedEngine = .jit
#else
    die("--engine jit requires a harness built from the JIT variant core (variants/jit)")
#endif
}

// Console capture: raw guest bytes. NovaMemory assembles complete UTF-8
// sequences before calling this, exactly as it does for the app; a trailing
// partial sequence at halt is dropped by NovaMemory in both cases.
var consoleBytes: [UInt8] = []
memory.consoleOutput = { s in
    consoleBytes.append(contentsOf: s.utf8)
}

// Network "hardware": offline. Deterministic -1 for every request.
memory.netHandler = { _, _, _, _ in
    return -1
}

// File "hardware": only when a sandbox directory is given. Semantics copied
// from NovaVMEngine.handleFileCommand (same clamps, same path rejection).
if let sandbox = sandboxPath {
    let sharedDir = URL(fileURLWithPath: sandbox, isDirectory: true)
    memory.fileHandler = { cmd, arg0, arg1, arg2 in
        switch cmd {
        case 1: // LIST: arg0=buffer addr, arg1=buffer size -> bytes written
            let bufAddr = arg0
            let bufSize = Int(min(arg1, 1_000_000))
            guard bufSize > 0 else { return 0 }
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: sharedDir.path) else { return -1 }
            var offset = 0
            for name in names.sorted() {
                let bytes = Array(name.utf8) + [0]
                guard offset + bytes.count <= bufSize else { break }
                for (k, b) in bytes.enumerated() {
                    try? memory.write8(bufAddr + UInt64(offset + k), b)
                }
                offset += bytes.count
            }
            return Int64(offset)
        case 2: // READ: arg0=path addr, arg1=buffer addr, arg2=buffer size
            let pathAddr = arg0, bufAddr = arg1
            let bufSize = Int(min(arg2, 10_000_000))
            guard bufSize > 0 else { return 0 }
            var pathBytes: [UInt8] = []
            var p = pathAddr
            for _ in 0..<256 {
                guard let b = try? memory.read8(p) else { break }
                if b == 0 { break }
                pathBytes.append(b)
                p += 1
            }
            guard let filename = String(bytes: pathBytes, encoding: .utf8),
                  !filename.contains(".."), !filename.contains("/") else { return -1 }
            let url = sharedDir.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { return -1 }
            let n = min(data.count, bufSize)
            for k in 0..<n {
                try? memory.write8(bufAddr + UInt64(k), data[k])
            }
            return Int64(n)
        case 3: // WRITE: arg0=path addr, arg1=buffer addr, arg2=byte count
            let pathAddr = arg0, bufAddr = arg1
            let count = Int(min(arg2, 10_000_000))
            guard count >= 0 else { return -1 }
            var pathBytes: [UInt8] = []
            var p = pathAddr
            for _ in 0..<256 {
                guard let b = try? memory.read8(p) else { break }
                if b == 0 { break }
                pathBytes.append(b)
                p += 1
            }
            guard let filename = String(bytes: pathBytes, encoding: .utf8),
                  !filename.contains(".."), !filename.contains("/") else { return -1 }
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for k in 0..<count {
                guard let b = try? memory.read8(bufAddr + UInt64(k)) else { break }
                bytes.append(b)
            }
            let url = sharedDir.appendingPathComponent(filename)
            do {
                try Data(bytes).write(to: url, options: .atomic)
                return Int64(bytes.count)
            } catch {
                return -1
            }
        default:
            return -1
        }
    }
}

// Trap capture: mirrors the engine's trapHandler, which records the trap and
// stops the CPU (cpu.running = false). Timed/vectored traps (timer interrupt
// or ECALL with a firmware vector installed) never reach this handler —
// NovaCPU.run() vectors them internally, exactly as on device.
var trapDesc: String? = nil
var trapRaw: UInt64 = 0
var trapTval: UInt64 = 0
cpu.trapHandler = { trap, tval in
    trapDesc = "\(trap)"
    trapRaw = trap.rawValue
    trapTval = tval
    cpu.running = false
}

// MARK: - resetCPUState() (mirrors NovaVMEngine.resetCPUState)

let timerEffective: UInt64 = timerArg ?? (firmwarePath != nil ? 100000 : 0)
cpu.dsp = memory.dataStackBase
cpu.csp = memory.callStackBase
cpu.vsp = memory.vectorStackBase
cpu.esp = memory.vectorStackBase &- 1024 * 1024
cpu.dslim = memory.dataStackBase &- 8 * 1024 * 1024
cpu.cslim = memory.callStackBase &- 8 * 1024 * 1024
cpu.eslim = cpu.esp &- 1024 * 1024
cpu.vslim = memory.vectorStackBase &- 8 * 1024 * 1024
cpu.fp = 0
cpu.pc = 0
cpu.status = (3 << 2) | 1
memory.timerInterval = timerEffective
memory.timerCount = timerEffective

// MARK: - Loading (mirrors NovaVMEngine.loadProgram / boot)

if let fwPath = firmwarePath {
    let fw = loadFile(fwPath)
    do { try memory.loadBytes(fw, at: 0) } catch { die("firmware load failed") }
    if !loadAddrSet { loadAddr = 0x1000 } // engine: program goes to 0x1000
}
var entry: UInt64 = 0
if let progPath = programPath {
    let prog = loadFile(progPath)
    guard prog.count < memory.totalSize / 2 else { die("program too large") }
    do { try memory.loadBytes(prog, at: loadAddr) } catch { die("program load failed") }
    entry = entryArg ?? loadAddr
} else {
    entry = entryArg ?? 0
}
cpu.pc = entry
// Scheduler-context register: NovaShell's `run` restores a process slot whose
// R15 holds the program's load address (see gen_galaxy.py in nova-programs:
// "R15 = load address (firmware sets it)"). Set only when explicitly asked.
if let r15 = r15Init {
    cpu.regs[15] = r15
}

// MARK: - Scripted keyboard input (same queue the app UI feeds)

var inputBytes: [UInt8] = []
if let t = inputText { inputBytes.append(contentsOf: t.utf8) }
if let h = inputHex {
    var idx = h.startIndex
    while idx < h.endIndex {
        let nxt = h.index(idx, offsetBy: 2, limitedBy: h.endIndex) ?? h.endIndex
        guard let b = UInt8(h[idx..<nxt], radix: 16) else { die("bad --input-hex") }
        inputBytes.append(b)
        idx = nxt
    }
}
if let f = inputFile { inputBytes.append(contentsOf: loadFile(f)) }
for b in inputBytes { memory.pushKey(b) }

// MARK: - Run

cpu.run(maxSteps: maxSteps)

// JIT probe/engine report (J1): extra meta lines + a stderr line,
// ONLY when --engine jit was given (and only compilable in JIT
// builds). The probe ran at run() entry (design §2.2); lastProbe
// records which allocation path won or why JIT is unavailable.
// Default (interpreter) runs gain no lines anywhere — meta, stdout
// and stderr are byte-identical to pre-J1 harness builds.
var metaSuffix = ""
#if NOVA_JIT_ENGINE
if engineArg == "jit" {
    let probeLabel = NovaJIT.lastProbe.label
    let activeLabel = cpu.activeEngine.label
    eprint("nova-harness: engine=jit probe=\(probeLabel) active=\(activeLabel)")
    metaSuffix = "engine_requested=jit\nengine_active=\(activeLabel)\njit_probe=\(probeLabel)\n"
}
#endif

// MARK: - Halt classification
//
// NovaCPU.run() gives no return value, so the reason is reconstructed from
// observable state, in priority order:
//   * trap handler fired            -> "trap:<case> tval=0x.."
//     (illegalInstruction included: "trap:illegalInstruction tval=0x..")
//   * cpu.running still true        -> the step budget stopped the loop
//   * otherwise                       -> WFI (0xC5) is the only instruction
//     that clears `running` from inside step().
let halt: String
if let t = trapDesc {
    halt = "trap:\(t) tval=0x\(String(trapTval, radix: 16))"
} else if cpu.running {
    halt = "step-budget"
} else {
    halt = "wfi"
}

// MARK: - Outputs

do {
    try Data(consoleBytes).write(to: URL(fileURLWithPath: consoleOut))
} catch {
    die("cannot write console output: \(consoleOut)")
}
let meta = """
cycles=\(cpu.cycle)
halt=\(halt)
trap_raw=\(trapRaw)
steps_budget=\(maxSteps)
console_bytes=\(consoleBytes.count)
pc=0x\(String(cpu.pc, radix: 16))
"""
do {
    try Data((meta + "\n" + metaSuffix).utf8).write(to: URL(fileURLWithPath: metaOut))
} catch {
    die("cannot write meta output: \(metaOut)")
}
print("\(halt) cycles=\(cpu.cycle) console_bytes=\(consoleBytes.count)")
exit(0)
