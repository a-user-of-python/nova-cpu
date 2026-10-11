// NovaConfig.swift — NOVA folder structure + config file.
// Creates ~/Documents/NOVA/ with config.nova, firmware/, programs/.
// The Documents folder is visible in the Files app under "On My iPad".

import Foundation

/// VM configuration. Two fields are mandatory: ramMB and cpuCores.
struct NovaConfig: Codable {
    // MARK: Mandatory
    var ramMB: Int          // RAM allocated to the VM (16–1024)
    var cpuCores: Int       // Total cores the VM may use (1–maxCores)

    // MARK: Optional (sensible defaults)
    var pCores: Int         // Performance cores (0–cpuCores)
    var eCores: Int         // Efficiency cores (0–cpuCores)
    var firmware: String    // "default" or a filename in NOVA/firmware/
    var consoleEnabled: Bool
    var maxStepsPerRun: UInt64  // 0 = unlimited

    static let maxRAMMB = 1024  // 1GB hard cap
    static let minRAMMB = 16

    static func `default`(maxCores: Int, pCores: Int, eCores: Int) -> NovaConfig {
        NovaConfig(
            ramMB: 256,
            cpuCores: min(4, maxCores),
            pCores: min(2, pCores),
            eCores: min(2, eCores),
            firmware: "default",
            consoleEnabled: true,
            maxStepsPerRun: 0
        )
    }

    /// Clamp all values into valid ranges.
    mutating func sanitize(maxCores: Int, maxP: Int, maxE: Int) {
        ramMB = min(max(ramMB, Self.minRAMMB), Self.maxRAMMB)
        cpuCores = min(max(cpuCores, 1), maxCores)
        pCores = min(max(pCores, 0), maxP)
        eCores = min(max(eCores, 0), maxE)
        // P+E should not exceed total; scale down E first.
        while pCores + eCores > cpuCores && eCores > 0 { eCores -= 1 }
        while pCores + eCores > cpuCores && pCores > 0 { pCores -= 1 }
    }
}

// MARK: - Folder management

enum NovaFolders {
    /// ~/Documents/NOVA
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NOVA", isDirectory: true)
    }
    static var firmwareDir: URL { root.appendingPathComponent("firmware", isDirectory: true) }
    static var programsDir: URL { root.appendingPathComponent("programs", isDirectory: true) }
    static var configFile: URL { root.appendingPathComponent("config.nova") }

    /// Create the folder structure on first launch. Idempotent.
    static func setup() {
        let fm = FileManager.default
        for dir in [root, firmwareDir, programsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Seed a README so the folders aren't empty/mysterious.
        let readme = firmwareDir.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            Drop custom NOVA firmware .bin files here.
            Select them from the app's firmware toggle (Custom firmware → Choose File),
            or set firmware=<filename> in ../config.nova.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
        let progReadme = programsDir.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: progReadme.path) {
            try? """
            Drop NOVA program .bin files here for quick access.
            You can also load programs from anywhere via the Files picker.
            Assemble .nova sources with: python3 novas.py program.nova -o program.bin
            """.write(to: progReadme, atomically: true, encoding: .utf8)
        }
    }

    /// Write the default config file if none exists. Returns the live config.
    static func loadOrCreateConfig() -> NovaConfig {
        let info = DeviceInfo.current
        var cfg: NovaConfig
        if let data = try? Data(contentsOf: configFile),
           let parsed = parseConfig(data) {
            cfg = parsed
        } else {
            cfg = NovaConfig.default(maxCores: info.totalCores, pCores: info.pCores, eCores: info.eCores)
            save(cfg)
        }
        cfg.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
        return cfg
    }

    static func save(_ cfg: NovaConfig) {
        try? serialize(cfg).write(to: configFile, atomically: true, encoding: .utf8)
    }

    // MARK: - config.nova format (key=value, # comments)

    static func parseConfig(_ data: Data) -> NovaConfig? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let info = DeviceInfo.current
        var cfg = NovaConfig.default(maxCores: info.totalCores, pCores: info.pCores, eCores: info.eCores)
        var seenRAM = false, seenCores = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "ram_mb":   if let v = Int(val) { cfg.ramMB = v; seenRAM = true }
            case "cpu_cores": if let v = Int(val) { cfg.cpuCores = v; seenCores = true }
            case "p_cores":  if let v = Int(val) { cfg.pCores = v }
            case "e_cores":  if let v = Int(val) { cfg.eCores = v }
            case "firmware": cfg.firmware = val
            case "console_enabled": cfg.consoleEnabled = val.lowercased() != "false" && val != "0"
            case "max_steps": if let v = UInt64(val) { cfg.maxStepsPerRun = v }
            default: break
            }
        }
        // Both mandatory fields must be present, else fall back to defaults.
        guard seenRAM && seenCores else { return nil }
        return cfg
    }

    static func serialize(_ cfg: NovaConfig) -> String {
        """
        # NOVA VM Configuration — edit freely, reloaded on app launch.
        # MANDATORY:
        ram_mb=\(cfg.ramMB)          # RAM for the VM in MB (16–1024)
        cpu_cores=\(cfg.cpuCores)       # Total cores the VM may use (1–\(DeviceInfo.current.totalCores))

        # OPTIONAL:
        p_cores=\(cfg.pCores)           # Performance cores to prefer
        e_cores=\(cfg.eCores)           # Efficiency cores to prefer
        firmware=\(cfg.firmware)  # "default" or a .bin filename in NOVA/firmware/
        console_enabled=\(cfg.consoleEnabled) # true/false — MMIO console output
        max_steps=\(cfg.maxStepsPerRun)          # 0 = unlimited instructions per run
        """
    }

    /// Resolve the firmware selection to actual bytes.
    static func resolveFirmware(_ cfg: NovaConfig) -> Data {
        if cfg.firmware.lowercased() != "default" {
            let url = firmwareDir.appendingPathComponent(cfg.firmware)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return NovaFirmware.defaultImage
    }
}
