// MenuView.swift — The blank menu. One firmware toggle, program loading,
// and a Run button. Large type, high contrast, minimal clutter.

import SwiftUI
import UniformTypeIdentifiers

struct MenuView: View {
    @ObservedObject var engine: NovaVMEngine
    @State private var showingProgramPicker = false
    @State private var showingFirmwarePicker = false
    @State private var showingVM = false
    @State private var showingSettings = false
    @State private var errorMessage: String?
    @State private var programName: String?
    @State private var folderPrograms: [String] = []
    @State private var folderFirmwares: [String] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Title — scales down on narrow screens
                    Text("NOVA")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.top, 20)
                    Text("Stack-machine VM")
                        .font(.title3)
                        .foregroundColor(.secondary)

                // Firmware toggle — the centerpiece
                VStack(spacing: 12) {
                    Toggle(isOn: $engine.useFirmware) {
                        Text("Use Firmware")
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .padding(.horizontal, 20)

                    if engine.useFirmware {
                        Toggle(isOn: $engine.useCustomFirmware) {
                            Text("Custom firmware")
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 20)

                        if engine.useCustomFirmware {
                            // Firmware list from NOVA/firmware/ folder
                            HStack {
                                Text("Firmware Files")
                                    .font(.headline)
                                Spacer()
                                Button(action: { refreshFirmwares() }) {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .padding(.horizontal, 20)

                            Text("Drop .bin files in Files → NovaVM → NOVA → firmware")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)

                            if folderFirmwares.isEmpty {
                                Text("No firmware files yet")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(folderFirmwares, id: \.self) { name in
                                    Button(action: { loadFirmwareFromFolder(name) }) {
                                        HStack {
                                            Image(systemName: "cpu")
                                            Text(name)
                                                .font(.headline)
                                                .lineLimit(1)
                                            Spacer()
                                            if engine.customFirmwareName == name {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.accentColor)
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                    }
                                }
                            }

                            Button("Choose Firmware File… (picker)") {
                                showingFirmwarePicker = true
                            }
                            .font(.subheadline)
                            if let name = engine.customFirmwareName {
                                Text("Selected: \(name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Built-in default firmware")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal, 24)

                // Program loading — direct from Files app folder
                VStack(spacing: 12) {
                    HStack {
                        Text("Programs")
                            .font(.title2).bold()
                        Spacer()
                        Button(action: { refreshPrograms() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.title3)
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("Drop .bin files in Files → NovaVM → NOVA → programs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 24)

                    if folderPrograms.isEmpty {
                        Text("No programs yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(folderPrograms, id: \.self) { name in
                            Button(action: { loadFromFolder(name) }) {
                                HStack {
                                    Image(systemName: "cpu")
                                    Text(name)
                                        .font(.headline)
                                    Spacer()
                                    if programName == name {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 24)
                        }
                    }

                    Button(action: { showingProgramPicker = true }) {
                        Label("Browse Files…", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)
                }

                // Run
                Button(action: {
                    showingVM = true
                    engine.start()
                }) {
                    Label("Run", systemImage: "play.fill")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(programName == nil ? Color.gray : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(programName == nil)
                .padding(.horizontal, 24)

                Text(engine.statusLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                // Settings — always visible, no Spacer pushing it off
                Button(action: { showingSettings = true }) {
                    Label("Settings", systemImage: "gear")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                }
            }
            .navigationBarHidden(true)
            .fileImporter(
                isPresented: $showingProgramPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleProgramPick(result)
            }
            .fileImporter(
                isPresented: $showingFirmwarePicker,
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
            .fullScreenCover(isPresented: $showingVM) {
                VMView(engine: engine)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(engine: engine)
            }
            .onAppear {
                refreshPrograms()
                refreshFirmwares()
            }
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

    /// Load firmware directly from the NOVA/firmware folder (no picker).
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// List .bin files in NOVA/programs/ (Files app → NovaVM → NOVA → programs)
    private func refreshPrograms() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: NovaFolders.programsDir,
            includingPropertiesForKeys: nil)) ?? []
        folderPrograms = files
            .filter { $0.pathExtension.lowercased() == "bin" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Load a program directly from the NOVA/programs folder (no picker).
    private func loadFromFolder(_ name: String) {
        let url = NovaFolders.programsDir.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            try engine.loadProgram(data)
            programName = name
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleProgramPick(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Could not access the file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            try engine.loadProgram(data)
            programName = url.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFirmwarePick(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            // SECURITY: Read the firmware NOW while we hold security-scoped access.
            // Storing the URL alone is unsafe — the scope expires when this
            // completion handler returns, and later reads would be denied.
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
