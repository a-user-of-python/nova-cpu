// ProgramsView.swift — Select a .bin program to auto-run.
// Tap to select, tap the selected one again to deselect (back to shell-only).
// Large type, high contrast.

import SwiftUI
import UniformTypeIdentifiers

struct ProgramsView: View {
    @ObservedObject var engine: NovaVMEngine
    @State private var showingPicker = false
    @State private var folderPrograms: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Currently selected program (with Deselect)
                if let name = engine.selectedProgramName {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { deselect() }) {
                            Label("Deselect", systemImage: "xmark.circle.fill")
                                .font(.headline)
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                } else {
                    Text("No program selected — the Run tab boots NovaShell only.")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                HStack {
                    Text("Programs")
                        .font(.title2).bold()
                    Spacer()
                    Button(action: { refreshPrograms() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)
                    }
                    .accessibilityLabel("Refresh program list")
                }
                .padding(.horizontal)

                Text("Drop .bin files in Files → NovaVM → NOVA → programs. Tap to select, tap the selected one again to deselect.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                if folderPrograms.isEmpty {
                    Text("No programs yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(folderPrograms, id: \.self) { name in
                                Button(action: { toggleSelect(name) }) {
                                    HStack {
                                        Image(systemName: "cpu")
                                            .font(.title3)
                                        Text(name)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Spacer()
                                        if engine.selectedProgramName == name {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.title3)
                                        }
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }

                Button(action: { showingPicker = true }) {
                    Label("Browse Files…", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Programs")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handlePick(result)
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                refreshPrograms()
            }
        }
    }

    /// Tap toggles: select if different, deselect if already selected.
    private func toggleSelect(_ name: String) {
        if engine.selectedProgramName == name {
            deselect()
        } else {
            select(name)
        }
    }

    private func select(_ name: String) {
        let url = NovaFolders.programsDir.appendingPathComponent(name)
        do {
            let data = try Data(contentsOf: url)
            engine.selectedProgramData = data
            engine.selectedProgramName = name
            // Copy to sharedDir so the firmware's `run` command can find it.
            let dest = NovaFolders.sharedDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? data.write(to: dest)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deselect() {
        engine.selectedProgramName = nil
        engine.selectedProgramData = nil
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

    private func handlePick(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Could not access the file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            engine.selectedProgramData = data
            engine.selectedProgramName = name
            // Copy to sharedDir so the firmware's `run` command can find it.
            let dest = NovaFolders.sharedDir.appendingPathComponent(name)
            try? data.write(to: dest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
