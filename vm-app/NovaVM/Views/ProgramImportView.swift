// ProgramImportView.swift — Import .bin programs from the nova-programs GitHub repo.
// Fetches the repo tree, lists .bin files, downloads on tap to the shared folder.

import SwiftUI

struct ProgramImportView: View {
    @Environment(\.dismiss) var dismiss
    @State private var programs: [String] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var downloading: String?

    let repo = "a-user-of-python/nova-programs"

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading programs...")
                        .font(.title2)
                } else if let err = errorMsg {
                    VStack(spacing: 16) {
                        Text("Failed to load")
                            .font(.title)
                        Text(err)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Retry") { loadPrograms() }
                            .font(.title2)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                } else if programs.isEmpty {
                    Text("No programs found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                } else {
                    List(programs, id: \.self) { prog in
                        Button(action: { downloadProgram(prog) }) {
                            HStack {
                                Image(systemName: "cpu")
                                    .font(.title2)
                                Text(prog)
                                    .font(.title3)
                                Spacer()
                                if downloading == prog {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title2)
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(downloading != nil)
                    }
                }
            }
            .navigationTitle("Import Programs")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.title3)
                }
            }
        }
        .onAppear { loadPrograms() }
    }

    private func loadPrograms() {
        isLoading = true
        errorMsg = nil
        // Use GitHub API to get recursive tree
        let urlStr = "https://api.github.com/repos/\(repo)/git/trees/main?recursive=1"
        guard let url = URL(string: urlStr) else {
            errorMsg = "Invalid URL"
            isLoading = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, err in
            DispatchQueue.main.async {
                isLoading = false
                if let err = err {
                    errorMsg = err.localizedDescription
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tree = json["tree"] as? [[String: Any]] else {
                    errorMsg = "Failed to parse repo tree"
                    return
                }
                // Filter for .bin files, get just the filename
                let bins = tree.compactMap { $0["path"] as? String }
                    .filter { $0.hasSuffix(".bin") }
                    .map { ($0 as NSString).lastPathComponent }
                    .sorted()
                programs = bins
            }
        }.resume()
    }

    private func downloadProgram(_ filename: String) {
        downloading = filename
        // Find the full path in the repo (we need it for raw URL)
        // For simplicity, try common locations: try the filename directly first,
        // then search. Actually, let's fetch the tree again to get the full path.
        let treeUrlStr = "https://api.github.com/repos/\(repo)/git/trees/main?recursive=1"
        guard let treeUrl = URL(string: treeUrlStr) else {
            downloading = nil
            return
        }
        URLSession.shared.dataTask(with: treeUrl) { data, _, _ in
            var fullPath: String?
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tree = json["tree"] as? [[String: Any]] {
                fullPath = (tree.compactMap { $0["path"] as? String }
                    .first { ($0 as NSString).lastPathComponent == filename })
            }
            guard let path = fullPath else {
                DispatchQueue.main.async { downloading = nil }
                return
            }
            let rawUrlStr = "https://raw.githubusercontent.com/\(repo)/main/\(path)"
            guard let rawUrl = URL(string: rawUrlStr) else {
                DispatchQueue.main.async { downloading = nil }
                return
            }
            URLSession.shared.dataTask(with: rawUrl) { data, _, err in
                DispatchQueue.main.async {
                    downloading = nil
                    if let err = err {
                        errorMsg = "Download failed: \(err.localizedDescription)"
                        return
                    }
                    guard let data = data else {
                        errorMsg = "No data received"
                        return
                    }
                    // Save to shared folder
                    let dest = NovaFolders.sharedDir.appendingPathComponent(filename)
                    do {
                        try data.write(to: dest)
                        // Success! Dismiss or show confirmation.
                        dismiss()
                    } catch {
                        errorMsg = "Save failed: \(error.localizedDescription)"
                    }
                }
            }.resume()
        }.resume()
    }
}
