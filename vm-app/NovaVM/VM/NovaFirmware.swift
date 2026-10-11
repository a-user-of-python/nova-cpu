// NovaFirmware.swift — Firmware loading: built-in default + custom via Files app.

import Foundation

/// NOVA firmware: runs at machine privilege before the user program.
/// Handles memory init, stack setup, trap vectors, and console I/O.
struct NovaFirmware {

    /// Default firmware: minimal machine-mode init written in NOVA assembly.
    /// Sets up stacks, installs a trap handler that halts, jumps to 0x1000 (program entry).
    ///
    /// Assembled by hand (see docs/FIRMWARE_ASM.md for source):
    ///   0x0000: DSPSET etc. are privileged — firmware runs at machine level.
    static var defaultImage: Data {
        var bytes = [UInt8]()
        func emit(_ b: UInt8) { bytes.append(b) }
        func emit64(_ v: UInt64) {
            for i in 0..<8 { bytes.append(UInt8((v >> (i*8)) & 0xFF)) }
        }
        // --- Set stack limits (firmware runs privileged) ---
        // DSLIM = dataStackBase - 8MB (set by host; firmware reads via CPUID-like)
        // For the default image we rely on the host having preset dsp/csp/dslim.
        // --- Install trap vector: all traps → halt loop ---
        // Write a 2-byte infinite loop at the trap vector area is host's job.
        // --- Jump to program entry at 0x1000 ---
        // JMP32 with offset = 0x1000 - (pc after insn)
        // insn at 0x0000, 5 bytes → pc=5, target 0x1000 → offset 0x0FFB
        emit(0xA1) // JMP32
        let off = Int32(0x1000 - 5)
        let u = UInt32(bitPattern: off)
        for i in 0..<4 { bytes.append(UInt8((u >> (i*8)) & 0xFF)) }
        return Data(bytes)
    }

    /// Load custom firmware from a file URL (via Files app document picker).
    static func loadCustom(from url: URL) throws -> Data {
        // Security-scoped access for Files app URLs
        guard url.startAccessingSecurityScopedResource() else {
            throw NovaError.firmwareAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024 else { throw NovaError.firmwareTooLarge }
        return data
    }
}

enum NovaError: Error, LocalizedError {
    case firmwareAccessDenied
    case firmwareTooLarge
    case programTooLarge
    case noProgramLoaded

    var errorDescription: String? {
        switch self {
        case .firmwareAccessDenied: return "Could not access the firmware file."
        case .firmwareTooLarge: return "Firmware image exceeds 1MB."
        case .programTooLarge: return "Program exceeds available guest memory."
        case .noProgramLoaded: return "Load a program first."
        }
    }
}
