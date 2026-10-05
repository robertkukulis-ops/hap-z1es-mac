import SwiftUI

/// A blue menu screen like the player's own: white text on deep blue.
enum ScreenTheme {
    static let blue = Color(red: 0.08, green: 0.22, blue: 0.52)
    static let blueDeep = Color(red: 0.03, green: 0.10, blue: 0.30)
    static let dim = Color(red: 0.72, green: 0.82, blue: 0.96)
    static let divider = Color(red: 0.26, green: 0.42, blue: 0.74)
}

extension View {
    /// Everything inside the screen: dark controls, white accents, blue background behind
    /// lists and tables.
    func sonyScreen() -> some View {
        self
            .environment(\.colorScheme, .dark)
            .tint(.white)
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [ScreenTheme.blue, ScreenTheme.blueDeep], startPoint: .top, endPoint: .bottom))
    }

    /// What the HAP's ENTER button does while this view is on screen.
    func onRackEnter(_ action: @escaping @MainActor () -> Void) -> some View {
        modifier(RackEnterModifier(action: action))
    }
}

private struct RackEnterModifier: ViewModifier {
    @Environment(RackState.self) private var rack
    @State private var id = UUID()
    @State private var box = EnterActionBox()
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        box.action = action  // runs whenever the page's data changes
        return content
            .onAppear { rack.setEnter(id, box.run) }
            .onDisappear { rack.clearEnter(id) }
    }
}
