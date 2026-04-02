import SwiftUI

struct ToastView: View {
    let message: String
    let type: ToastType

    private var icon: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch type {
        case .success: return .appSuccess
        case .error: return .appError
        case .info: return .appAccent
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .font(.appBody)
                .foregroundStyle(Color.appPrimaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .cornerRadius(8)
        .shadow(color: Color.appShadowColor.opacity(0.9), radius: 8, y: 4)
        .padding(.top, 8)
    }
}
