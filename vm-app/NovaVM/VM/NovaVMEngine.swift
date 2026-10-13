// NovaVMEngine.swift — Ties CPU + memory together, runs on a background thread,
// streams console output to SwiftUI. Optimized: the run loop never touches
// the main thread except to publish console text.

import Foundation
import Combine

/// Full CPU context for scheduler context switches.
struct CPUContext {
    var regs: [UInt64] = Array(repeating: 0, count: 16)
    var pc: UInt64 = 0
    var dsp: UInt64 = 0
    var csp: UInt64 = 0
    var esp: UInt64 = 0
    var vsp: UInt64 = 0
    var fp: UInt64 = 0
    var status: UInt64 = 0
    var cause: UInt64 = 0
    var epc: UInt64 = 0
    var tval: UInt64 = 0
    var satp: UInt64 = 0
    var dslim: UInt64 = 0
    var cslim: UInt64 = 0
    var eslim: UInt64 = 0
    var vslim: UInt64 = 0
    var cycle: UInt64 = 0
    var flagN: Bool = false
    var flagZ: Bool = false
    var flagC: Bool = false
    var flagV: Bool = false
}

/// Process slot for the 2-program scheduler.
/// NOTE: Firmware (NovaShell) is NOT a program and does NOT occupy a slot.
/// The 2-slot limit applies to user programs only.
struct ProcessSlot {
    var inUse: Bool = false
    var name: String = ""
    var loadAddr: UInt64 = 0
    var ctx: CPUContext = CPUContext()
}

final class NovaVMEngine: ObservableObject {

    @Published var consoleText: String = ""
    @Published var isRunning: Bool = false
    @Published var statusLine: String = "Idle"

    private let cpu = NovaCPU()
    var memory: NovaMemory
    private var runThread: Thread?

    // Scheduler: max 2 concurrent programs (user requirement).
    var procSlots: [ProcessSlot] = [ProcessSlot(), ProcessSlot()]
    private var currentSlot: Int = 0

    // Live configuration (from NOVA/config.nova)
    @Published var config: NovaConfig

    // Register snapshot for the viewer (updated when halted — safe, no data race)
    @Published var regSnapshot: [UInt64] = Array(repeating: 0, count: 16)
    @Published var spSnapshot: (dsp: UInt64, csp: UInt64, pc: UInt64, fp: UInt64) = (0, 0, 0, 0)

    // Firmware toggle
    @Published var useFirmware: Bool = true
    @Published var useCustomFirmware: Bool = false
    // Firmware bytes are copied at pick time (security-scoped URLs expire).
    var customFirmwareData: Data?
    var customFirmwareName: String?

    // Memory size chosen by user (default 64MB)
    var memorySize: Int

    init() {
        // Launch log for crash diagnosis (visible in Files app)
        Self.logLaunch("init start")
        // Set up the on-device folder structure first.
        NovaFolders.setup()
        Self.logLaunch("folders ok")
        let cfg = NovaFolders.loadOrCreateConfig()
        Self.logLaunch("config ok: \(cfg.ramMB)MB")
        self.config = cfg
        let ramBytes = cfg.ramMB * 1024 * 1024
        self.memorySize = ramBytes
        Self.logLaunch("allocating \(ramBytes) bytes")
        self.memory = NovaMemory(totalSize: ramBytes)
        Self.logLaunch("memory ok")
        cpu.memory = memory

        // Wire up file MMIO handler for firmware (NovaShell)
        memory.fileHandler = { [weak self] cmd, arg0, arg1, arg2 in
            return self?.handleFileCommand(cmd, arg0: arg0, arg1: arg1, arg2: arg2) ?? -1
        }

        // Wire stack pointers
        resetCPUState()
        Self.logLaunch("cpu state ok")

        // Trap handler: report and halt, EXCEPT for timer interrupts.
        // Timer interrupts are hardware behavior for the firmware scheduler:
        // the CPU vectors to the firmware's timer handler (set via MMIO timerVector).
        // The app does not control scheduling; it only emulates the hardware.
        cpu.trapHandler = { [weak self] trap, tval in
            if trap == .timerInterrupt {
                // Hardware timer interrupt: vector to firmware handler.
                // Save the interrupted PC in epc, set cause, jump to timerVector.
                // Do NOT halt; the firmware's scheduler takes over.
                guard let self = self else { return }
                self.cpu.epc = self.cpu.pc
                self.cpu.cause = 17  // Timer interrupt cause
                let vec = self.memory.timerVector
                if vec != 0 {
                    self.cpu.pc = vec
                } else {
                    // No handler set: halt (firmware hasn't set up scheduler yet).
                    self.cpu.running = false
                }
                // Do not halt (unless no vector), do not print. Firmware is in charge.
                return
            }
            // Other traps: report and halt (as before).
            DispatchQueue.main.async {
                self?.consoleText += "\n[TRAP \(trap) tval=0x\(String(tval, radix: 16))]\n"
                self?.isRunning = false
                self?.statusLine = "Trapped: \(trap)"
                self?.snapshotRegisters()
            }
            self?.cpu.running = false
        }

        // Console output → published string (batched)
        memory.consoleOutput = { [weak self] s in
            DispatchQueue.main.async {
                self?.consoleText += s
                // Cap console at ~100k chars
                if let t = self?.consoleText, t.count > 100_000 {
                    self?.consoleText = String(t.suffix(90_000))
                }
            }
        }
    }

    /// Writes to NOVA/launch.log in Documents (visible in Files app).
    /// Static so it can be called before all properties are initialized.
    private static func logLaunch(_ msg: String) {
        let url = NovaFolders.root.appendingPathComponent("launch.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let fh = try? FileHandle(forWritingTo: url) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Apply a new configuration: persist to config.nova, rebuild guest RAM
    /// if the size changed, and re-tune the VM thread.
    func applyConfig(_ cfg: NovaConfig) {
        var c = cfg
        let info = DeviceInfo.current
        c.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
        NovaFolders.save(c)
        let ramBytes = c.ramMB * 1024 * 1024
        if ramBytes != memorySize {
            // Rebuild memory — requires app restart for full effect on some paths,
            // but we swap it live here.
            let newMem = NovaMemory(totalSize: ramBytes)
            newMem.consoleOutput = memory.consoleOutput
            newMem.fileHandler = { [weak self] cmd, arg0, arg1, arg2 in
                return self?.handleFileCommand(cmd, arg0: arg0, arg1: arg1, arg2: arg2) ?? -1
            }
            self.memory = newMem
            cpu.memory = newMem
            self.memorySize = ramBytes
        }
        self.config = c
        // Sync firmware toggle with config file
        useFirmware = true
        useCustomFirmware = c.firmware.lowercased() != "default"
        resetCPUState()
        statusLine = "Config applied (\(c.ramMB) MB, \(c.cpuCores) cores)"
    }

    /// Thread QoS derived from the P/E core preference.
    /// P-heavy → userInteractive; balanced → userInitiated; E-heavy → utility.
    private var threadQoS: QualityOfService {
        let total = max(1, config.pCores + config.eCores)
        let pRatio = Double(config.pCores) / Double(total)
        if pRatio >= 0.66 { return .userInteractive }
        if pRatio >= 0.33 { return .userInitiated }
        return .utility
    }

    private func resetCPUState() {
        // Use wrapping arithmetic to avoid traps on unexpected layouts;
        // NovaMemory guarantees the layout fits within the allocation.
        cpu.dsp = memory.dataStackBase
        cpu.csp = memory.callStackBase
        cpu.vsp = memory.vectorStackBase
        cpu.esp = memory.vectorStackBase &- 1024*1024
        cpu.dslim = memory.dataStackBase &- 8*1024*1024
        cpu.cslim = memory.callStackBase &- 8*1024*1024
        cpu.eslim = cpu.esp &- 1024*1024
        cpu.vslim = memory.vectorStackBase &- 8*1024*1024
        cpu.fp = 0
        cpu.pc = 0
        // Machine privilege, interrupts on
        cpu.status = (3 << 2) | 1
    }

    /// Load a program binary. If firmware is enabled, program goes to 0x1000
    /// and firmware runs first; otherwise program runs from 0x0.
    func loadProgram(_ data: Data) throws {
        guard data.count < memorySize / 2 else { throw NovaError.programTooLarge }
        // Stop any running VM first. Without this, the old firmware/program
        // keeps running in the background: the new load never takes effect,
        // Run appears to do nothing, and the firmware seems "stuck".
        cpu.running = false
        isRunning = false
        if useFirmware {
            let fw: Data
            if useCustomFirmware, let custom = customFirmwareData {
                fw = custom
            } else {
                fw = NovaFirmware.defaultImage
            }
            // Firmware at 0x0, program at 0x1000
            try memory.loadBytes(fw, at: 0)
            try memory.loadBytes(data, at: 0x1000)
            cpu.pc = 0
        } else {
            try memory.loadBytes(data, at: 0)
            cpu.pc = 0
        }
        resetCPUState()
        DispatchQueue.main.async {
            self.consoleText = ""
            self.statusLine = "Program loaded (\(data.count) bytes)"
        }
    }

    /// Snapshot all programmer-visible registers. Call only when halted.
    func snapshotRegisters() {
        regSnapshot = cpu.regs
        spSnapshot = (cpu.dsp, cpu.csp, cpu.pc, cpu.fp)
    }

    // MARK: - Firmware File MMIO

    /// Handle file commands from firmware. Runs on VM thread — keep it fast and safe.
    /// cmd 1 = LIST: arg0=buffer addr, arg1=buffer size → returns bytes written
    /// cmd 2 = READ: arg0=path addr (null-term), arg1=buffer addr, arg2=buffer size → returns bytes read or -1
    private func handleFileCommand(_ cmd: UInt64, arg0: UInt64, arg1: UInt64, arg2: UInt64) -> Int64 {
        let shared = NovaFolders.sharedDir
        switch cmd {
        case 1: // LIST
            let bufAddr = arg0
            // Safe conversion: clamp to reasonable max to avoid Int overflow trap
            let bufSize = Int(min(arg1, 1_000_000))
            guard bufSize > 0 else { return 0 }
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: shared.path) else { return -1 }
            var offset = 0
            for name in names.sorted() {
                let bytes = Array(name.utf8) + [0] // null-terminated
                guard offset + bytes.count <= bufSize else { break }
                for (i, b) in bytes.enumerated() {
                    try? memory.write8(bufAddr + UInt64(offset + i), b)
                }
                offset += bytes.count
            }
            return Int64(offset)
        case 2: // READ
            let pathAddr = arg0, bufAddr = arg1
            let bufSize = Int(min(arg2, 10_000_000)) // clamp to 10MB max
            guard bufSize > 0 else { return 0 }
            // Read null-terminated path from guest memory
            var pathBytes: [UInt8] = []
            var p = pathAddr
            for _ in 0..<256 { // max path len
                guard let b = try? memory.read8(p) else { break }
                if b == 0 { break }
                pathBytes.append(b)
                p += 1
            }
            guard let filename = String(bytes: pathBytes, encoding: .utf8),
                  !filename.contains(".."), !filename.contains("/") else { return -1 }
            let url = shared.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { return -1 }
            let n = min(data.count, bufSize)
            for i in 0..<n {
                try? memory.write8(bufAddr + UInt64(i), data[i])
            }
            return Int64(n)
        default:
            return -1
        }
    }

    /// Live register updates while running (4x/sec). Only active when panel visible.
    var liveUpdateTimer: Timer?
    var liveUpdatesEnabled = false

    func startLiveUpdates() {
        liveUpdatesEnabled = true
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.liveUpdatesEnabled else { return }
            // Snapshot on main thread (cpu.regs is simple array copy)
            self.regSnapshot = self.cpu.regs
            self.spSnapshot = (self.cpu.dsp, self.cpu.csp, self.cpu.pc, self.cpu.fp)
        }
    }

    func stopLiveUpdates() {
        liveUpdatesEnabled = false
        liveUpdateTimer?.invalidate()
        liveUpdateTimer = nil
    }

    // MARK: - Scheduler (2 user programs max, firmware not counted)

    /// Save current CPU state into a context.
    private func saveContext(_ ctx: inout CPUContext) {
        ctx.regs = cpu.regs
        ctx.pc = cpu.pc
        ctx.dsp = cpu.dsp
        ctx.csp = cpu.csp
        ctx.esp = cpu.esp
        ctx.vsp = cpu.vsp
        ctx.fp = cpu.fp
        ctx.status = cpu.status
        ctx.cause = cpu.cause
        ctx.epc = cpu.epc
        ctx.tval = cpu.tval
        ctx.satp = cpu.satp
        ctx.dslim = cpu.dslim
        ctx.cslim = cpu.cslim
        ctx.eslim = cpu.eslim
        ctx.vslim = cpu.vslim
        ctx.cycle = cpu.cycle
        ctx.flagN = cpu.flagN
        ctx.flagZ = cpu.flagZ
        ctx.flagC = cpu.flagC
        ctx.flagV = cpu.flagV
    }

    /// Restore CPU state from a context.
    private func restoreContext(_ ctx: CPUContext) {
        cpu.regs = ctx.regs
        cpu.pc = ctx.pc
        cpu.dsp = ctx.dsp
        cpu.csp = ctx.csp
        cpu.esp = ctx.esp
        cpu.vsp = ctx.vsp
        cpu.fp = ctx.fp
        cpu.status = ctx.status
        cpu.cause = ctx.cause
        cpu.epc = ctx.epc
        cpu.tval = ctx.tval
        cpu.satp = ctx.satp
        cpu.dslim = ctx.dslim
        cpu.cslim = ctx.cslim
        cpu.eslim = ctx.eslim
        cpu.vslim = ctx.vslim
        cpu.cycle = ctx.cycle
        cpu.flagN = ctx.flagN
        cpu.flagZ = ctx.flagZ
        cpu.flagC = ctx.flagC
        cpu.flagV = ctx.flagV
    }

    /// Shell context (firmware, not counted as a program).
    private var shellCtx = CPUContext()
    private var shellActive = true

    func start() {
        guard !cpu.running else { return }
        isRunning = true
        statusLine = "Running"
        runThread = Thread { [weak self] in
            self?.schedulerLoop()
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.statusLine = "Halted"
                self?.snapshotRegisters()
            }
        }
        runThread?.name = "NOVA-VM"
        runThread?.qualityOfService = threadQoS
        runThread?.start()
    }

    /// Scheduler loop: round-robin between shell and active program slots.
    /// Firmware (shell) is not counted in the 2-program limit.
    private func schedulerLoop() {
        cpu.running = true
        // Save initial shell context
        saveContext(&shellCtx)
        shellActive = true

        while cpu.running {
            // Check if any programs are active
            let activeSlots = procSlots.indices.filter { procSlots[$0].inUse }

            if activeSlots.isEmpty {
                // No programs: run shell until it halts or a program is started.
                // The shell will send PROC_RUN via MMIO, which sets a flag.
                // For now, just run the shell.
                cpu.run(maxSteps: 100000)
                // If cpu.running is false, the shell halted. Exit loop.
                if !cpu.running { break }
                // Otherwise, continue (shell is waiting for input, will poll).
            } else {
                // Time-slice: shell -> prog0 -> prog1 -> shell ...
                // Run shell for a bit (handles input)
                if shellActive {
                    restoreContext(shellCtx)
                }
                cpu.run(maxSteps: 20000)
                if !cpu.running { break }
                saveContext(&shellCtx)

                // Run each active program
                for idx in activeSlots {
                    // Save shell, restore program
                    restoreContext(procSlots[idx].ctx)
                    cpu.run(maxSteps: 50000)
                    if !cpu.running { break }
                    // Save program state
                    saveContext(&procSlots[idx].ctx)
                    // Check if program halted (e.g., via TRAP or exit)
                    // For now, assume it continues. A halt would set cpu.running=false.
                }
                if !cpu.running { break }
            }
        }
        cpu.running = false
    }

    func stop() {
        cpu.running = false
        isRunning = false
        statusLine = "Stopped"
        snapshotRegisters()
    }

    func reset() {
        stop()
        resetCPUState()
        consoleText = ""
        statusLine = "Reset"
        snapshotRegisters()
    }
}
