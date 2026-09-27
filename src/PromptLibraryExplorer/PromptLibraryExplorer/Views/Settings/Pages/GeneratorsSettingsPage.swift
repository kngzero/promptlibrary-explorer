import SwiftUI

/// Settings ▸ Generators: where Re-run in ComfyUI and Send to A1111/Forge go.
struct GeneratorsSettingsPage: View {
    @Bindable private var settings = GeneratorSettings.shared

    var body: some View {
        GeneratorServerCard(kind: .comfyUI, baseURL: $settings.comfyBaseURL) {
            Text("Re-run in ComfyUI posts a file's embedded API graph to /prompt, optionally with a new seed or an edited positive prompt. Files with only a UI workflow can't be queued this way.")
        }

        GeneratorServerCard(kind: .a1111, baseURL: $settings.a1111BaseURL) {
            Text("Send to A1111 / Forge posts the prompt and parameters to /sdapi/v1/txt2img and saves the images it returns. Start the server with --api.")
        } extra: {
            SettingsToggleRow(
                title: "Use the file's model by default",
                detail: "Asks the server to switch to the file's checkpoint for each request and switch back afterwards.",
                isOn: $settings.a1111UseFileModel
            )
        }

        SettingsFootnote("The app only connects to these addresses, only when you run a Send or Test action, and never in the background. Use http://127.0.0.1 for a server on this Mac, or the address of a machine on your network.")
    }
}

private struct GeneratorServerCard<Explanation: View, Extra: View>: View {
    let kind: GeneratorKind
    @Binding var baseURL: String
    @ViewBuilder var explanation: Explanation
    @ViewBuilder var extra: Extra

    @State private var isTesting = false
    @State private var result: (message: String, tone: ToastType)?

    init(kind: GeneratorKind, baseURL: Binding<String>, @ViewBuilder explanation: () -> Explanation, @ViewBuilder extra: () -> Extra) {
        self.kind = kind
        _baseURL = baseURL
        self.explanation = explanation()
        self.extra = extra()
    }

    var body: some View {
        SettingsCard(title: kind.title, icon: kind == .comfyUI ? "point.3.connected.trianglepath.dotted" : "paintbrush.pointed") {
            explanation
                .font(.appCallout)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Base URL")
                    .font(.appCaptionEmphasis)
                    .foregroundStyle(Color.appMuted)
                HStack(spacing: AppSpacing.sm) {
                    TextField("Base URL", text: $baseURL, prompt: Text(kind.defaultBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .font(.appMono)
                        .labelsHidden()
                        .onChange(of: baseURL) { _, _ in result = nil }
                    if baseURL != kind.defaultBaseURL {
                        Button {
                            baseURL = kind.defaultBaseURL
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.appCallout)
                        }
                        .buttonStyle(AppIconButtonStyle(width: 24, height: 24, cornerRadius: AppRadius.sm))
                        .help("Reset to \(kind.defaultBaseURL)")
                        .accessibilityLabel("Reset to default address")
                    }
                }
            }

            extra

            HStack(spacing: AppSpacing.md) {
                SettingsFilledButton(title: "Test Connection", isBusy: isTesting, isEnabled: !baseURL.isEmpty) {
                    await test()
                }
                if let result {
                    Label(result.message, systemImage: result.tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.appCallout)
                        .foregroundStyle(result.tone == .success ? Color.labelGreenText : Color.labelRedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let message = try await PromptWorkflowController.shared.testConnection(kind)
            result = (message, .success)
        } catch {
            result = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }
}

extension GeneratorServerCard where Extra == EmptyView {
    init(kind: GeneratorKind, baseURL: Binding<String>, @ViewBuilder explanation: () -> Explanation) {
        self.init(kind: kind, baseURL: baseURL, explanation: explanation, extra: { EmptyView() })
    }
}
