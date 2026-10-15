// VMView.swift — Console + controls + live register viewer.
// Big monospace console, Stop/Reset buttons, all 16 registers visible at once.

import SwiftUI

/// Parse ANSI escape codes into styled SwiftUI Text.
struct ANSIRenderer {
    static func render(_ text: String) -> Text {
        var result = Text("")
        var current = ""
        var fg: Color? = nil
        var bold = false
        
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{1B}" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "[" {
                // Flush current segment
                if !current.isEmpty {
                    var t = Text(current)
                    if let c = fg { t = t.foregroundColor(c) }
                    if bold { t = t.bold() }
                    result = result + t
                    current = ""
                }
                // Parse escape sequence
                var j = text.index(i, offsetBy: 2)
                var codes = ""
                while j < text.endIndex && text[j] != "m" {
                    codes.append(text[j])
                    j = text.index(after: j)
                }
                if j < text.endIndex { j = text.index(after: j) } // skip 'm'
                
                // Interpret codes
                let parts = codes.split(separator: ";").map { String($0) }
                if parts == ["0"] {
                    fg = nil; bold = false
                } else if parts == ["1"] {
                    bold = true
                } else if parts == ["2"] {
                    fg = Color.gray // dim
                } else if parts.count >= 5 && parts[0] == "38" && parts[1] == "2" {
                    // 38;2;r;g;b foreground RGB
                    if let r = Int(parts[2]), let g = Int(parts[3]), let b = Int(parts[4]) {
                        fg = Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
                    }
                }
                i = j
            } else {
                current.append(text[i])
                i = text.index(after: i)
            }
        }
        if !current.isEmpty {
            var t = Text(current)
            if let c = fg { t = t.foregroundColor(c) }
            if bold { t = t.bold() }
            result = result + t
        }
        return result
    }
}

struct VMView: View {
    @ObservedObject var engine: NovaVMEngine
    @EnvironmentObject var appSettings: AppSettings
    @State private var showingRegisters = false
    @State private var keyboardInput = ""
    @State private var showingImport = false

    /// Console colors from the App Settings theme.
    private var consoleBackground: Color {
        switch appSettings.consoleTheme {
        case "light": return .white
        case "highContrast": return .black
        default: return .black
        }
    }

    private var consoleForeground: Color {
        switch appSettings.consoleTheme {
        case "light": return .black
        case "highContrast": return .yellow
        default: return .white
        }
    }

    /// Light haptic tap, honoring the App Settings toggle.
    private func haptic() {
        guard appSettings.hapticFeedback else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Register viewer — all 16 at once, not just top of stack
            if showingRegisters {
                RegisterGrid(engine: engine)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .onAppear {
                        engine.snapshotRegisters()
                        engine.startLiveUpdates()
                    }
                    .onDisappear {
                        engine.stopLiveUpdates()
                    }
            }

            // Console — full width, edge to edge
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if engine.consoleText.isEmpty {
                            Text("No output yet.")
                                .foregroundColor(consoleForeground)
                        } else {
                            ANSIRenderer.render(engine.consoleText)
                        }
                    }
                        .font(.system(size: appSettings.consoleFontSize, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("consoleEnd")
                }
                .background(consoleBackground)
                .foregroundColor(consoleForeground)
                .onChange(of: engine.consoleText) { _ in
                    proxy.scrollTo("consoleEnd", anchor: .bottom)
                }
            }

            // Keyboard input — sends keys to the VM (for firmware shells)
            HStack {
                TextField("Type here...", text: $keyboardInput, onCommit: {
                    sendKeys()
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.system(size: 22))
                .autocapitalization(appSettings.keyboardAutocapitalization ? .sentences : .none)
                .disableAutocorrection(!appSettings.keyboardAutocorrection)
                Button("Send") { haptic(); sendKeys() }
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Bottom control bar — Running/Halted, Registers, Stop, Reset, Reboot, Import
            HStack {
                Text(engine.isRunning ? "● Running" : "○ Halted")
                    .font(.headline)
                    .foregroundColor(engine.isRunning ? .green : .secondary)
                Spacer()
                Button(action: { haptic(); showingRegisters.toggle() }) {
                    Label("Registers", systemImage: "cpu")
                        .font(.headline)
                        .labelStyle(.iconOnly)
                }
                Button(action: { haptic(); engine.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .labelStyle(.iconOnly)
                }
                .disabled(!engine.isRunning)
                Button(action: { haptic(); engine.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .labelStyle(.iconOnly)
                }
                Button(action: { haptic(); engine.boot() }) {
                    Label("Reboot", systemImage: "power")
                        .font(.headline)
                        .labelStyle(.iconOnly)
                }
                Button(action: { haptic(); showingImport = true }) {
                    Label("Import", systemImage: "arrow.down.circle")
                        .font(.headline)
                        .labelStyle(.iconOnly)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .sheet(isPresented: $showingImport) {
                ProgramImportView()
            }

            // Status bar
            Text(engine.statusLine)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(8)
        }
        .onAppear {
            // Auto-boot when the Run tab appears and nothing is running.
            if !engine.isRunning {
                engine.boot()
            }
            if appSettings.keepAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func sendKeys() {
        for byte in keyboardInput.utf8 {
            engine.memory.pushKey(byte)
        }
        // Send Enter key too
        engine.memory.pushKey(10)
        // Do NOT echo here: the guest shell echoes via console MMIO.
        // Echoing here creates duplicates and confusion.
        keyboardInput = ""
    }
}

struct RegisterGrid: View {
    @ObservedObject var engine: NovaVMEngine

    private func hex(_ v: UInt64) -> String {
        String(format: "0x%016llX", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Registers")
                    .font(.headline)
                Spacer()
                // Manual refresh — snapshots immediately
                Button(action: { engine.snapshotRegisters() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }
            // R0–R15 in a 4×4 grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    HStack {
                        Text("R\(i)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, alignment: .leading)
                        Text(hex(engine.regSnapshot[i]))
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
            // Stack pointers + PC + FP
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("DSP").font(.caption).foregroundColor(.secondary)
                    Text(hex(engine.spSnapshot.dsp)).font(.system(size: 13, design: .monospaced))
                }
                VStack(alignment: .leading) {
                    Text("CSP").font(.caption).foregroundColor(.secondary)
                    Text(hex(engine.spSnapshot.csp)).font(.system(size: 13, design: .monospaced))
                }
                VStack(alignment: .leading) {
                    Text("PC").font(.caption).foregroundColor(.secondary)
                    Text(hex(engine.spSnapshot.pc)).font(.system(size: 13, design: .monospaced))
                }
                VStack(alignment: .leading) {
                    Text("FP").font(.caption).foregroundColor(.secondary)
                    Text(hex(engine.spSnapshot.fp)).font(.system(size: 13, design: .monospaced))
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 1))
    }
}
