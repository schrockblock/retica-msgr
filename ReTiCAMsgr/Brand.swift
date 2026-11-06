//
//  Brand.swift
//  ReTiCAMsgr
//

import SwiftUI

/// The app icon's colors: an indigo-violet gradient behind a white speech bubble. `AccentColor`
/// is the gradient's top stop in light mode, lightened in dark mode so tinted text stays legible
/// on black.
enum Brand {
    static let gradient = LinearGradient(
        colors: [Color(.brandTop), Color(.brandBottom)],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// A circle in the brand gradient with the person's initials (or a person glyph), used for the
/// profile row and the address screen.
struct BrandAvatar: View {
    let name: String
    var size: CGFloat = 56

    private var initials: String {
        // First letter of each of the first two words that has one: "SA7SKY (LB)" is "SL", not "S(".
        name.split(separator: " ")
            .compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Brand.gradient)
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
