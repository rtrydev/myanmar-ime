import InputMethodKit
import BurmeseIMECore

/// Shared candidates panel — created by AppDelegate in the app target after IMKServer is ready.
/// Nil in the extension target (where it is never set), so all calls are safe no-ops there.
var sharedCandidatesPanel: IMKCandidates?

/// Primary InputMethodKit controller for the Burmese IME extension.
///
/// Lifecycle:
///   - One instance is created per input session by IMKServer.
///   - `handle(_:client:)` receives every key-down event while the IME is active.
///   - `commitComposition(_:)` is called by the system when the client requests a
///     forced commit (e.g. window focus loss).
///   - `candidateSelected(_:)` is called when the user picks from the IMKCandidates panel.
@objc(BurmeseInputController)
class BurmeseInputController: IMKInputController {

    // MARK: - State

    private let engine = BurmeseEngine()
    private var state = CompositionState()

    // MARK: - IMKInputController overrides

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }

        let keyCode = event.keyCode
        let chars = event.characters ?? ""

        switch keyCode {
        case 53: // Escape — commit raw latin
            commitRaw(client: sender)
            return true

        case 36, 76: // Return / Enter — commit selection
            commitSelection(client: sender)
            return true

        case 49: // Space — commit selection (first press) or insert space (second)
            if state.isActive {
                commitSelection(client: sender)
            } else {
                (sender as? IMKTextInput)?.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
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

        // Option+1…5 — candidate selection shortcut
        if event.modifierFlags.contains(.option), let digit = Int(chars), (1...5).contains(digit) {
            let index = digit - 1
            if index < state.candidates.count {
                state.selectedCandidateIndex = index
                commitSelection(client: sender)
                return true
            }
        }

        // Composing characters: a-z, 0-9, +, *, ', :, .
        let composingSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+*':.")
        if chars.unicodeScalars.allSatisfy({ composingSet.contains($0) }) {
            state.rawBuffer += chars.lowercased()
            state = engine.update(buffer: state.rawBuffer, context: state.committedContext)
            updateMarkedText(client: sender)
            return true
        }

        // Punctuation — commit pending candidate then pass through
        if state.isActive {
            commitSelection(client: sender)
        }
        return false
    }

    override func commitComposition(_ sender: Any!) {
        commitSelection(client: sender)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        return state.candidates.map { $0.surface }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        // candidateSelected is called when the user picks from the IMKCandidates panel.
        // Update the selection index, then commit immediately.
        let surface = candidateString.string
        if let idx = state.candidates.firstIndex(where: { $0.surface == surface }) {
            state.selectedCandidateIndex = idx
        }
        guard let activeClient = client() else { return }
        commitSelection(client: activeClient)
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        // Called as the user navigates through the panel without committing.
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
            sharedCandidatesPanel?.hide()
        } else {
            sharedCandidatesPanel?.update()
            sharedCandidatesPanel?.show(kIMKLocateCandidatesBelowHint)
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
        sharedCandidatesPanel?.hide()
    }

    private func commitRaw(client sender: Any!) {
        guard state.isActive else { return }
        let raw = state.rawBuffer
        (sender as? IMKTextInput)?.insertText(
            raw,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        state = CompositionState(committedContext: state.committedContext)
        sharedCandidatesPanel?.hide()
    }
}
