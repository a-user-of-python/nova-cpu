// AppSettingsView.swift — App-specific UI settings (NOT VM hardware).
// Console font size, theme, keyboard behavior, haptics, keep-awake.
// Persisted via @AppStorage, shared via @EnvironmentObject.

import SwiftUI

/// App-level preferences. Backed by @AppStorage so they persist across launches.
final class AppSettings: ObservableObject {
    @AppStorage("consoleFontSize") var consoleFontSize: Double = 18
    @AppStorage("consoleTheme") var consoleTheme: String = "dark"
    @AppStorage("keyboardAutocapitalization") var keyboardAutocapitalization: Bool = false
    @AppStorage("keyboardAutocorrection") var keyboardAutocorrection: Bool = false
    @AppStorage("hapticFeedback") var hapticFeedback: Bool = true
    @AppStorage("keepAwake") var keepAwake: Bool = true
}

struct AppSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Console").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Font size")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(settings.consoleFontSize)) pt")
                                .font(.headline)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.consoleFontSize, in: 12...32, step: 1)
                            .accessibilityLabel("Console font size")
                    }
                    .padding(.vertical, 4)

                    Picker("Theme", selection: $settings.consoleTheme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("High Contrast").tag("highContrast")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Keyboard").font(.headline)) {
                    Toggle(isOn: $settings.keyboardAutocapitalization) {
                        Text("Autocapitalization")
                            .font(.headline)
                    }
                    Toggle(isOn: $settings.keyboardAutocorrection) {
                        Text("Autocorrection")
                            .font(.headline)
                    }
                    Text("Keep both OFF for terminal input.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Feedback").font(.headline)) {
                    Toggle(isOn: $settings.hapticFeedback) {
                        Text("Haptic feedback")
                            .font(.headline)
                    }
                    Text("Vibrate on button presses.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Power").font(.headline)) {
                    Toggle(isOn: $settings.keepAwake) {
                        Text("Keep screen awake while VM runs")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
