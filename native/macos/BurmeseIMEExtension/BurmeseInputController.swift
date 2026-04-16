import InputMethodKit
import BurmeseIMECore

/// Shared IMKCandidates panel — created by AppDelegate in the app target.
/// Nil in the extension target (where it is never set), so all calls are safe no-ops there.
var sharedCandidates: IMKCandidates?

/// Primary InputMethodKit controller for the Burmese IME extension.
///
/// Lifecycle:
///   - One instance is created per input session by IMKServer.
///   - `handle(_:client:)` receives every key-down event while the IME is active.
///   - `commitComposition(_:)` is called by the system when the client requests a
///     forced commit (e.g. window focus loss).
@objc(BurmeseInputController)
class BurmeseInputController: IMKInputController {
    private static let sharedCandidateStore: any CandidateStore = {
        if let lexiconURL = locateResourceURL(name: "BurmeseLexicon", ext: "sqlite"),
           let store = SQLiteCandidateStore(path: lexiconURL.path) {
            return store
        }
        return EmptyCandidateStore()
    }()

    private static let sharedLanguageModel: any LanguageModel = {
        if let lmURL = locateResourceURL(name: "BurmeseLM", ext: "bin"),
           let model = try? TrigramLanguageModel(path: lmURL.path) {
            return model
        }
        return NullLanguageModel()
    }()

    private static func locateResourceURL(name: String, ext: String) -> URL? {
        let bundles = [Bundle(for: BurmeseInputController.self), Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    // MARK: - State

    private let engine = BurmeseEngine(
        candidateStore: BurmeseInputController.sharedCandidateStore,
        languageModel: BurmeseInputController.sharedLanguageModel
    )
    private var state = CompositionState()

    // MARK: - IMKInputController overrides

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }

        let keyCode = event.keyCode

        switch keyCode {
        case 53: // Escape — commit raw latin
            commitRaw(client: sender)
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

        // Let IMKCandidates handle arrow keys and page up/down while the panel is
        // visible. Tab/Shift-Tab aren't navigation keys to IMKCandidates by default,
        // so we translate them into synthetic Down/Up arrow events. The panel calls
        // back through candidateSelected(_:) and candidateSelectionChanged(_:).
        if state.isActive, let panel = sharedCandidates, panel.isVisible() {
            if isCandidateNavigationKey(keyCode) {
                panel.interpretKeyEvents([event])
                return true
            }
            if keyCode == 48 { // Tab / Shift+Tab
                let arrowKeyCode: UInt16 = event.modifierFlags.contains(.shift) ? 126 : 125
                if let synthetic = arrowEvent(like: event, keyCode: arrowKeyCode) {
                    panel.interpretKeyEvents([synthetic])
                }
                return true
            }
        }

        let chars: String = {
            let direct = event.characters ?? ""
            if !direct.isEmpty { return direct }
            return event.charactersIgnoringModifiers ?? ""
        }()
        guard !chars.isEmpty else { return false }

        // "Typeable" characters — ASCII letters, digits, and common punctuation —
        // extend the composition buffer rather than forcing a commit. This mirrors
        // the behaviour of system IMEs like Pinyin and Kotoeri: the user can
        // interleave non-convertible text, and the engine emits the raw buffer
        // verbatim if no Burmese parse is found.
        if isTypeableInput(chars) {
            let seed = state.isActive ? state.rawBuffer : ""
            let nextBuffer = seed + chars.lowercased()
            state = engine.update(buffer: nextBuffer, context: state.committedContext)
            updateMarkedText(client: sender)
            return true
        }

        // Anything else (control characters, function keys forwarded as text, etc.)
        // commits the pending candidate first and falls through.
        if state.isActive {
            commitSelection(client: sender)
        }
        return false
    }

    /// Printable characters that should extend the composition buffer. We accept
    /// the printable ASCII range excluding whitespace (space is a commit key) so
    /// mixed-content input stays in the buffer until the user explicitly commits.
    /// Key codes that IMKCandidates natively treats as navigation: Left/Right/Down/Up
    /// arrows (123/124/125/126) and PageUp/PageDown (116/121). Tab is handled
    /// separately via synthetic arrow events.
    private func isCandidateNavigationKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 116, 121, 123, 124, 125, 126: return true
        default: return false
        }
    }

    /// Build a synthetic key-down event matching `source` but with a different
    /// keyCode — used to translate Tab/Shift-Tab into arrow keys for the panel.
    private func arrowEvent(like source: NSEvent, keyCode: UInt16) -> NSEvent? {
        let character: String
        switch keyCode {
        case 125: character = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: character = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 123: character = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: character = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: character = ""
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: source.locationInWindow,
            modifierFlags: source.modifierFlags.subtracting(.shift),
            timestamp: source.timestamp,
            windowNumber: source.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func isTypeableInput(_ chars: String) -> Bool {
        guard !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    override func commitComposition(_ sender: Any!) {
        commitSelection(client: sender)
    }

    override func deactivateServer(_ sender: Any!) {
        hideCandidates()
        super.deactivateServer(sender)
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
            hideCandidates()
        } else {
            showCandidates()
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
        hideCandidates()
    }

    private func commitRaw(client sender: Any!) {
        guard state.isActive else { return }
        let raw = state.rawBuffer
        (sender as? IMKTextInput)?.insertText(
            raw,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        state = CompositionState(committedContext: state.committedContext)
        hideCandidates()
    }

    private func showCandidates() {
        guard let panel = sharedCandidates else { return }
        panel.update()
        panel.show(kIMKLocateCandidatesBelowHint)
    }

    private func hideCandidates() {
        sharedCandidates?.hide()
    }
}
