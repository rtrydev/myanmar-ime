import SwiftUI
import AppKit
import BurmeseIMECore

/// Converts Myanmar Unicode text to the romanized "myanglish" input the
/// user would type to produce it. Useful when you see a Myanmar word and
/// want to learn how to enter it.
struct MyanmarToInputView: View {
    @State private var myanmar: String = ""
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            columns
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Myanmar → input")
                .font(.headline)
            Text("Paste Myanmar text on the left to see the myanglish keys that would produce it. Type those keys with the IME active in compose mode (က) to reproduce the original.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 12) {
            inputColumn
            outputColumn
        }
        .frame(minHeight: 260)
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Myanmar")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $myanmar)
                .font(.system(size: 16))
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                )
            HStack {
                Button("Paste") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        myanmar = clip
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                if !myanmar.isEmpty {
                    Button("Clear") { myanmar = "" }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Myanglish input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !converted.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(converted, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            ScrollView {
                Text(converted.isEmpty ? "—" : converted)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                    .foregroundStyle(converted.isEmpty ? .secondary : .primary)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Text("+ stacks the next consonant, * marks asat, ' forces a syllable break, : is the long / heavy tone, . is the short / creaky tone.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Convert the input, preserving whitespace/newlines between Myanmar tokens.
    private var converted: String {
        guard !myanmar.isEmpty else { return "" }
        var result = ""
        var token = ""
        for ch in myanmar {
            if ch.isWhitespace {
                if !token.isEmpty {
                    result += transform(token)
                    token = ""
                }
                result.append(ch)
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty {
            result += transform(token)
        }
        return result
    }

    private func transform(_ token: String) -> String {
        stripDisambiguators(ReverseRomanizer.romanize(token))
    }
}
