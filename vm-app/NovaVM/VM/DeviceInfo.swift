// DeviceInfo.swift — Detects the Apple Silicon chip and core topology.
// Uses sysctl hw.model (e.g. "iPad16,3") mapped to known chips.
// P/E core counts come from Apple's published specs per chip.

import Foundation
import Darwin

struct ChipInfo {
    let name: String        // "Apple M3"
    let totalCores: Int
    let pCores: Int
    let eCores: Int
}

struct DeviceInfo {
    let chip: ChipInfo
    var totalCores: Int { chip.totalCores }
    var pCores: Int { chip.pCores }
    var eCores: Int { chip.eCores }

    static var current: DeviceInfo {
        let model = hardwareModel()
        return DeviceInfo(chip: chipForModel(model) ?? fallbackChip())
    }

    // MARK: - sysctl

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Physical core count from the OS (sanity check / upper bound).
    static var osCoreCount: Int {
        ProcessInfo.processInfo.processorCount
    }

    // MARK: - Chip database (iPad + iPhone, M-series)

    private static func chipForModel(_ model: String) -> ChipInfo? {
        // iPad Air 11" M3 / 13" M3
        if model.hasPrefix("iPad16,3") || model.hasPrefix("iPad16,4")
            || model.hasPrefix("iPad16,5") || model.hasPrefix("iPad16,6") {
            return ChipInfo(name: "Apple M3", totalCores: 8, pCores: 4, eCores: 4)
        }
        // iPad Pro 11" M4 / 13" M4
        if model.hasPrefix("iPad16,7") || model.hasPrefix("iPad16,8")
            || model.hasPrefix("iPad16,9") || model.hasPrefix("iPad16,10")
            || model.hasPrefix("iPad16,11") || model.hasPrefix("iPad16,12") {
            // M4: 9-core (3P+6E) on 256/512GB, 10-core (4P+6E) on 1TB/2TB.
            // Report the 10-core variant; sanitize() clamps to OS count.
            return ChipInfo(name: "Apple M4", totalCores: 10, pCores: 4, eCores: 6)
        }
        // iPad Pro M2 (11" 4th gen / 12.9" 6th gen)
        if model.hasPrefix("iPad13,4") || model.hasPrefix("iPad13,5")
            || model.hasPrefix("iPad13,6") || model.hasPrefix("iPad13,7")
            || model.hasPrefix("iPad13,8") || model.hasPrefix("iPad13,9")
            || model.hasPrefix("iPad13,10") || model.hasPrefix("iPad13,11") {
            return ChipInfo(name: "Apple M2", totalCores: 8, pCores: 4, eCores: 4)
        }
        // iPad Pro M1
        if model.hasPrefix("iPad13,1") || model.hasPrefix("iPad13,2")
            || model.hasPrefix("iPad13,16") || model.hasPrefix("iPad13,17") {
            return ChipInfo(name: "Apple M1", totalCores: 8, pCores: 4, eCores: 4)
        }
        // iPhone 16 Pro (A18 Pro)
        if model.hasPrefix("iPhone17,1") || model.hasPrefix("iPhone17,2") {
            return ChipInfo(name: "Apple A18 Pro", totalCores: 6, pCores: 2, eCores: 4)
        }
        // iPhone 16 / 16 Plus (A18)
        if model.hasPrefix("iPhone17,3") || model.hasPrefix("iPhone17,4") {
            return ChipInfo(name: "Apple A18", totalCores: 6, pCores: 2, eCores: 4)
        }
        // iPhone 15 Pro (A17 Pro)
        if model.hasPrefix("iPhone16,1") || model.hasPrefix("iPhone16,2") {
            return ChipInfo(name: "Apple A17 Pro", totalCores: 6, pCores: 2, eCores: 4)
        }
        return nil
    }

    private static func fallbackChip() -> ChipInfo {
        // Unknown model: trust the OS core count, assume half P / half E.
        let n = max(1, osCoreCount)
        let p = max(1, n / 2)
        return ChipInfo(name: "Apple Silicon (unknown)", totalCores: n, pCores: p, eCores: n - p)
    }
}
