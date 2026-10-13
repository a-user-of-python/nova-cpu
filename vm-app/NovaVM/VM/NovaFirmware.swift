// NovaFirmware.swift — Firmware loading: built-in default + custom via Files app.

import Foundation

/// NOVA firmware: runs at machine privilege before the user program.
/// Handles memory init, stack setup, trap vectors, and console I/O.
struct NovaFirmware {

    /// Default firmware: NovaShell (interactive shell), embedded in NovaShellDefault.swift.
    /// Runs at 0x0. Programs load at 0x1000 on top of it (via the app's
    /// program loader or NovaShell's `run <file>` command).
    static var defaultImage: Data {
        // NovaShell is the default. The minimal JMP stub is kept as a
        // fallback in case the embedded image is ever unavailable.
        let shell = novaShellImage
        if !shell.isEmpty {
            return shell
        }
        // Fallback: minimal JMP32 to 0x1000 (program entry).
        var bytes = [UInt8]()
        bytes.append(0xA1) // JMP32
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
