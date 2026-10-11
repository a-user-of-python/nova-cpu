// VMView.swift — Console + controls while the VM runs.
// Big monospace console, Stop/Reset buttons, register readout.

import SwiftUI

struct VMView: View {
    @ObservedObject var engine: NovaVMEngine
    @Environment(\.dismiss) private var dismiss

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
                Button(action: { engine.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!engine.isRunning)
                Button(action: { engine.reset() }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
            .padding()

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
