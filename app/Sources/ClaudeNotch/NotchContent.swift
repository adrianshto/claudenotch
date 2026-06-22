import SwiftUI

/// The tappable notch content: SF Symbol + title + subtitle.
struct NotchContent: View {
    let title: String
    let message: String
    let systemImage: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .contentShape(Rectangle())   // whole area is hit-testable
        // AppKit click target instead of .onTapGesture — reliable in the
        // non-key notch panel (see ClickCatcher).
        .overlay(ClickCatcher(onClick: onTap))
    }
}
