// NovaMemory.swift — Guest physical memory for the NOVA VM.
// Uses a single ContiguousArray<UInt8> for cache-friendly access.
// Stack regions grow downward from their bases; program loaded at low addresses.

import Foundation

final class NovaMemory {

    // MARK: - Layout
    // [0x0            ] program + data (grows up)
    // [dataStackBase  ] data stack (grows down from base)
    // [callStackBase  ] call stack (grows down)
    // [vectorStackBase] vector stack (grows down, 16-byte entries)

    let totalSize: Int
    private var bytes: ContiguousArray<UInt8>

    let dataStackBase: UInt64
    let callStackBase: UInt64
    let vectorStackBase: UInt64

    // Page size for MMU stub (VM uses identity mapping; firmware may enable paging)
    static let pageSize = 4096

    init(totalSize: Int = 64 * 1024 * 1024) {
        // Default 64MB guest RAM carved from iOS device memory.
        self.totalSize = totalSize
        self.bytes = ContiguousArray<UInt8>(repeating: 0, count: totalSize)

        // Stacks at top of memory, 8MB each.
        let top = UInt64(totalSize)
        self.vectorStackBase = top
        self.callStackBase   = top - 8 * 1024 * 1024
        self.dataStackBase   = top - 16 * 1024 * 1024
    }

    // MARK: - Raw access (little-endian, unchecked — CPU checks bounds)

    @inline(__always) func read8(_ addr: UInt64) -> UInt8 {
        bytes[Int(addr)]
    }

    @inline(__always) func read16(_ addr: UInt64) -> UInt16 {
        let i = Int(addr)
        return UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
    }

    @inline(__always) func read32(_ addr: UInt64) -> UInt32 {
        let i = Int(addr)
        return UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
            | (UInt16(bytes[i+2]) << 16) | (UInt16(bytes[i+3]) << 24)
    }

    @inline(__always) func read64(_ addr: UInt64) -> UInt64 {
        let i = Int(addr)
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(bytes[i+b]) << (b*8) }
        return v
    }

    @inline(__always) func write8(_ addr: UInt64, _ v: UInt8) {
        bytes[Int(addr)] = v
    }

    @inline(__always) func write64(_ addr: UInt64, _ v: UInt64) {
        let i = Int(addr)
        for b in 0..<8 { bytes[i+b] = UInt8((v >> (b*8)) & 0xFF) }
    }

    func copyBytes(from src: UInt64, to dst: UInt64, count: UInt64) {
        let s = Int(src), d = Int(dst), n = Int(count)
        guard s >= 0, d >= 0, s+n <= totalSize, d+n <= totalSize else { return }
        bytes.withContiguousMutableStorage { buf in
            guard let base = buf.baseAddress else { return }
            memmove(base + d, base + s, n)
        }
    }

    // MARK: - Program loading

    /// Load a raw NOVA binary at `address`. Copies bytes directly.
    func loadBytes(_ data: Data, at address: UInt64) {
        let offset = Int(address)
        let n = min(data.count, totalSize - offset)
        guard n > 0 else { return }
        data.withUnsafeBytes { src in
            guard let sp = src.baseAddress else { return }
            bytes.withContiguousMutableStorage { dst in
                guard let dp = dst.baseAddress else { return }
                memcpy(dp + offset, sp, n)
            }
        }
    }

    /// Load a raw NOVA binary at address 0.
    func loadProgram(_ data: Data) {
        loadBytes(data, at: 0)
    }

    // MARK: - Console I/O (memory-mapped)

    /// MMIO: writes to 0xFFFF_FFFF_FFFF_0000 go to console output.
    static let consoleAddr: UInt64 = 0xFFFF_FFFF_FFFF_0000
    var consoleOutput: ((String) -> Void)?

    func mmioWrite(_ addr: UInt64, _ v: UInt64) {
        if addr == Self.consoleAddr {
            // Low byte = character to print
            let c = Character(UnicodeScalar(UInt8(v & 0xFF)))
            consoleOutput?(String(c))
        }
    }
}
