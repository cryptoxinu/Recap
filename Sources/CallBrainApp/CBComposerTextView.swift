import SwiftUI
import AppKit
import CallBrainAppCore

/// Fixed-height AppKit composer for Ask. SwiftUI's vertical `TextField` can enter a recursive
/// intrinsic-size measurement loop inside the chat pane after repeated streamed answers.
struct CBComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusToken: focusToken, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        configure(textView)
        textView.delegate = context.coordinator
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        guard let textView = scrollView.documentView as? NSTextView else { return }
        configure(textView)

        if textView.string != text {
            let selection = SafeTextSelection.clamped(textView.selectedRange(),
                                                      textUTF16Length: (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(selection)
        }

        guard context.coordinator.focusToken != focusToken else { return }
        context.coordinator.focusToken = focusToken
        DispatchQueue.main.async {
            guard textView.window != nil else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: textView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusToken: Int
        var onSubmit: () -> Void

        init(text: Binding<String>, focusToken: Int, onSubmit: @escaping () -> Void) {
            self.text = text
            self.focusToken = focusToken
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            guard !flags.contains(.shift), !flags.contains(.option) else { return false }
            onSubmit()
            return true
        }
    }
}
