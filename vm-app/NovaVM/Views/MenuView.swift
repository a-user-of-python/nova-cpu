// MenuView.swift — The blank menu. One firmware toggle, program loading,
// and a Run button. Large type, high contrast, minimal clutter.

import SwiftUI
import UniformTypeIdentifiers

struct MenuView: View {
    @ObservedObject var engine: NovaVMEngine
    @State private var showingProgramPicker = false
    @State private var showingFirmwarePicker = false
    @State private var showingVM = false
    @State private var errorMessage: String?
    @State private var programName: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 28) {
                // Title
                Text("NOVA")
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .padding(.top, 40)
                Text("Stack-machine VM")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Spacer()

                // Firmware toggle — the centerpiece
                VStack(spacing: 12) {
                    Toggle(isOn: $engine.useFirmware) {
                        Text("Use Firmware")
                            .font(.title2)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .padding(.horizontal, 40)

                    if engine.useFirmware {
                        Toggle(isOn: $engine.useCustomFirmware) {
                            Text("Custom firmware")
                                .font(.headline)
                        }
                        .padding(.horizontal, 40)

                        if engine.useCustomFirmware {
                            Button("Choose Firmware File…") {
                                showingFirmwarePicker = true
                            }
                            .font(.headline)
                            if let url = engine.customFirmwareURL {
                                Text(url.lastPathComponent)
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

                // Program loading
                VStack(spacing: 12) {
                    Button(action: { showingProgramPicker = true }) {
                        Label("Load Program…", systemImage: "folder")
                            .font(.title2)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    if let name = programName {
                        Text(name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 24)

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

                Spacer()

                Text(engine.statusLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
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
            engine.customFirmwareURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
