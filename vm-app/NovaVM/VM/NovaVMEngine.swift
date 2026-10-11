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
    private let memory: NovaMemory
    private var runThread: Thread?

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
    let memorySize: Int

    init(memorySize: Int = 64 * 1024 * 1024) {
        self.memorySize = memorySize
        self.memory = NovaMemory(totalSize: memorySize)
        cpu.memory = memory

        // Wire stack pointers
        resetCPUState()

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

    private func resetCPUState() {
        cpu.dsp = memory.dataStackBase
        cpu.csp = memory.callStackBase
        cpu.vsp = memory.vectorStackBase
        cpu.esp = memory.vectorStackBase - 1024*1024
        cpu.dslim = memory.dataStackBase - 8*1024*1024
        cpu.cslim = memory.callStackBase - 8*1024*1024
        cpu.eslim = cpu.esp - 1024*1024
        cpu.vslim = memory.vectorStackBase - 8*1024*1024
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
            memory.loadBytes(fw, at: 0)
            memory.loadBytes(data, at: 0x1000)
            cpu.pc = 0
        } else {
            memory.loadBytes(data, at: 0)
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
        runThread?.qualityOfService = .userInitiated
        runThread?.start()
    }

    func stop() {
        cpu.running = false
        isRunning = false
        statusLine = "Stopped"
    }

    func reset() {
        stop()
        resetCPUState()
        consoleText = ""
        statusLine = "Reset"
        snapshotRegisters()
    }
}
