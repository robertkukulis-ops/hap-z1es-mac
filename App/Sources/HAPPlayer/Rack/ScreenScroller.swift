import AppKit

/// The VOLUME knob scrolls whatever list or grid is on the screen: it finds the scroll view
/// under the middle of the screen and gives it an ordinary scroll-wheel movement, so the page
/// scrolls exactly as with a mouse.
enum ScreenScroller {
    /// `points` > 0 moves the content up (shows what's further down).
    @MainActor static func scroll(by points: CGFloat, screenFrame: CGRect) {
        guard !screenFrame.isEmpty,
              // The window the knob was turned in (it needn't be the active one: the scroll
              // wheel works over a window in the background too).
              let window = NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView else { return }
        var point = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        if !content.isFlipped { point.y = content.bounds.height - point.y }  // SwiftUI measures from the top
        let inSuperview = content.convert(point, to: content.superview)
        guard let hit = content.hitTest(inSuperview),
              let scrollView = (hit as? NSScrollView) ?? hit.enclosingScrollView,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(-points), wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent)
        else { return }
        scrollView.scrollWheel(with: event)
    }
}
