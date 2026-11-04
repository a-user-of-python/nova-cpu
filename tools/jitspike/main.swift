// main.swift — jitspike: executable-memory feasibility probe for NOVA v0.0.71.
//
// Question this answers (on the GitHub macOS CI runner, and by extension
// what code paths the JIT design may rely on): can a plain Swift
// command-line process, with NO special entitlements and NO code signing
// beyond swiftc's ad-hoc signature,
//   (a) allocate executable memory — plain mmap RWX first, MAP_JIT second,
//   (b) write trivial native machine code into it,
//   (c) call it through an UnsafeRawPointer -> C function pointer cast,
//   (d) honour W^X discipline: write while RW, mprotect to RX to execute,
//       never RWX at execute time where avoidable?
//
// Every probe is flushed to stdout BEFORE the risky call, so if executing
// generated code crashes the process, the CI log still shows exactly how
// far it got and which paths had already succeeded. Results are DATA:
// the process exits 0 when it ran to completion, whatever the outcomes;
// a non-zero exit or a missing "SPIKE DONE" line means the probe itself
// died (which is also a result — see the workflow log).
//
// Machine code:
//   arm64:  const42: mov w0, #42 ; ret          add: add w0, w0, w1 ; ret
//   x86_64: const42: mov eax, 42 ; ret          add: mov eax, edi ;
//                                                    add eax, esi ; ret

import Foundation
#if canImport(Darwin)
import Darwin
#endif

@_silgen_name("sys_icache_invalidate")
private func novaSysICacheInvalidate(_ start: UnsafeMutableRawPointer, _ len: Int)

private typealias FnConst = @convention(c) () -> Int32
private typealias FnAdd = @convention(c) (Int32, Int32) -> Int32

private let pageSize = 4096
// Darwin mmap flags not all surfaced to Swift; use the raw values.
private let MAP_PRIVATE_C: Int32 = 0x0002
private let MAP_ANON_C: Int32 = 0x1000
private let MAP_JIT_C: Int32 = 0x0800

private func say(_ s: String) {
    print(s)
    fflush(stdout)
}

private func archName() -> String {
#if arch(arm64)
    return "arm64"
#elseif arch(x86_64)
    return "x86_64"
#else
    return "unknown"
#endif
}

private func constCode() -> [UInt8] {
#if arch(arm64)
    // mov w0, #42  = 0x52800540 ; ret = 0xD65F03C0 (little-endian words)
    return [0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6]
#elseif arch(x86_64)
    // mov eax, 42 ; ret
    return [0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3]
#else
    return []
#endif
}

private func addCode() -> [UInt8] {
#if arch(arm64)
    // add w0, w0, w1 = 0x0B010000 ; ret = 0xD65F03C0
    return [0x00, 0x00, 0x01, 0x0B, 0xC0, 0x03, 0x5F, 0xD6]
#elseif arch(x86_64)
    // mov eax, edi ; add eax, esi ; ret
    return [0x89, 0xF8, 0x01, 0xF0, 0xC3]
#else
    return []
#endif
}

private func writeCode(_ base: UnsafeMutableRawPointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { src in
        if let sp = src.baseAddress {
            base.copyMemory(from: sp, byteCount: bytes.count)
        }
    }
    novaSysICacheInvalidate(base, bytes.count)
}

private func callConst(_ base: UnsafeMutableRawPointer) -> Int32 {
    let fn = unsafeBitCast(base, to: FnConst.self)
    return fn()
}

private func callAdd(_ base: UnsafeMutableRawPointer, _ a: Int32, _ b: Int32) -> Int32 {
    let fn = unsafeBitCast(base, to: FnAdd.self)
    return fn(a, b)
}

private func mmapFailed(_ p: UnsafeMutableRawPointer?) -> Bool {
    guard let p = p else { return true }
    return p == UnsafeMutableRawPointer(bitPattern: -1)
}

/// Run the const+add pair against an already-executable `base`.
/// Caller is responsible for write-protect state before each write.
private func exercise(_ label: String, _ base: UnsafeMutableRawPointer,
                      beforeWrite: () -> Void, beforeExec: () -> Void) {
    beforeWrite()
    writeCode(base, constCode())
    beforeExec()
    say("  [\(label)] calling const42 ...")
    let c = callConst(base)
    say("  [\(label)] const42() = \(c) (expected 42) \(c == 42 ? "OK" : "MISMATCH")")
    beforeWrite()
    writeCode(base, addCode())
    beforeExec()
    say("  [\(label)] calling add(20, 22) ...")
    let s = callAdd(base, 20, 22)
    say("  [\(label)] add(20, 22) = \(s) (expected 42) \(s == 42 ? "OK" : "MISMATCH")")
    say("  [\(label)] calling add(-5, 5) ...")
    let s2 = callAdd(base, -5, 5)
    say("  [\(label)] add(-5, 5) = \(s2) (expected 0) \(s2 == 0 ? "OK" : "MISMATCH")")
}

// MARK: - Probe 1: plain RWX mmap (PROT_READ|PROT_WRITE|PROT_EXEC)

private func probePlainRWX() -> Bool {
    say("PROBE plain-rwx: mmap(PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON)")
    let p = mmap(nil, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE_C | MAP_ANON_C, -1, 0)
    if mmapFailed(p) {
        say("  plain-rwx: mmap FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
        return false
    }
    guard let base = p else { return false }
    say("  plain-rwx: mmap OK at \(base)")
    exercise("plain-rwx", base, beforeWrite: {}, beforeExec: {})
    munmap(base, pageSize)
    say("  plain-rwx: RESULT OK (RWX allocation + execute worked)")
    return true
}

// MARK: - Probe 2: W^X — mmap RW, write, mprotect RX, execute; flip back to rewrite

private func probeWXTransition() -> Bool {
    say("PROBE wx-transition: mmap(PROT_READ|PROT_WRITE) -> write -> mprotect(PROT_READ|PROT_EXEC) -> execute")
    let p = mmap(nil, pageSize, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE_C | MAP_ANON_C, -1, 0)
    if mmapFailed(p) {
        say("  wx-transition: mmap FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
        return false
    }
    guard let base = p else { return false }
    say("  wx-transition: mmap RW OK at \(base)")
    var writeMode = true
    let toWrite = {
        if !writeMode {
            let rc = mprotect(base, pageSize, PROT_READ | PROT_WRITE)
            say("  wx-transition: mprotect(RX->RW) rc=\(rc)")
            writeMode = true
        }
    }
    let toExec = {
        if writeMode {
            let rc = mprotect(base, pageSize, PROT_READ | PROT_EXEC)
            say("  wx-transition: mprotect(RW->RX) rc=\(rc) errno=\(rc == 0 ? 0 : errno)")
            writeMode = false
        }
    }
    exercise("wx-transition", base, beforeWrite: toWrite, beforeExec: toExec)
    munmap(base, pageSize)
    say("  wx-transition: RESULT OK (write RW, execute RX, never RWX while executing)")
    return true
}

// MARK: - Probe 3: MAP_JIT (with pthread_jit_write_protect_np toggling)

private func probeMAPJIT() -> Bool {
    say("PROBE map-jit: mmap(PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANON|MAP_JIT)")
    var p = mmap(nil, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE_C | MAP_ANON_C | MAP_JIT_C, -1, 0)
    if mmapFailed(p) {
        let e1 = errno
        say("  map-jit: RWX+MAP_JIT mmap FAILED errno=\(e1) (\(String(cString: strerror(e1)))); trying PROT_READ|PROT_WRITE + MAP_JIT")
        p = mmap(nil, pageSize, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE_C | MAP_ANON_C | MAP_JIT_C, -1, 0)
        if mmapFailed(p) {
            say("  map-jit: RW+MAP_JIT mmap FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
            return false
        }
    }
    guard let base = p else { return false }
    say("  map-jit: mmap OK at \(base)")
    // pthread_jit_write_protect_np(0) = writes allowed, (1) = execute allowed.
    exercise("map-jit", base,
             beforeWrite: { pthread_jit_write_protect_np(0) },
             beforeExec: { pthread_jit_write_protect_np(1) })
    munmap(base, pageSize)
    say("  map-jit: RESULT OK (MAP_JIT allocation + execute worked)")
    return true
}

// MARK: - Main

say("=== NOVA JIT SPIKE ===")
say("arch=\(archName())")
#if arch(arm64) || arch(x86_64)
say("code sizes: const=\(constCode().count) bytes, add=\(addCode().count) bytes")
let rwx = probePlainRWX()
let wx = probeWXTransition()
let jit = probeMAPJIT()
say("SPIKE-SUMMARY plainRWX=\(rwx) wxTransition=\(wx) mapJIT=\(jit)")
say("SPIKE WINNING-PATH: \(rwx ? "plain mmap RWX" : (wx ? "mmap RW + mprotect RW->RX (W^X)" : (jit ? "MAP_JIT" : "NONE")))")
#else
say("SPIKE-SUMMARY unsupported arch — no machine code emitted")
#endif
say("SPIKE DONE")
