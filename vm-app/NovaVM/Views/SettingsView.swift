// SettingsView.swift — Chip info + sliders for RAM and core allocation.
// Large type, high contrast. Writes back to NOVA/config.nova.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: NovaVMEngine
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: NovaConfig
    private let info: DeviceInfo

    init(engine: NovaVMEngine) {
        self.engine = engine
        self.info = DeviceInfo.current
        _cfg = State(initialValue: engine.config)
    }

    var body: some View {
        NavigationView {
            Form {
                // Chip readout
                Section(header: Text("Processor").font(.headline)) {
                    HStack {
                        Image(systemName: "cpu")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(info.chip.name)
                                .font(.title2).bold()
                            Text("\(info.totalCores) cores (\(info.pCores)P + \(info.eCores)E)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // RAM slider (16MB – 1024MB)
                Section(header: Text("Memory").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("VM RAM")
                                .font(.title3)
                            Spacer()
                            Text("\(cfg.ramMB) MB")
                                .font(.title3).bold()
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(cfg.ramMB) },
                            set: { cfg.ramMB = Int($0) }
                        ), in: Double(NovaConfig.minRAMMB)...Double(NovaConfig.maxRAMMB), step: 16)
                        Text("Max 1024 MB (1 GB). Takes effect on next launch.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // Core sliders
                Section(header: Text("CPU Cores").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Total cores")
                                .font(.title3)
                            Spacer()
                            Text("\(cfg.cpuCores)")
                                .font(.title3).bold()
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(cfg.cpuCores) },
                            set: {
                                cfg.cpuCores = Int($0)
                                cfg.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
                            }
                        ), in: 1...Double(info.totalCores), step: 1)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("P-cores (performance)")
                                .font(.headline)
                            Spacer()
                            Text("\(cfg.pCores)")
                                .font(.title3).bold()
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(cfg.pCores) },
                            set: {
                                cfg.pCores = Int($0)
                                cfg.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
                            }
                        ), in: 0...Double(info.pCores), step: 1)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("E-cores (efficiency)")
                                .font(.headline)
                            Spacer()
                            Text("\(cfg.eCores)")
                                .font(.title3).bold()
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(cfg.eCores) },
                            set: {
                                cfg.eCores = Int($0)
                                cfg.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
                            }
                        ), in: 0...Double(info.eCores), step: 1)
                    }
                    .padding(.vertical, 4)

                    Text("P+E cannot exceed total cores. Higher P-core share = faster, hotter. E-cores save battery.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Firmware
                Section(header: Text("Firmware").font(.headline)) {
                    Picker("Firmware", selection: $cfg.firmware) {
                        Text("Built-in default").tag("default")
                        ForEach(availableFirmware(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Custom .bin files go in NOVA/firmware/ (Files app → On My iPad → NovaVM).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Actions
                Section {
                    Button("Save") {
                        var c = cfg
                        c.sanitize(maxCores: info.totalCores, maxP: info.pCores, maxE: info.eCores)
                        engine.applyConfig(c)
                        dismiss()
                    }
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .center)

                    Button("Reset to Defaults") {
                        cfg = NovaConfig.default(maxCores: info.totalCores, pCores: info.pCores, eCores: info.eCores)
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("NOVA Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func availableFirmware() -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: NovaFolders.firmwareDir,
            includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "bin" }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
