// VMView.swift — Console + controls + live register viewer.
// Big monospace console, Stop/Reset buttons, all 16 registers visible at once.

import SwiftUI

struct VMView: View {
    @ObservedObject var engine: NovaVMEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showingRegisters = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    engine.stop()
                    dismiss()
                }) {
                    Label("Close", systemImage: "xmark")
                        .font(.headline)
                }
                Spacer()
                Text(engine.isRunning ? "● Running" : "○ Halted")
                    .font(.headline)
                    .foregroundColor(engine.isRunning ? .green : .secondary)
                Spacer()
                Button(action: { showingRegisters.toggle() }) {
                    Label("Registers", systemImage: "cpu")
                }
                Button(action: { engine.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!engine.isRunning)
                Button(action: { engine.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
            .padding()

            // Register viewer — all 16 at once, not just top of stack
            if showingRegisters {
                RegisterGrid(engine: engine)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            // Console
            ScrollViewReader { proxy in
                ScrollView {
                    Text(engine.consoleText.isEmpty ? "No output yet." : engine.consoleText)
                        .font(.system(size: 18, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("consoleEnd")
                }
                .background(Color.black)
                .foregroundColor(Color.green)
                .cornerRadius(12)
                .padding(.horizontal)
                .onChange(of: engine.consoleText) { _ in
                    proxy.scrollTo("consoleEnd", anchor: .bottom)
                }
            }

            // Status bar
            Text(engine.statusLine)
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(8)
        }
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
                // Manual refresh — only meaningful when halted
                Button(action: { engine.snapshotRegisters() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(engine.isRunning)
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
