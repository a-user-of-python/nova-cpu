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
    case timerInterrupt      = 17  // Hardware timer fired (for firmware scheduler)
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

    /// Hard cap: the VM can never allocate more than 1 GB of device RAM.
    static let maxTotalSize = 1024 * 1024 * 1024

    init(totalSize: Int = 64 * 1024 * 1024) {
        // Clamp into [64MB, 1GB]. 64MB minimum ensures stack regions fit.
        let clamped = min(max(totalSize, 64 * 1024 * 1024), Self.maxTotalSize)
        self.totalSize = clamped
        self.sizeU64 = UInt64(clamped)
        self.bytes = ContiguousArray<UInt8>(repeating: 0, count: clamped)

        let top = UInt64(clamped)
        // Reserve stack space proportionally, capped at 8MB/16MB.
        // For 64MB: reserve 4MB/8MB. For >=128MB: use full 8MB/16MB.
        let reserveUnit = min(UInt64(8 * 1024 * 1024), top / 16)
        self.vectorStackBase = top
        self.callStackBase   = top &- reserveUnit
        self.dataStackBase   = top &- (reserveUnit * 2)
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

    @inline(__always) func write16(_ addr: UInt64, _ v: UInt16) throws {
        try checkWrite(addr, 2)
        let i = Int(addr)
        bytes[i] = UInt8(v & 0xFF)
        bytes[i+1] = UInt8((v >> 8) & 0xFF)
    }

    @inline(__always) func write32(_ addr: UInt64, _ v: UInt32) throws {
        try checkWrite(addr, 4)
        let i = Int(addr)
        for b in 0..<4 { bytes[i+b] = UInt8((v >> (b*8)) & 0xFF) }
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
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            memmove(base + Int(dst), base + Int(src), n)
        }
    }

    // MARK: - Program loading

    func loadBytes(_ data: Data, at address: UInt64) throws {
        guard address < sizeU64 else { throw NovaTrap.loadAccessFault }
        let n = min(data.count, Int(sizeU64 - address))
        guard n > 0 else { return }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let sp = src.baseAddress else { return }
            bytes.withUnsafeMutableBufferPointer { dst in
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
    static let keyboardAddr: UInt64 = 0xFFFF_FFFF_FFFF_0008
    static let fileCmdAddr: UInt64 = 0xFFFF_FFFF_FFFF_0010
    static let fileArg0Addr: UInt64 = 0xFFFF_FFFF_FFFF_0018
    static let fileArg1Addr: UInt64 = 0xFFFF_FFFF_FFFF_0020
    static let fileArg2Addr: UInt64 = 0xFFFF_FFFF_FFFF_0028
    static let fileResultAddr: UInt64 = 0xFFFF_FFFF_FFFF_0030
    // Hardware timer (for firmware scheduler). Firmware writes interval in cycles.
    // Write 0 to disable. When the timer fires, the CPU takes a Machine trap
    // and vectors to the firmware's trap handler (hardware behavior, not app control).
    static let timerIntervalAddr: UInt64 = 0xFFFF_FFFF_FFFF_0040
    static let timerCountAddr: UInt64 = 0xFFFF_FFFF_FFFF_0048
    // Timer vector: firmware writes its handler address here (like mtvec).
    // On timer interrupt, the CPU jumps to this address.
    static let timerVectorAddr: UInt64 = 0xFFFF_FFFF_FFFF_0050

    var consoleOutput: ((String) -> Void)?

    /// Keyboard input queue (host pushes keys, guest pops via MMIO read)
    var keyboardQueue: [UInt8] = []
    /// Guards keyboardQueue: pushKey runs on the main (UI) thread,
    /// mmioRead runs on the VM thread. Without this, rapid input
    /// corrupts the array and duplicates/drops bytes.
    private let keyboardLock = NSLock()

    /// File operation handler (set by host)
    var fileHandler: ((UInt64, UInt64, UInt64, UInt64) -> Int64)?

    // File command args
    private var fileArg0: UInt64 = 0
    private var fileArg1: UInt64 = 0
    private var fileArg2: UInt64 = 0
    private var fileResult: Int64 = 0

    /// Hardware timer interval in CPU cycles (0 = disabled). Set by firmware via MMIO.
    /// The CPU checks this and fires a timer interrupt when the cycle count reaches it.
    var timerInterval: UInt64 = 0
    /// Timer countdown (cycles remaining). Firmware can read via MMIO.
    var timerCount: UInt64 = 0
    /// Timer vector: firmware's handler address (like mtvec). Set via MMIO.
    var timerVector: UInt64 = 0

    /// Buffer for assembling multi-byte UTF-8 sequences from MMIO writes.
    private var utf8Buffer = [UInt8]()

    /// Debug: logs raw console/keyboard bytes to Documents/console-debug.log
    static func debugLog(_ msg: String) {
        let url = NovaFolders.root.appendingPathComponent("console-debug.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    func mmioWrite(_ addr: UInt64, _ v: UInt64) {
        if addr == Self.consoleAddr {
            let byte = UInt8(v & 0xFF)
            Self.debugLog("CONSOLE_OUT byte=\(byte) char='\(byte < 32 ? "\\u{\(String(byte, radix: 16))}" : String(UnicodeScalar(byte)))'")
            utf8Buffer.append(byte)
            if isCompleteUTF8(utf8Buffer), let s = String(bytes: utf8Buffer, encoding: .utf8) {
                utf8Buffer.removeAll()
                consoleOutput?(s)
            } else if utf8Buffer.count > 8 {
                let s = String(bytes: utf8Buffer, encoding: .utf8) ?? ""
                utf8Buffer.removeAll()
                consoleOutput?(s)
            }
        } else if addr == Self.timerIntervalAddr {
            timerInterval = v
            timerCount = v  // Reset countdown
        } else if addr == Self.timerVectorAddr {
            timerVector = v
        } else if addr == Self.fileCmdAddr {
            // Execute file command synchronously
            if let handler = fileHandler {
                fileResult = handler(v, fileArg0, fileArg1, fileArg2)
            } else {
                fileResult = -1
            }
        } else if addr == Self.fileArg0Addr {
            fileArg0 = v
        } else if addr == Self.fileArg1Addr {
            fileArg1 = v
        } else if addr == Self.fileArg2Addr {
            fileArg2 = v
        }
    }

    func mmioRead(_ addr: UInt64) -> UInt64 {
        if addr == Self.keyboardAddr {
            keyboardLock.lock()
            defer { keyboardLock.unlock() }
            return keyboardQueue.isEmpty ? 0 : UInt64(keyboardQueue.removeFirst())
        } else if addr == Self.fileResultAddr {
            return UInt64(bitPattern: fileResult)
        } else if addr == Self.timerCountAddr {
            return timerCount
        } else if addr == Self.timerIntervalAddr {
            return timerInterval
        } else if addr == Self.timerVectorAddr {
            return timerVector
        }
        return 0
    }

    /// Host pushes a key for the guest to read
    func pushKey(_ byte: UInt8) {
        Self.debugLog("KEYBOARD_IN byte=\(byte) char='\(byte < 32 ? "\\u{\(String(byte, radix: 16))}" : String(UnicodeScalar(byte)))'")
        keyboardLock.lock()
        keyboardQueue.append(byte)
        keyboardLock.unlock()
    }

    /// Clears pending keyboard input (used on reboot).
    func clearKeyboardQueue() {
        keyboardLock.lock()
        keyboardQueue.removeAll()
        keyboardLock.unlock()
    }

    /// Returns true if bytes form complete UTF-8 sequences (not cut mid-character).
    private func isCompleteUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            let len: Int
            if b < 0x80 { len = 1 }
            else if b < 0xC2 { return false } // stray continuation
            else if b < 0xE0 { len = 2 }
            else if b < 0xF0 { len = 3 }
            else if b < 0xF5 { len = 4 }
            else { return false }
            if i + len > bytes.count { return false } // incomplete
            // Validate continuation bytes
            for j in 1..<len {
                if bytes[i+j] < 0x80 || bytes[i+j] > 0xBF { return false }
            }
            i += len
        }
        return true
    }
}
