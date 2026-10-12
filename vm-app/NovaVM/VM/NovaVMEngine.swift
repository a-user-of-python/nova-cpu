// NovaVMEngine.swift — Ties CPU + memory together, runs on a background thread,
// streams console output to SwiftUI. Optimized: the run loop never touches
// the main thread except to publish console text.

import Foundation
import Combine

final class NovaVMEngine: ObservableObject {

    @Published var consoleText: String = ""
    @Published var isRunning: Bool = false
    @Published var statusLine: String = "Idle"

    private let cpu = NovaCPU()
    private var memory: NovaMemory
    private var runThread: Thread?

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

        // Wire stack pointers
        resetCPUState()
        Self.logLaunch("cpu state ok")

        // Trap handler: report and halt
        cpu.trapHandler = { [weak self] trap, tval in
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

    func start() {
        guard !cpu.running else { return }
        isRunning = true
        statusLine = "Running"
        runThread = Thread { [weak self] in
            self?.cpu.run()
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
