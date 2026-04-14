import InputMethodKit
import BurmeseIMECore

/// Shared custom candidates panel — created by AppDelegate in the app target.
/// Nil in the extension target (where it is never set), so all calls are safe no-ops there.
var sharedCandidatePanelController: BurmeseCandidatePanelController?

/// Primary InputMethodKit controller for the Burmese IME extension.
///
/// Lifecycle:
///   - One instance is created per input session by IMKServer.
///   - `handle(_:client:)` receives every key-down event while the IME is active.
///   - `commitComposition(_:)` is called by the system when the client requests a
///     forced commit (e.g. window focus loss).
///   - A custom candidate panel is kept in sync with the selected candidate index.
@objc(BurmeseInputController)
class BurmeseInputController: IMKInputController {
    private static let sharedCandidateStore: any CandidateStore = {
        if let lexiconURL = locateLexiconURL(),
           let store = SQLiteCandidateStore(path: lexiconURL.path) {
            return store
        }
        return EmptyCandidateStore()
    }()

    private static func locateLexiconURL() -> URL? {
        let bundles = [Bundle(for: BurmeseInputController.self), Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(forResource: "BurmeseLexicon", withExtension: "sqlite") {
                return url
            }
        }
        return nil
    }

    // MARK: - State

    private let engine = BurmeseEngine(candidateStore: BurmeseInputController.sharedCandidateStore)
    private var state = CompositionState()

    /// Most recent anchor rect returned by the client. Cached so transient
    /// `firstRect` failures during a composition session don't snap the panel
    /// to a different location on every keystroke.
    private var lastAnchorRect: NSRect?

    // MARK: - IMKInputController overrides

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }

        let keyCode = event.keyCode

        switch keyCode {
        case 53: // Escape — commit raw latin
            commitRaw(client: sender)
            return true

        case 48: // Tab / Shift+Tab — cycle candidate selection in the panel
            guard state.isActive, !state.candidates.isEmpty else { return false }
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            cycleCandidates(delta: delta)
            return true

        case 36, 76: // Return / Enter — commit selection
            guard state.isActive else { return false }
            commitSelection(client: sender)
            return true

        case 49: // Space — commit selection (first press) or insert space (second)
            if state.isActive {
                commitSelection(client: sender)
            } else {
                (sender as? IMKTextInput)?.insertText(
                    " ",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            return true

        case 51: // Backspace
            if !state.rawBuffer.isEmpty {
                state.rawBuffer.removeLast()
                state = engine.update(buffer: state.rawBuffer, context: state.committedContext)
                updateMarkedText(client: sender)
                return true
            }
            return false

        default:
            break
        }

        let chars: String = {
            let direct = event.characters ?? ""
            if !direct.isEmpty {
                return direct
            }
            return event.charactersIgnoringModifiers ?? ""
        }()
        guard !chars.isEmpty else { return false }

        if let digit = Int(chars), (1...5).contains(digit) {
            if event.modifierFlags.contains(.option) || state.isActive {
                if selectCandidateShortcut(digit - 1, client: sender) {
                    return true
                }
            }
        }

        // Plain digits are no longer part of compose mode. Commit the current
        // candidate first, then let the digit reach the client unchanged.
        let decimalDigits = CharacterSet.decimalDigits
        if chars.unicodeScalars.allSatisfy({ decimalDigits.contains($0) }) {
            if state.isActive {
                commitSelection(client: sender)
            }
            return false
        }

        // Composing characters: a-z, +, *, ', :, .
        let composingSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz+*':.")
        if chars.unicodeScalars.allSatisfy({ composingSet.contains($0) }) {
            state.rawBuffer += chars.lowercased()
            state = engine.update(buffer: state.rawBuffer, context: state.committedContext)
            updateMarkedText(client: sender)
            return true
        }

        // Pass-through characters commit the pending candidate first.
        if state.isActive {
            commitSelection(client: sender)
        }
        return false
    }

    override func commitComposition(_ sender: Any!) {
        commitSelection(client: sender)
    }

    override func deactivateServer(_ sender: Any!) {
        hideCandidatePanel()
        lastAnchorRect = nil
        super.deactivateServer(sender)
    }

    override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool {
        switch aSelector {
        case #selector(NSResponder.insertTab(_:)):
            guard state.isActive, !state.candidates.isEmpty else { return false }
            cycleCandidates(delta: 1)
            return true

        case #selector(NSResponder.insertBacktab(_:)):
            guard state.isActive, !state.candidates.isEmpty else { return false }
            cycleCandidates(delta: -1)
            return true

        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            guard state.isActive else { return false }
            commitSelection(client: sender)
            return true

        case #selector(NSResponder.deleteBackward(_:)):
            guard !state.rawBuffer.isEmpty else { return false }
            state.rawBuffer.removeLast()
            state = engine.update(buffer: state.rawBuffer, context: state.committedContext)
            updateMarkedText(client: sender)
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            guard state.isActive else { return false }
            commitRaw(client: sender)
            return true

        default:
            return false
        }
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        state.candidates.map(\.surface)
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        let surface = candidateString.string
        if let idx = state.candidates.firstIndex(where: { $0.surface == surface }) {
            state.selectedCandidateIndex = idx
        }
        guard let activeClient = client() else { return }
        commitSelection(client: activeClient)
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        let surface = candidateString.string
        if let idx = state.candidates.firstIndex(where: { $0.surface == surface }) {
            state.selectedCandidateIndex = idx
        }
    }

    // MARK: - Private helpers

    /// Advance the candidate selection by `delta` and highlight it in the panel.
    /// The marked text (raw latin buffer) is intentionally left unchanged —
    /// only the panel highlight moves. Space/Enter commits the highlighted candidate.
    private func cycleCandidates(delta: Int) {
        let count = state.candidates.count
        state.selectedCandidateIndex = (state.selectedCandidateIndex + delta + count) % count
        sharedCandidatePanelController?.updateSelection(selectedIndex: state.selectedCandidateIndex)
    }

    private func updateMarkedText(client sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        let display = state.rawBuffer
        let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: NSRange(location: NSNotFound, length: 0))
        client.setMarkedText(
            NSAttributedString(string: display, attributes: attrs as? [NSAttributedString.Key: Any]),
            selectionRange: NSRange(location: display.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        if state.candidates.isEmpty {
            hideCandidatePanel()
        } else {
            showCandidatePanel()
        }
    }

    private func commitSelection(client sender: Any!) {
        guard state.isActive else { return }
        let output = engine.commit(state: state)
        (sender as? IMKTextInput)?.insertText(
            output,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let newContext = Array((state.committedContext + [output]).suffix(3))
        state = CompositionState(committedContext: newContext)
        hideCandidatePanel()
        lastAnchorRect = nil
    }

    private func commitRaw(client sender: Any!) {
        guard state.isActive else { return }
        let raw = state.rawBuffer
        (sender as? IMKTextInput)?.insertText(
            raw,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        state = CompositionState(committedContext: state.committedContext)
        hideCandidatePanel()
        lastAnchorRect = nil
    }

    private func selectCandidateShortcut(_ index: Int, client sender: Any!) -> Bool {
        guard state.isActive, index >= 0, index < state.candidates.count else { return false }
        state.selectedCandidateIndex = index
        commitSelection(client: sender)
        return true
    }

    private func showCandidatePanel() {
        guard let panel = sharedCandidatePanelController else { return }
        panel.delegate = self
        panel.show(
            candidates: state.candidates,
            selectedIndex: state.selectedCandidateIndex,
            anchorRect: candidateAnchorRect()
        )
    }

    private func hideCandidatePanel() {
        if sharedCandidatePanelController?.delegate === self {
            sharedCandidatePanelController?.delegate = nil
        }
        sharedCandidatePanelController?.hide()
    }

    private func candidateAnchorRect() -> NSRect? {
        // Use the IMKTextInput proxy directly — it declares firstRect/markedRange/selectedRange.
        // Casting to NSTextInputClient is unreliable because the IMK proxy forwards selectors
        // rather than declaring structural conformance, so `as? NSTextInputClient` can miss.
        guard let textClient = client() else { return lastAnchorRect }

        let markedRange = textClient.markedRange()
        let selectedRange = textClient.selectedRange()

        // Preferred ranges, in order of reliability for placing a candidate panel
        // right at the text cursor during marked-text composition.
        var rangesToTry: [NSRange] = []

        if markedRange.location != NSNotFound {
            // Start-of-composition insertion point — matches where the text caret is drawn.
            rangesToTry.append(NSRange(location: markedRange.location, length: 0))
            if markedRange.length > 0 {
                // First glyph of the marked text — non-zero-length fallback for clients that
                // return NSZeroRect for zero-length queries.
                rangesToTry.append(NSRange(location: markedRange.location, length: 1))
                rangesToTry.append(markedRange)
            }
        }

        if selectedRange.location != NSNotFound {
            rangesToTry.append(NSRange(location: selectedRange.location, length: 0))
            if selectedRange.length > 0 {
                rangesToTry.append(selectedRange)
            }
            if selectedRange.location > 0 {
                rangesToTry.append(NSRange(location: selectedRange.location - 1, length: 1))
            }
        }

        for range in rangesToTry {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let rect = textClient.firstRect(forCharacterRange: range, actualRange: &actualRange)
            // firstRect returns NSZeroRect (or a rect with zero size at 0,0) on failure.
            guard rect.size.width > 0 || rect.size.height > 0 else { continue }

            if let resolved = rectIfOnScreen(rect) {
                lastAnchorRect = resolved
                return resolved
            }
        }

        // Preserve the last known good position so transient failures during a single
        // composition session don't cause the panel to jump to a random fallback.
        return lastAnchorRect
    }

    /// Validate a rect returned by `firstRect` and normalise it into AppKit screen
    /// coordinates (bottom-left origin). Some text clients return CG-style
    /// (top-left origin, Y down) coordinates; this also handles that case.
    private func rectIfOnScreen(_ rect: NSRect) -> NSRect? {
        if NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
            return rect
        }
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            let flipped = NSRect(
                x: rect.minX,
                y: primary.frame.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            if NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) {
                return flipped
            }
        }
        return nil
    }
}

extension BurmeseInputController: BurmeseCandidatePanelControllerDelegate {
    func candidatePanelController(_ controller: BurmeseCandidatePanelController, didCommitCandidateAt index: Int) {
        guard state.isActive, index >= 0, index < state.candidates.count else { return }
        state.selectedCandidateIndex = index
        guard let activeClient = client() else { return }
        commitSelection(client: activeClient)
    }
}

protocol BurmeseCandidatePanelControllerDelegate: AnyObject {
    func candidatePanelController(_ controller: BurmeseCandidatePanelController, didCommitCandidateAt index: Int)
}

final class BurmeseCandidatePanelController: NSObject {
    weak var delegate: BurmeseCandidatePanelControllerDelegate?

    private let panel: BurmeseCandidatePanelWindow
    private let backgroundView = NSVisualEffectView()
    private let stackView = NSStackView()
    private var itemViews: [BurmeseCandidateItemView] = []

    override init() {
        panel = BurmeseCandidatePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func show(candidates: [Candidate], selectedIndex: Int, anchorRect: NSRect?) {
        rebuildItemViews(candidates: candidates, selectedIndex: selectedIndex)
        panel.contentView?.layoutSubtreeIfNeeded()
        let contentSize = backgroundView.fittingSize
        panel.setContentSize(contentSize)
        positionPanel(anchorRect: anchorRect, panelSize: contentSize)
        panel.orderFrontRegardless()
    }

    func updateSelection(selectedIndex: Int) {
        for (index, itemView) in itemViews.enumerated() {
            itemView.isSelectedCandidate = index == selectedIndex
            let hideSeparator = index == 0
                || index == selectedIndex
                || (index - 1) == selectedIndex
            itemView.showsSeparator = !hideSeparator
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false

        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
        ])

        panel.contentView = backgroundView
    }

    private func rebuildItemViews(candidates: [Candidate], selectedIndex: Int) {
        for itemView in itemViews {
            stackView.removeArrangedSubview(itemView)
            itemView.removeFromSuperview()
        }
        itemViews.removeAll(keepingCapacity: true)

        for (index, candidate) in candidates.enumerated() {
            let itemView = BurmeseCandidateItemView()
            itemView.candidateIndex = index
            itemView.target = self
            itemView.action = #selector(candidateItemPressed(_:))
            itemView.configure(
                title: candidate.surface,
                selected: index == selectedIndex,
                showsSeparator: index > 0 && index != selectedIndex && (index - 1) != selectedIndex
            )
            stackView.addArrangedSubview(itemView)
            itemViews.append(itemView)
        }

        // Force all rows to match the widest row so the selection highlight spans the full width.
        stackView.layoutSubtreeIfNeeded()
        let widest = itemViews.map { $0.intrinsicContentSize.width }.max() ?? 0
        for itemView in itemViews {
            itemView.widthConstraint.constant = widest
        }
    }

    private func positionPanel(anchorRect: NSRect?, panelSize: NSSize) {
        // If we have no anchor AND the panel is already visible, leave it where it is
        // rather than jumping somewhere arbitrary. Better stale than wrong.
        guard let anchor = anchorRect else {
            if !panel.isVisible {
                let screen = NSScreen.main ?? NSScreen.screens.first
                let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                panel.setFrameOrigin(NSPoint(
                    x: visible.midX - panelSize.width / 2,
                    y: visible.midY
                ))
            }
            return
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Standard IME placement: a gap below the text baseline (anchor.minY in AppKit
        // screen coords is the bottom of the glyph run).  Horizontally align the panel's
        // left edge with the start of the composition.  The gap is deliberately larger
        // than the clamp margin so the panel clears descenders and doesn't cover the
        // marked text the user is still editing.
        let gap: CGFloat = 24
        let edgeMargin: CGFloat = 4
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - panelSize.height - gap)

        // If placing below would clip off the bottom of the visible area, flip above the text.
        if origin.y < visibleFrame.minY + edgeMargin {
            origin.y = anchor.maxY + gap
        }

        // Clamp into the visible frame so the panel never lands off-screen.
        origin.x = max(visibleFrame.minX + edgeMargin, min(origin.x, visibleFrame.maxX - panelSize.width - edgeMargin))
        origin.y = max(visibleFrame.minY + edgeMargin, min(origin.y, visibleFrame.maxY - panelSize.height - edgeMargin))

        panel.setFrameOrigin(origin)
    }

    @objc private func candidateItemPressed(_ sender: BurmeseCandidateItemView) {
        delegate?.candidatePanelController(self, didCommitCandidateAt: sender.candidateIndex)
    }
}

final class BurmeseCandidatePanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BurmeseCandidateItemView: NSControl {
    var candidateIndex = 0
    var isSelectedCandidate = false {
        didSet { updateAppearance() }
    }
    var showsSeparator = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    private(set) var widthConstraint: NSLayoutConstraint!

    private let highlightView = NSView()
    private let label = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 4
        addSubview(highlightView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = NSColor.separatorColor.withAlphaComponent(0.35)
        separator.isHidden = true
        addSubview(separator)

        let widthC = widthAnchor.constraint(equalToConstant: 0)
        widthC.priority = .required
        widthConstraint = widthC
        NSLayoutConstraint.activate([
            widthC,
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 20, height: max(26, labelSize.height + 8))
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    func configure(title: String, selected: Bool, showsSeparator: Bool) {
        let titleColor = selected ? NSColor.white : NSColor.labelColor
        label.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: titleColor,
            ]
        )
        isSelectedCandidate = selected
        self.showsSeparator = showsSeparator
        invalidateIntrinsicContentSize()
    }

    private func updateAppearance() {
        highlightView.layer?.backgroundColor = (
            isSelectedCandidate ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        )
        label.textColor = isSelectedCandidate ? .white : .labelColor
    }
}
