import AppKit

/// One menu row that the app draws itself, because a click on a standard
/// `NSMenuItem` ends the menu and this row's answer arrives after it would
/// have.
///
/// AppKit dismisses a menu on *selection*: the click that starts **Check for
/// Updates…** closed the menu, the check took one to three seconds, and the
/// answer was visible only on the next open — which is what Luis hit on 8
/// September ("ideally the menu would stay open during that time"). A view in a
/// menu item is responsible for its own event handling (`NSMenuItem.view`), and
/// that is the only place a click on a menu row can be handled without ending
/// the tracking session. The other half of the same design is that nothing
/// rebuilds the menu while it is up: `removeAllItems()` is what closes a
/// tracking menu, measured in `Prototypes/T8Probe` (12 in-place mutations of an
/// open menu, 0 closes).
///
/// Everything a standard row gets for free is drawn here, and every colour
/// comes from a system colour rather than from the light frames this was
/// designed against — a row hard-coded to those frames reads as a bug at 19:00
/// in dark appearance.
final class MenuRowView: NSView {
    /// The probe's metrics, because they are the ones in the frames Luis chose:
    /// the image column at 14, the title at 38, a 22-point row.
    private static let imageX: CGFloat = 14
    private static let titleX: CGFloat = 38
    private static let height: CGFloat = 22
    /// Room to the right of the longest title, so the highlight does not stop
    /// against the last letter.
    private static let trailing: CGFloat = 24

    private let title: String
    private let symbolName: String?
    private let spinner: NSProgressIndicator?
    /// Nil is a row with nothing to click: no highlight, and a click that does
    /// nothing. It says nothing about the ink — see `isUnavailable`.
    private let onClick: (() -> Void)?
    /// An action row with nothing to do right now, in disabled ink.
    ///
    /// Not the same as having no handler, and the difference is the repo's own
    /// rule: an information row has no action either and is deliberately NOT
    /// dimmed, because "2 claims" in disabled-gray reads as "nothing here"
    /// (`MenuModel.MenuItemModel.action`). "Checking for updates…" is an
    /// information row and keeps its ink; "Check for Updates…" while that check
    /// runs is unavailable and loses it. Drawn from `onClick == nil` alone, the
    /// spinner row came out gray — which is how this comment exists.
    private let isUnavailable: Bool
    private var isHovered = false

    init(title: String, symbol: String?, spinning: Bool, isUnavailable: Bool = false,
         onClick: (() -> Void)?) {
        self.title = title
        self.symbolName = symbol
        self.isUnavailable = isUnavailable
        self.onClick = onClick
        if spinning {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            // Menu tracking runs in its own run-loop mode, and an animation
            // driven from a background thread inside a tracking menu is the
            // documented hazard there (AppKit, Views in Menu Items: a timer has
            // to be added to the run loop in `NSEventTrackingRunLoopMode`). So
            // the animation stays on the main thread.
            //
            // It was first credited with more than that, and the record is
            // corrected here rather than left to stand: a menu opened with this
            // row already in it dismissed itself after 150–400 ms three times
            // in a row, this line was added, and the dismissal stopped — n=2
            // against n=3. Taking the line out again today does NOT bring the
            // dismissal back (six runs, both delays), so the cause of those
            // three is not known and this is not the fix for it.
            // `Prototypes/T20Frames capture-checking 0.4` is the guard that
            // would catch it coming back, whatever it was.
            indicator.usesThreadedAnimation = false
            self.spinner = indicator
        } else {
            self.spinner = nil
        }

        let font = NSFont.menuFont(ofSize: 0)
        let width = Self.titleX
            + (title as NSString).size(withAttributes: [.font: font]).width
            + Self.trailing
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: Self.height))

        if let spinner {
            spinner.frame = NSRect(x: Self.imageX, y: 3, width: 16, height: 16)
            addSubview(spinner)
        }

        // A menu item with a view exposes the view, not the item, so the label
        // a plain row carried for free has to be set here or VoiceOver reads an
        // unnamed group where a menu item used to be.
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(!isUnavailable)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MenuRowView is code-only") }

    /// "When the menu is opened, the view is added to a window; when the menu is
    /// closed the view is removed from the window. If you are using a custom
    /// view, you can therefore override `viewDidMoveToWindow` as a convenient
    /// place to start or stop animation" (AppKit, Views in Menu Items).
    ///
    /// It is also what stops the spinner when this row is swapped out for the
    /// answer while the menu is still up — that too takes the view out of the
    /// window, so there is one mechanism here and not two.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let spinner else { return }
        if window == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard onClick != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// The click, and the whole reason this view exists: it runs the handler
    /// and returns. Nothing here calls `cancelTracking`, so the menu is still
    /// open when the check that this click starts comes back.
    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        isHovered = false
        needsDisplay = true
        onClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Keyboard highlight as well as the pointer's: AppKit sets
        // `isHighlighted` on the item, and a view that only watched its
        // tracking area would draw an un-highlighted row under the selection.
        let highlighted = isHovered || (enclosingMenuItem?.isHighlighted ?? false)
        if highlighted, onClick != nil {
            // The shape macOS has drawn a highlighted menu row with since Big
            // Sur: the accent colour in a rounded rect inset from the row's
            // edges, not `selectedMenuItemColor` — which is the pre-Big-Sur
            // full-bleed fill and deprecated for saying so.
            NSColor.selectedContentBackgroundColor.setFill()
            let box = bounds.insetBy(dx: 5, dy: 1)
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
        let ink: NSColor = {
            if isUnavailable { return .disabledControlTextColor }
            return highlighted ? .selectedMenuItemTextColor : .labelColor
        }()

        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            let box = NSRect(x: Self.imageX, y: 3, width: 16, height: 16)
            // Tinted the same way the title is, so the row is one thing in
            // every appearance and under the highlight.
            let tinted = NSImage(size: box.size, flipped: false) { rect in
                image.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: box)
        }

        let font = NSFont.menuFont(ofSize: 0)
        let text = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: ink,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: Self.titleX, y: (Self.height - size.height) / 2))
    }
}
