// NovaVMEngine.swift — Ties CPU + memory together, runs on a background thread,
// streams console output to SwiftUI. Optimized: the run loop never touches
// the main thread except to publish console text.

import Foundation
import Combine

final class NovaVMEngine: ObservableObject {

    @Published var consoleText: String = ""
    /// Generation counter to invalidate stale thread completions after reboot.
    private var runGeneration = 0
    @Published var isRunning: Bool = false
    @Published var statusLine: String = "Idle"

    private let cpu = NovaCPU()
    var memory: NovaMemory
    private var runThread: Thread?
    /// Tracks the VM run thread so stop()/reboot() can wait for it to
    /// actually exit before resetting state. Without this, the old thread
    /// races the new one on CPU/memory state (caused stackUnderflow on
    /// reboot while a program was running).
    private let runGroup = DispatchGroup()

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

    // Program selection (shared across tabs). Tap again to deselect → nil.
    @Published var selectedProgramName: String?
    var selectedProgramData: Data?

    // Scheduler / VM tuning
    @Published var timerInterval: UInt64 = 100000  // scheduler timeslice, cycles
    @Published var programSlots: Int = 8           // max concurrent programs

    // Memory size chosen by user (default 64MB)
    var memorySize: Int

    init() {
        // Launch log for crash diagnosis (visible in Files app)
        Self.logLaunch("init start")
        // Set up the on-device folder structure first.
        NovaFolders.setup()
        NovaFirmware.refreshBuiltIn()
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

        // Wire up network MMIO handler: the app is the network "hardware".
        // Firmware drives it purely via MMIO (Nova machine code only).
        memory.netHandler = { [weak self] urlAddr, bufAddr, bufSize, cmd in
            return self?.handleNetGet(urlAddr: urlAddr, bufAddr: bufAddr, bufSize: bufSize, cmd: cmd) ?? -1
        }

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
            newMem.fileHandler = { [weak self] cmd, arg0, arg1, arg2 in
                return self?.handleFileCommand(cmd, arg0: arg0, arg1: arg1, arg2: arg2) ?? -1
            }
            newMem.netHandler = { [weak self] urlAddr, bufAddr, bufSize, cmd in
                return self?.handleNetGet(urlAddr: urlAddr, bufAddr: bufAddr, bufSize: bufSize, cmd: cmd) ?? -1
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
        // Scheduler timeslice (firmware may override via MMIO)
        memory.timerInterval = timerInterval
        memory.timerCount = timerInterval
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
    /// Network "hardware": blocking HTTP GET for the firmware's MMIO network device.
    /// Runs on the VM thread (like a syscall). Only http/https URLs are allowed.
    private func handleNetGet(urlAddr: UInt64, bufAddr: UInt64, bufSize: UInt64, cmd: UInt64) -> Int64 {
        // Read NUL-terminated URL from guest memory
        var urlBytes: [UInt8] = []
        var p = urlAddr
        for _ in 0..<2048 { // max URL length
            guard let b = try? memory.read8(p) else { break }
            if b == 0 { break }
            urlBytes.append(b)
            p += 1
        }
        guard let urlStr = String(bytes: urlBytes, encoding: .utf8),
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return -1 }
        let maxBytes = Int(min(bufSize, 1_000_000)) // cap at 1MB
        guard maxBytes > 0 else { return 0 }

        var request = URLRequest(url: url)
        request.timeoutInterval = (cmd == 2) ? 5 : 20
        request.setValue("NovaVM/1.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        // Use a box to avoid Swift 6 concurrency warnings on captured vars
        final class Box { var data: Data?; var error: Error? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, _, error in
            box.data = data
            box.error = error
            sem.signal()
        }.resume()
        // Wait up to ~25s (VM thread blocks like a syscall; UI stays responsive
        // only in that the main thread is untouched)
        guard sem.wait(timeout: .now() + ((cmd == 2) ? 6 : 25)) == .success,
              box.error == nil,
              let data = box.data else { return -1 }
        let n = min(data.count, maxBytes)
        for i in 0..<n {
            try? memory.write8(bufAddr + UInt64(i), data[i])
        }
        return Int64(n)
    }

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
        case 3: // WRITE: arg0=path addr (null-term), arg1=buffer addr, arg2=byte count → bytes written or -1
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
            for i in 0..<count {
                guard let b = try? memory.read8(bufAddr + UInt64(i)) else { break }
                bytes.append(b)
            }
            let url = shared.appendingPathComponent(filename)
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
        runGeneration += 1
        let gen = runGeneration
        isRunning = true
        statusLine = "Running"
        runGroup.enter()
        runThread = Thread { [weak self] in
            defer { self?.runGroup.leave() }
            self?.cpu.run()
            DispatchQueue.main.async { [weak self] in
                // Only update UI if this is still the current generation.
                // Prevents a stale thread from overwriting state after reboot.
                guard let self = self, self.runGeneration == gen else { return }
                self.isRunning = false
                self.statusLine = "Halted"
                self.snapshotRegisters()
            }
        }
        runThread?.name = "NOVA-VM"
        runThread?.qualityOfService = threadQoS
        runThread?.start()
    }

    func stop() {
        cpu.running = false
        // Wait for the VM thread to actually exit before we touch
        // CPU/memory state. Prevents reboot races.
        _ = runGroup.wait(timeout: .now() + 2.0)
        runThread = nil
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

    /// Completely reboot the VM: reset CPU, reload firmware, clear console, and start.
    /// Use this when the VM is halted and you want a fresh boot.
    func reboot() {
        stop()
        // Clear any pending input and timer state from the old session.
        // Prevents stale keys/timer from corrupting the fresh boot.
        memory.clearKeyboardQueue()
        memory.timerVector = 0
        memory.timerCount = 0
        resetCPUState()
        // Reload firmware bytes into memory at 0x0
        if useFirmware {
            let fwData: Data?
            if useCustomFirmware, let custom = customFirmwareData {
                fwData = custom
            } else {
                fwData = NovaFirmware.defaultImage
            }
            if let fw = fwData {
                for i in 0..<fw.count {
                    try? memory.write8(UInt64(i), fw[i])
                }
            }
        }
        consoleText = ""
        statusLine = "Rebooting..."
        snapshotRegisters()
        // Start the VM
        start()
    }

    /// Boot for the Run tab: load firmware (or run a program directly if
    /// firmware is off), then auto-run the selected program via the shell's
    /// `run` command. Works with NO program selected (boots shell only).
    func boot() {
        stop()
        resetCPUState()
        if useFirmware {
            let fwData: Data?
            if useCustomFirmware, let custom = customFirmwareData {
                fwData = custom
            } else {
                fwData = NovaFirmware.defaultImage
            }
            if let fw = fwData {
                try? memory.loadBytes(fw, at: 0)
            }
            consoleText = ""
            statusLine = "Booting NovaShell..."
            start()
            // NOTE: No auto-run. The user types `run <file>` manually.
            // The old auto-typing raced with manual input and corrupted it.
        } else if let progData = selectedProgramData {
            // No firmware: run the program binary directly at 0x0.
            try? memory.loadBytes(progData, at: 0)
            cpu.pc = 0
            consoleText = ""
            statusLine = "Running program directly..."
            start()
        } else {
            consoleText = "No firmware and no program selected.\nEnable firmware or pick a program first."
            statusLine = "Idle"
        }
    }

    /// Copy the selected program into sharedDir so the firmware's `run`
    /// command (which reads via file MMIO from sharedDir) can find it.
    private func ensureProgramInSharedDir(_ name: String) {
        let dest = NovaFolders.sharedDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        if let data = selectedProgramData {
            try? data.write(to: dest)
        } else {
            let src = NovaFolders.programsDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: src) {
                try? data.write(to: dest)
            }
        }
    }
}
