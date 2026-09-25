import Foundation
import AppKit

/// Verification for the script editor. The regression this guards against: binding a
/// SwiftUI `TextEditor` straight to the scene model re-assigned the text view's whole
/// string on every keystroke, which moved the caret to the end of the document.
enum EditorSelfTest {

    static func run(check: Checker) {
        _ = NSApplication.shared     // AppKit needs to exist before views are made
        testCaretIsPreservedWhileTyping(check)
        testExternalChangesReplaceText(check)
        testSelectionClamping(check)
        testAutoIndent(check)
        testSubstitutionsAreOff(check)
        testChangeForwarding(check)
        testHighlighting(check)
        testCompletionPanel(check)
        testLuauEditing(check)
        testCopyAndPaste(check)
    }

    /// ⌘X, ⌘C and ⌘V reach the editor through Edit menu items with no target, which AppKit
    /// sends to whatever text has the keyboard. Without them the keys did nothing at all.
    private static func testCopyAndPaste(_ check: Checker) {
        print("\nScript editor: copy and paste")
        let menu = EditorAppDelegate().makeMainMenu()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"),
                                    ("Copy", #selector(NSText.copy(_:)), "c"),
                                    ("Paste", #selector(NSText.paste(_:)), "v")] {
            let found = items.first { $0.action == action }
            check("\(name) is in the Edit menu as ⌘\(key.uppercased()), for whatever has the keyboard",
                  found?.title == name && found?.keyEquivalent == key
                  && found?.keyEquivalentModifierMask == [.command] && found?.target == nil)
            let answering = items.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command] }
            check("…and nothing else answers ⌘\(key.uppercased())", answering.count == 1, "\(answering.map(\.title))")
        }

        // Two items on one shortcut means the second never runs from the keyboard.
        func shortcut(_ item: NSMenuItem) -> String? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            var mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            var key = item.keyEquivalent
            // An upper-case letter is typed with ⇧.
            if key.count == 1, let letter = key.first, letter.isLetter, letter.isUppercase {
                mask.insert(.shift)
                key = key.lowercased()
            }
            return "\(mask.rawValue) \(key)"
        }
        func everyItem(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(everyItem) ?? []) }
        }
        let shortcuts = Dictionary(grouping: everyItem(menu).filter { shortcut($0) != nil }, by: { shortcut($0)! })
        let clashes = shortcuts.values.filter { $0.count > 1 }.map { $0.map(\.title).joined(separator: " / ") }
        check("no two menu commands share a shortcut", clashes.isEmpty, clashes.joined(separator: "; "))

        // Through a pasteboard of its own, so the test leaves the real clipboard alone.
        var received: [String] = []
        let entry = CodeEditor.makeEntry()
        let coordinator = CodeEditor.Coordinator(onChange: { received.append($0) }, indentWidth: 2)
        coordinator.entry = entry
        entry.textView.delegate = coordinator
        entry.textView.string = "local a = 1\n"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StudioSelfTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        entry.textView.setSelectedRange(NSRange(location: 6, length: 1))
        // What Copy writes: the text view's own types, which for plain text is the legacy
        // string type — the pasteboard hands it back as an ordinary string.
        let copied = entry.textView.writeSelection(to: pasteboard, types: entry.textView.writablePasteboardTypes)
        check("copying writes the selected code", copied && pasteboard.string(forType: .string) == "a",
              "\(copied) \(pasteboard.string(forType: .string) ?? "nothing")")
        pasteboard.clearContents()
        pasteboard.setString("speed", forType: .string)
        check("pasting replaces the selection",
              entry.textView.readSelection(from: pasteboard, type: .string)
              && entry.textView.string == "local speed = 1\n", entry.textView.string)
        check("…and reaches the script", received.last == "local speed = 1\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if entry.undo.canUndo { entry.undo.undo() }
        check("…as one edit that undoes", entry.textView.string == "local a = 1\n", entry.textView.string)
    }

    /// Colours are applied as attributes, so the characters must be untouched and the
    /// caret must not move.
    private static func testHighlighting(_ check: Checker) {
        print("\nScript editor: highlighting Wren")
        let source = """
        import "studio" for Workspace
        // a note
        var count = 42
        """
        let view = textView(source)
        view.setSelectedRange(NSRange(location: 40, length: 0))
        CodeEditor.highlight(view, language: .wren)

        guard let storage = view.textStorage else {
            check("the view has a text storage", false)
            return
        }
        check("the text is unchanged by highlighting", storage.string == source)
        check("the caret is unchanged by highlighting",
              view.selectedRange() == NSRange(location: 40, length: 0), "\(view.selectedRange())")

        func colour(at offset: Int) -> NSColor? {
            storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        }
        let ns = source as NSString
        check("keywords are coloured",
              colour(at: ns.range(of: "import").location) == SyntaxTheme.keyword)
        check("types are coloured",
              colour(at: ns.range(of: "Workspace").location) == SyntaxTheme.type)
        check("strings are coloured",
              colour(at: ns.range(of: "\"studio\"").location) == SyntaxTheme.string)
        check("comments are coloured",
              colour(at: ns.range(of: "// a note").location) == SyntaxTheme.comment)
        check("numbers are coloured",
              colour(at: ns.range(of: "42").location) == SyntaxTheme.number)
        check("plain identifiers keep the default colour",
              colour(at: ns.range(of: "count").location) == SyntaxTheme.plain)
        check("the font survives highlighting",
              (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? false)

        // Re-highlighting after an edit must clear colours that no longer apply.
        let swapped = textView("class Tower {}")
        CodeEditor.highlight(swapped, language: .wren)
        check("a keyword starts out coloured as one",
              (swapped.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                  == SyntaxTheme.keyword)

        // "class" becomes "count", which is a plain identifier.
        swapped.setSelectedRange(NSRange(location: 0, length: 5))
        swapped.insertText("count", replacementRange: swapped.selectedRange())
        CodeEditor.highlight(swapped, language: .wren)
        check("stale colours are cleared on re-highlight",
              (swapped.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                  == SyntaxTheme.plain,
              "\(String(describing: swapped.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)))")

        // Deleting an opening quote must stop the rest of the line being a string.
        let unquoted = textView("var s = \"text\"")
        CodeEditor.highlight(unquoted, language: .wren)
        let quoteOffset = ("var s = \"text\"" as NSString).range(of: "text").location
        check("a quoted region is coloured as a string",
              (unquoted.textStorage?.attribute(.foregroundColor, at: quoteOffset, effectiveRange: nil) as? NSColor)
                  == SyntaxTheme.string)
        unquoted.setSelectedRange(NSRange(location: 8, length: 1))
        unquoted.insertText("", replacementRange: unquoted.selectedRange())
        CodeEditor.highlight(unquoted, language: .wren)
        check("removing the quote clears the string colour",
              (unquoted.textStorage?.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor)
                  != SyntaxTheme.string,
              "\(String(describing: unquoted.textStorage?.attribute(.foregroundColor, at: 8, effectiveRange: nil)))")
    }

    /// Luau is the default language of the editor.
    private static func testLuauEditing(_ check: Checker) {
        print("\nScript editor: Luau")
        let source = """
        -- a note
        local RunService = game:GetService("RunService")
        local count = 42
        """
        let view = textView(source)
        CodeEditor.highlight(view)
        guard let storage = view.textStorage else { return }
        let ns = source as NSString
        func colour(_ text: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: ns.range(of: text).location, effectiveRange: nil) as? NSColor
        }
        check("the editor highlights Luau by default", colour("local") == SyntaxTheme.keyword)
        check("Luau comments are coloured", colour("-- a note") == SyntaxTheme.comment)
        check("Luau strings are coloured", colour("\"RunService\"") == SyntaxTheme.string)
        check("globals like game are coloured", colour("game") == SyntaxTheme.type)
        check("numbers are coloured", colour("42") == SyntaxTheme.number)

        // Tab indents with a tab in Luau, as Roblox Studio does; spaces in Wren.
        let coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2)
        let luau = textView("")
        _ = coordinator.textView(luau, doCommandBy: #selector(NSResponder.insertTab(_:)))
        check("Tab inserts a tab in Luau", luau.string == "\t", "\(Array(luau.string.utf8))")
        let wrenCoordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2, language: .wren)
        let wren = textView("")
        _ = wrenCoordinator.textView(wren, doCommandBy: #selector(NSResponder.insertTab(_:)))
        check("Tab inserts spaces in Wren", wren.string == "  ", "\(Array(wren.string.utf8))")

        // The completion panel, driven by the Luau engine.
        let completing = "local RunService = game:GetService(\"RunService\")\nRunService.Heartbeat:Con"
        let panel = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        CodeEditor.configure(panel)
        panel.string = completing
        panel.setSelectedRange(NSRange(location: (completing as NSString).length, length: 0))
        let luauCoordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2)
        panel.source = luauCoordinator
        let displays = luauCoordinator.textView(panel, completions: [],
                                                forPartialWordRange: panel.rangeForUserCompletion,
                                                indexOfSelectedItem: nil)
        check("the panel offers Luau methods through GetService",
              displays.contains { $0.hasPrefix("Connect(callback)") }, "\(displays)")
    }

    private static func testCompletionPanel(_ check: Checker) {
        print("\nScript editor: completion panel (Wren)")
        let source = "import \"studio\" for Workspace\nWorkspace.fin"
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        CodeEditor.configure(view)
        view.string = source
        let caret = (source as NSString).length
        view.setSelectedRange(NSRange(location: caret, length: 0))

        let coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2, language: .wren,
                                                 completions: { WrenCompletion.items(in: $0, caret: $1) })
        view.source = coordinator
        view.delegate = coordinator

        check("the partial word range is the typed prefix",
              (source as NSString).substring(with: view.rangeForUserCompletion) == "fin",
              (source as NSString).substring(with: view.rangeForUserCompletion))

        let displays = coordinator.textView(view, completions: [],
                                            forPartialWordRange: view.rangeForUserCompletion,
                                            indexOfSelectedItem: nil)
        check("the panel is offered suggestions", !displays.isEmpty, "\(displays)")
        check("suggestions show the return type alongside the name",
              displays.contains { $0.hasPrefix("find(name)") && $0.contains("Part") }, "\(displays)")
        check("every display string is distinct", Set(displays).count == displays.count)

        guard let first = displays.first(where: { $0.hasPrefix("find(name)") }) else {
            check("find is offered", false)
            return
        }
        check("the display string maps back to the text to insert",
              coordinator.insertion(forDisplay: first) == "find(",
              coordinator.insertion(forDisplay: first))
        check("an unknown display string is inserted verbatim",
              coordinator.insertion(forDisplay: "something else") == "something else")

        // Inserting must put the code in, not the decorated label.
        view.insertCompletion(first, forPartialWordRange: view.rangeForUserCompletion,
                              movement: 0, isFinal: true)
        check("choosing a suggestion inserts real code",
              view.string.hasSuffix("Workspace.find("), view.string)
        check("the decoration is not inserted", !view.string.contains("·"), view.string)
    }

    private static func textView(_ contents: String) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        CodeEditor.configure(view)
        view.string = contents
        return view
    }

    // MARK: - Tests

    private static func testCaretIsPreservedWhileTyping(_ check: Checker) {
        print("\nScript editor: typing")
        let source = "import \"studio\" for Workspace\nvar a = 1\nvar b = 2\n"
        let view = textView(source)

        // Put the caret in the middle of the second line, as if the user were typing there.
        let caret = NSRange(location: 34, length: 0)
        view.setSelectedRange(caret)

        // The model hands the identical string straight back after each keystroke.
        var replaced = false
        for _ in 0..<12 {
            replaced = CodeEditor.syncText(source, into: view, coordinator: nil) || replaced
        }
        check("identical text is not re-assigned", !replaced)
        check("the caret stays where the user put it", view.selectedRange() == caret,
              "\(view.selectedRange())")
        check("the text is untouched", view.string == source)

        // Now simulate real typing: insert a character, then sync the resulting string.
        view.insertText("x", replacementRange: view.selectedRange())
        let afterTyping = view.selectedRange()
        CodeEditor.syncText(view.string, into: view, coordinator: nil)
        check("the caret does not jump after a round trip through the model",
              view.selectedRange() == afterTyping, "\(view.selectedRange()) vs \(afterTyping)")
        check("the caret is not at the end of the document",
              view.selectedRange().location < (view.string as NSString).length,
              "caret \(view.selectedRange().location) of \((view.string as NSString).length)")
    }

    private static func testExternalChangesReplaceText(_ check: Checker) {
        print("\nScript editor: switching scripts")
        let view = textView("first script")
        view.setSelectedRange(NSRange(location: 5, length: 0))

        let replaced = CodeEditor.syncText("a completely different script", into: view, coordinator: nil)
        check("different text is written in", replaced)
        check("the view shows the new text", view.string == "a completely different script")
        check("the caret is still valid",
              view.selectedRange().location <= (view.string as NSString).length)
    }

    private static func testSelectionClamping(_ check: Checker) {
        print("\nScript editor: selection clamping")
        let long = NSRange(location: 40, length: 10)
        let clamped = CodeEditor.clamp(long, to: "short")
        check("a selection past the end is clamped", clamped.location <= 5 && clamped.length <= 5,
              "\(clamped)")
        check("clamping never produces a negative length", clamped.length >= 0, "\(clamped)")

        let inside = NSRange(location: 2, length: 2)
        check("a valid selection is left alone", CodeEditor.clamp(inside, to: "abcdef") == inside)

        // Replacing long text with short text must not crash or select out of bounds.
        let view = textView("a long script with plenty of characters")
        view.setSelectedRange(NSRange(location: 30, length: 5))
        CodeEditor.syncText("tiny", into: view, coordinator: nil)
        let range = view.selectedRange()
        check("shrinking the document keeps the selection in bounds",
              range.location + range.length <= 4, "\(range)")
    }

    private static func testAutoIndent(_ check: Checker) {
        print("\nScript editor: indentation")
        let source = "class A {\n    var x = 1\nplain\n"
        // Offsets: 0 = start, 10 = start of the indented line, 23 = end of it.
        check("no indent at the start of the file",
              CodeEditor.Coordinator.leadingWhitespace(in: source, before: 0) == "")
        check("an indented line carries its indent forward",
              CodeEditor.Coordinator.leadingWhitespace(in: source, before: 23) == "    ",
              "\"\(CodeEditor.Coordinator.leadingWhitespace(in: source, before: 23))\"")
        check("an unindented line carries nothing forward",
              CodeEditor.Coordinator.leadingWhitespace(in: source, before: 29) == "",
              "\"\(CodeEditor.Coordinator.leadingWhitespace(in: source, before: 29))\"")
        check("an out-of-range offset is handled",
              CodeEditor.Coordinator.leadingWhitespace(in: source, before: 9999) == "")
        check("tabs count as indentation",
              CodeEditor.Coordinator.leadingWhitespace(in: "\tvar x", before: 5) == "\t")
    }

    private static func testSubstitutionsAreOff(_ check: Checker) {
        print("\nScript editor: input substitutions")
        let view = textView("")
        check("smart quotes are off", !view.isAutomaticQuoteSubstitutionEnabled)
        check("smart dashes are off", !view.isAutomaticDashSubstitutionEnabled)
        check("text replacement is off", !view.isAutomaticTextReplacementEnabled)
        check("spelling correction is off", !view.isAutomaticSpellingCorrectionEnabled)
        check("the editor is plain text", !view.isRichText)
        check("undo is available", view.allowsUndo)
        check("the font is monospaced", view.font?.isFixedPitch ?? false, "\(String(describing: view.font))")

        // Typed quotes must survive verbatim, or every Wren string literal breaks.
        view.insertText("import \"studio\"", replacementRange: NSRange(location: 0, length: 0))
        check("typed quotes stay straight", view.string == "import \"studio\"", view.string)
    }

    private static func testChangeForwarding(_ check: Checker) {
        print("\nScript editor: change forwarding")
        var received: [String] = []
        let coordinator = CodeEditor.Coordinator(onChange: { received.append($0) }, indentWidth: 2)
        let view = textView("start")
        view.delegate = coordinator

        // A real user edit goes through insertText, which notifies the delegate.
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.insertText("edited by the user", replacementRange: view.selectedRange())
        check("user edits reach the model", received == ["edited by the user"], "\(received)")

        // Writing text in programmatically must not come back as a user edit.
        received = []
        CodeEditor.syncText("written by the host", into: view, coordinator: coordinator)
        check("a programmatic write does not report a user edit", received.isEmpty, "\(received)")
        check("but the text was written", view.string == "written by the host", view.string)
        check("the guard flag is cleared afterwards", !coordinator.isApplyingExternalChange)

        // And if a change notification does arrive mid-write, the guard drops it.
        received = []
        coordinator.isApplyingExternalChange = true
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        coordinator.isApplyingExternalChange = false
        check("a change arriving during a host write is ignored", received.isEmpty, "\(received)")

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        check("changes are accepted again once the write finishes",
              received == ["written by the host"], "\(received)")
    }
}
