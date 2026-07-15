import SwiftUI
import AppKit

/// A text field that does NOT auto-select all text on focus.
/// Uses NSTextField under the hood with custom focus behavior.
struct NonSelectingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let field = NoSelectTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                text.wrappedValue = field.stringValue
            }
        }
    }
}

/// NSTextField subclass that places cursor at end instead of selecting all on focus.
private class NoSelectTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // After becoming first responder, move cursor to end (deselect)
        DispatchQueue.main.async { [weak self] in
            if let editor = self?.currentEditor() {
                editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            }
        }
        return result
    }
}
