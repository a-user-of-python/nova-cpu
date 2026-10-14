// FirmwareView.swift — Firmware selection.
// Toggle firmware on/off, pick custom firmware, tap the selected one again
// to deselect and return to the built-in NovaShell default.

import SwiftUI
import UniformTypeIdentifiers

struct FirmwareView: View {
    @ObservedObject var engine: NovaVMEngine
    @State private var showingPicker = false
    @State private var folderFirmwares: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Toggle(isOn: $engine.useFirmware) {
                        Text("Use Firmware")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .padding(.horizontal)

                    if engine.useFirmware {
                        Toggle(isOn: $engine.useCustomFirmware) {
                            Text("Custom firmware")
                                .font(.headline)
                        }
                        .padding(.horizontal)

                        if engine.useCustomFirmware {
                            HStack {
                                Text("Firmware Files")
                                    .font(.headline)
                                Spacer()
                                Button(action: { refreshFirmwares() }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.title3)
                                }
                                .accessibilityLabel("Refresh firmware list")
                            }
                            .padding(.horizontal)

                            Text("Drop .bin files in Files → NovaVM → NOVA → firmware. Tap the selected firmware again to deselect it and return to the built-in default.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)

                            if folderFirmwares.isEmpty {
                                Text("No firmware files yet")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(folderFirmwares, id: \.self) { name in
                                    Button(action: { toggleFirmware(name) }) {
                                        HStack {
                                            Image(systemName: "cpu")
                                                .font(.title3)
                                            Text(name)
                                                .font(.headline)
                                                .lineLimit(1)
                                            Spacer()
                                            if engine.customFirmwareName == name {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.accentColor)
                                                    .font(.title3)
                                            }
                                        }
                                        .padding()
                                        .background(Color(.secondarySystemBackground))
                                        .cornerRadius(10)
                                        .padding(.horizontal)
                                    }
                                }
                            }

                            Button("Choose Firmware File…") {
                                showingPicker = true
                            }
                            .font(.headline)
                            .padding()

                            if let name = engine.customFirmwareName {
                                Text("Selected: \(name)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Built-in NovaShell (default)")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    } else {
                        Text("Firmware disabled — programs run directly with no scheduler.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Firmware")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleFirmwarePick(result)
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                refreshFirmwares()
            }
        }
    }

    /// Tap toggles: select if different, deselect (back to built-in) if same.
    private func toggleFirmware(_ name: String) {
        if engine.customFirmwareName == name {
            engine.customFirmwareData = nil
            engine.customFirmwareName = nil
            engine.useCustomFirmware = false
        } else {
            loadFirmwareFromFolder(name)
        }
    }

    /// List .bin files in NOVA/firmware/ (Files app → NovaVM → NOVA → firmware)
    private func refreshFirmwares() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: NovaFolders.firmwareDir,
            includingPropertiesForKeys: nil)) ?? []
        folderFirmwares = files
            .filter { $0.pathExtension.lowercased() == "bin" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    private func loadFirmwareFromFolder(_ name: String) {
        let url = NovaFolders.firmwareDir.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else {
                errorMessage = "Firmware image exceeds 1MB."
                return
            }
            engine.customFirmwareData = data
            engine.customFirmwareName = name
            engine.useCustomFirmware = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFirmwarePick(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            // SECURITY: Read the firmware NOW while we hold security-scoped access.
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Could not access the firmware file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            guard data.count <= 1024 * 1024 else {
                errorMessage = "Firmware image exceeds 1MB."
                return
            }
            engine.customFirmwareData = data
            engine.customFirmwareName = url.lastPathComponent
            engine.useCustomFirmware = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
