// NovaMemory.swift — Guest physical memory for the NOVA VM.
// Uses a single ContiguousArray<UInt8> for cache-friendly access.
// Stack regions grow downward from their bases; program loaded at low addresses.
//
// SECURITY: All accessors are bounds-checked. Out-of-bounds access throws
// NovaTrap.loadAccessFault / .storeAccessFault instead of crashing the host.

import Foundation

// MARK: - Trap Causes (shared by CPU and memory)
enum NovaTrap: UInt64, Error {
    case instrAddrMisaligned = 0
    case instrAccessFault    = 1
    case illegalInstruction  = 2
    case breakpoint          = 3
    case loadAddrMisaligned  = 4
    case loadAccessFault     = 5
    case storeAddrMisaligned = 6
    case storeAccessFault    = 7
    case ecallU              = 8
    case ecallS              = 9
    case ecallH              = 10
    case ecallM              = 11
    case instrPageFault      = 12
    case loadPageFault       = 13
    case storePageFault      = 14
    case stackOverflow       = 15
    case stackUnderflow      = 16
}

final class NovaMemory {

    // MARK: - Layout
    // [0x0            ] program + data (grows up)
    // [dataStackBase  ] data stack (grows down from base)
    // [callStackBase  ] call stack (grows down)
    // [vectorStackBase] vector stack (grows down, 16-byte entries)

    let totalSize: Int
    private let sizeU64: UInt64
    private var bytes: ContiguousArray<UInt8>

    let dataStackBase: UInt64
    let callStackBase: UInt64
    let vectorStackBase: UInt64

    static let pageSize = 4096

    init(totalSize: Int = 64 * 1024 * 1024) {
        self.totalSize = totalSize
        self.sizeU64 = UInt64(totalSize)
        self.bytes = ContiguousArray<UInt8>(repeating: 0, count: totalSize)

        let top = UInt64(totalSize)
        self.vectorStackBase = top
        self.callStackBase   = top - 8 * 1024 * 1024
        self.dataStackBase   = top - 16 * 1024 * 1024
    }

    // MARK: - Bounds-checked access (little-endian)

    @inline(__always) private func checkRead(_ addr: UInt64, _ size: UInt64) throws {
        // Wrapping add avoids overflow trap on addr+size; compare handles it.
        guard addr < sizeU64, size <= sizeU64, addr &+ size <= sizeU64 else {
            throw NovaTrap.loadAccessFault
        }
    }

    @inline(__always) private func checkWrite(_ addr: UInt64, _ size: UInt64) throws {
        guard addr < sizeU64, size <= sizeU64, addr &+ size <= sizeU64 else {
            throw NovaTrap.storeAccessFault
        }
    }

    @inline(__always) func read8(_ addr: UInt64) throws -> UInt8 {
        try checkRead(addr, 1)
        return bytes[Int(addr)]
    }

    @inline(__always) func read16(_ addr: UInt64) throws -> UInt16 {
        try checkRead(addr, 2)
        let i = Int(addr)
        return UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
    }

    @inline(__always) func read32(_ addr: UInt64) throws -> UInt32 {
        try checkRead(addr, 4)
        let i = Int(addr)
        // NOTE: must be UInt32 — UInt16 << 16 traps on overflow.
        return UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8)
             | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)
    }

    @inline(__always) func read64(_ addr: UInt64) throws -> UInt64 {
        try checkRead(addr, 8)
        let i = Int(addr)
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(bytes[i+b]) << (b*8) }
        return v
    }

    @inline(__always) func write8(_ addr: UInt64, _ v: UInt8) throws {
        try checkWrite(addr, 1)
        bytes[Int(addr)] = v
    }

    @inline(__always) func write64(_ addr: UInt64, _ v: UInt64) throws {
        try checkWrite(addr, 8)
        let i = Int(addr)
        for b in 0..<8 { bytes[i+b] = UInt8((v >> (b*8)) & 0xFF) }
    }

    func copyBytes(from src: UInt64, to dst: UInt64, count: UInt64) throws {
        guard count <= sizeU64,
              src < sizeU64, src &+ count <= sizeU64,
              dst < sizeU64, dst &+ count <= sizeU64 else {
            throw NovaTrap.loadAccessFault
        }
        let n = Int(count)
        bytes.withContiguousMutableStorage { buf in
            guard let base = buf.baseAddress else { return }
            memmove(base + Int(dst), base + Int(src), n)
        }
    }

    // MARK: - Program loading

    func loadBytes(_ data: Data, at address: UInt64) throws {
        guard address < sizeU64 else { throw NovaTrap.loadAccessFault }
        let n = min(data.count, Int(sizeU64 - address))
        guard n > 0 else { return }
        data.withUnsafeBytes { src in
            guard let sp = src.baseAddress else { return }
            bytes.withContiguousMutableStorage { dst in
                guard let dp = dst.baseAddress else { return }
                memcpy(dp + Int(address), sp, n)
            }
        }
    }

    func loadProgram(_ data: Data) throws {
        try loadBytes(data, at: 0)
    }

    // MARK: - Console I/O (memory-mapped)

    static let consoleAddr: UInt64 = 0xFFFF_FFFF_FFFF_0000
    var consoleOutput: ((String) -> Void)?

    func mmioWrite(_ addr: UInt64, _ v: UInt64) {
        if addr == Self.consoleAddr {
            let c = Character(UnicodeScalar(UInt8(v & 0xFF)))
            consoleOutput?(String(c))
        }
    }
}
