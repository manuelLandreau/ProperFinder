import AppKit
import SwiftUI

struct PathField: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.pathText)
        field.setAccessibilityIdentifier("pathField")
        field.cell?.setAccessibilityIdentifier("pathField")
        field.placeholderString = String(localized: "Path")
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        // A scrollable cell never truncates and shows the start of a long path; the end (current folder) matters more.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byTruncatingHead
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        if field.stringValue != model.pathText { field.stringValue = model.pathText }
        field.textColor = model.pathInvalid ? .systemRed : .labelColor
        if context.coordinator.focusRequest != model.pathFocusRequest {
            context.coordinator.focusRequest = model.pathFocusRequest
            // makeFirstResponder on an NSTextField selects its whole text, which is what ⌘L wants.
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: BrowserModel
        var focusRequest: Int

        init(model: BrowserModel) {
            self.model = model
            focusRequest = model.pathFocusRequest
        }

        // Read the field rather than the model: an accessibility client can set AXValue without any change notification.
        @objc func commit(_ field: NSTextField) {
            model.pathText = field.stringValue
            model.commitPathEditing()
            guard model.pathInvalid else { return }
            // Caret at the end, not a full selection: selected text is drawn in the selection color and hides the red tint.
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.pathText = field.stringValue
            model.pathInvalid = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            model.cancelPathEditing()
            control.stringValue = model.pathText
            model.focusContent()
            return true
        }

        // Leaving the field (click elsewhere, Tab) drops a half-typed path like an address bar does; Return goes through commit.
        func controlTextDidEndEditing(_ notification: Notification) {
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            guard movement != NSTextMovement.return.rawValue else { return }
            model.cancelPathEditing()
        }
    }
}
