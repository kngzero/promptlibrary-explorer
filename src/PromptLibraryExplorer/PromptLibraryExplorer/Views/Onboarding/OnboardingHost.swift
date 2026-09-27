import SwiftUI

/// Presents the welcome tour on the main window (first launch, Help ▸ Welcome
/// Tour…) and runs a page's "Try it" once the sheet has gone. Applied once in the
/// App file, like the other sheet hosts.
struct OnboardingHost: ViewModifier {
    @Environment(ExplorerViewModel.self) private var vm
    @Bindable private var onboarding = OnboardingController.shared

    /// Lets the window settle (and a restored folder open) before the tour.
    private static let firstLaunchDelay: Duration = .milliseconds(900)

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $onboarding.isTourPresented, onDismiss: runPendingCommand) {
                WelcomeTourView()
                    .environment(vm)
            }
            .task {
                vm.configureOnboardingTips()
                try? await Task.sleep(for: Self.firstLaunchDelay)
                guard !vm.isAnyModalOpen else {
                    return
                }
                onboarding.presentTourIfFirstLaunch()
            }
    }

    private func runPendingCommand() {
        guard let command = onboarding.takePendingCommand() else { return }
        // The sheet's window is still closing; a new sheet needs it gone.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard vm.canPerform(command) else { return }
            vm.perform(command)
        }
    }
}

extension View {
    func onboardingHost() -> some View {
        modifier(OnboardingHost())
    }
}
