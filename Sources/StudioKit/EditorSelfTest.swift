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
        testSuggestions(check)
        testModuleSuggestions(check)
        testLuauEditing(check)
        testCopyAndPaste(check)
    }

    /// ⌘X, ⌘C and ⌘V reach the editor through Edit menu items with no target, which AppKit
    /// sends to whatever text has the keyboard. Without them the keys did nothing at all.
    private static func testCopyAndPaste(_ check: Checker) {
        print("\nScript editor: copy and paste")
        // Kept alive while the menu is read: its items' targets are weak references to it.
        let delegate = EditorAppDelegate()
        defer { withExtendedLifetime(delegate) {} }
        let menu = delegate.makeMainMenu()
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

    }

    /// A code editor in a window, typed into the way the keyboard does it: characters
    /// through `insertText`, keys through `doCommand`, which asks the coordinator first.
    private final class Typist {
        let entry = CodeEditor.makeEntry()
        let coordinator: CodeEditor.Coordinator
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        var view: CodeTextView { entry.textView }
        var list: CompletionList { coordinator.completionList }
        var text: String { view.string }

        init(_ language: CodeLanguage = .luau, completions: ((String, Int) -> [CompletionItem])? = nil) {
            coordinator = CodeEditor.Coordinator(onChange: { _ in }, indentWidth: 2, language: language,
                                                 completions: completions ?? { language.completions(in: $0, caret: $1) })
            coordinator.entry = entry
            view.delegate = coordinator
            view.source = coordinator
            window.contentView = entry.scrollView
            window.makeFirstResponder(view)
        }

        func reset(_ contents: String = "", caret: Int? = nil) {
            list.hide()
            view.string = contents
            coordinator.lastLength = (contents as NSString).length
            view.setSelectedRange(NSRange(location: caret ?? (contents as NSString).length, length: 0))
        }

        func type(_ characters: String) {
            for character in characters {
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
        }

        /// A key on its own turn of the run loop, as a real key press is, so undo groups
        /// the way it does for someone typing.
        func key(_ selector: Selector) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            view.doCommand(by: selector)
        }

        /// Long enough for a waiting list to open.
        func pause() { RunLoop.current.run(until: Date().addingTimeInterval(CodeEditor.Coordinator.pause + 0.12)) }

        var labels: [String] { list.items.map(\.label) }
        var highlighted: String? { list.highlighted?.label }
    }

    private static let down = #selector(NSResponder.moveDown(_:))
    private static let up = #selector(NSResponder.moveUp(_:))
    private static let tab = #selector(NSResponder.insertTab(_:))
    private static let enter = #selector(NSResponder.insertNewline(_:))
    private static let escape = #selector(NSResponder.cancelOperation(_:))
    private static let backspace = #selector(NSResponder.deleteBackward(_:))

    /// The suggestion list: it waits, stays out of the text until chosen, never takes
    /// Return unless a suggestion was picked, and keeps out of the way where it can't help.
    private static func testSuggestions(_ check: Checker) {
        print("\nScript editor: suggestions")
        let editor = Typist()

        editor.type("pr")
        check("a word being typed doesn't open the list straight away", !editor.list.isOpen)
        editor.pause()
        check("…it opens when typing pauses", editor.list.isOpen && editor.highlighted == "print(...)", "\(editor.labels)")
        check("…and nothing is written into the code until one is chosen", editor.text == "pr", editor.text)
        editor.key(enter)
        check("Return with nothing picked is a new line, in one press", editor.text == "pr\n" && !editor.list.isOpen,
              "\"\(editor.text)\"")

        editor.reset()
        editor.type("workspace.Part.")
        check("after a dot the members open at once", editor.list.isOpen && editor.highlighted == "Anchored",
              "\(editor.labels)")
        editor.type("Pos")
        check("…and narrow as the name is typed", editor.labels == ["Position"], "\(editor.labels)")
        editor.key(tab)
        check("Tab puts the highlighted one in", editor.text == "workspace.Part.Position" && !editor.list.isOpen,
              editor.text)
        editor.pause()
        check("…without the list coming straight back", !editor.list.isOpen)
        editor.entry.undo.undo()
        check("…and ⌘Z takes it out again", editor.text == "workspace.Part.Pos", editor.text)

        editor.reset()
        editor.type("workspace.Part.")
        editor.key(down)
        editor.key(down)
        let chosen = editor.highlighted
        editor.type("C")
        check("a suggestion picked with the arrows stays picked as typing narrows the list",
              chosen == "CanTouch" && editor.highlighted == "CanTouch" && editor.list.picked, "\(chosen ?? "-") \(editor.labels)")

        editor.reset()
        editor.type("re")
        editor.pause()
        check("keywords come before functions", editor.labels.prefix(3) == ["repeat", "return", "require(moduleScript)"],
              "\(editor.labels)")
        editor.key(up)
        check("Up at the top stays there", editor.highlighted == "repeat")
        editor.key(down)
        check("Down moves the highlight", editor.highlighted == "return" && editor.list.picked)
        editor.key(enter)
        check("once one is picked with the arrows, Return puts it in", editor.text == "return" && !editor.list.isOpen,
              "\"\(editor.text)\"")

        editor.reset()
        editor.type("ga")
        editor.pause()
        editor.key(escape)
        check("Esc closes the list and leaves the text", !editor.list.isOpen && editor.text == "ga")
        editor.key(escape)
        check("Esc with no list opens none", !editor.list.isOpen && editor.text == "ga")
        editor.view.complete(nil)
        check("⌥Esc opens it by hand", editor.list.isOpen && editor.highlighted == "game", "\(editor.labels)")
        editor.reset("p")
        editor.view.complete(nil)
        check("…even for one letter", editor.list.isOpen, "\(editor.labels)")

        // The block words: typing one out and pressing Return must just start a new line.
        editor.reset("if ready then\n\tgo()\n")
        editor.type("en")
        editor.pause()
        check("`en` suggests end before Enum", editor.labels.prefix(2) == ["end", "Enum"], "\(editor.labels)")
        editor.type("d")
        check("a word typed in full closes the list", !editor.list.isOpen, "\(editor.labels)")
        editor.key(enter)
        check("…so end then Return is a new line in one press", editor.text.hasSuffix("\tgo()\nend\n"),
              "\"\(editor.text)\"")
        for word in ["then", "do", "else", "local", "function", "true"] {
            editor.reset()
            for letter in word {
                editor.type(String(letter))
                editor.pause()
            }
            editor.key(enter)
            check("\(word) typed slowly, then Return, is a new line", editor.text == word + "\n", "\"\(editor.text)\"")
        }
        editor.reset("local count = 0\n")
        editor.type("count")
        editor.pause()
        editor.key(enter)
        check("…and so is a local's whole name", editor.text.hasSuffix("count\n"), "\"\(editor.text)\"")

        // Where a new name is being made up, suggestions only get in the way.
        for line in ["local pl", "local a, bo", "for i", "for _, pl", "local function onTo", "function onTouched(hi",
                     "local handler = function(pa", "local x: Pa"] {
            editor.reset()
            editor.type(line)
            editor.pause()
            check("nothing is suggested while naming: \(line)", !editor.list.isOpen, "\(editor.labels)")
        }
        editor.reset()
        editor.type("for _, v in pa")
        editor.pause()
        check("…but there is once the name is done", editor.highlighted == "pairs(t)", "\(editor.labels)")

        editor.reset("workspace", caret: 3)
        editor.type("x")
        editor.pause()
        check("no list while editing inside a word", !editor.list.isOpen)
        editor.reset()
        editor.type("local speed = 0.")
        editor.pause()
        check("no list after the dot in a number", !editor.list.isOpen, "\(editor.labels)")
        editor.reset()
        editor.type("-- workspace.")
        editor.pause()
        check("no list in a comment", !editor.list.isOpen)

        editor.reset()
        editor.type("workspace.Part.Pos")
        let narrow = editor.list.items.count
        editor.key(backspace)
        check("Backspace widens the list", editor.list.isOpen && editor.list.items.count > narrow,
              "\(narrow) → \(editor.list.items.count)")
        editor.key(backspace)
        editor.key(backspace)
        check("…back to all the members after the dot", editor.list.isOpen && editor.highlighted == "Anchored")
        editor.key(backspace)
        check("…and deleting the dot closes it", !editor.list.isOpen)

        editor.reset()
        editor.type("workspace.Part.")
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        check("moving off the word closes the list", !editor.list.isOpen)
        editor.reset()
        editor.type("workspace.Part.")
        editor.type(" ")
        check("…as does typing past it", !editor.list.isOpen)

        editor.reset()
        editor.type("workspace.Part.")
        editor.list.onClick?(1)
        check("clicking a row puts that one in", editor.text == "workspace.Part.CanCollide", editor.text)

        editor.reset("local RunService = game:GetService(\"RunService\")\n")
        editor.type("RunService.Heartbeat:Con")
        check("methods through GetService", editor.highlighted == "Connect(callback)", "\(editor.labels)")

        // Placed under the word, lined up with it.
        editor.reset()
        editor.type("workspace.Part.")
        let word = editor.view.firstRect(forCharacterRange: NSRange(location: editor.list.anchor, length: 0), actualRange: nil)
        let frame = editor.list.panelFrame
        check("the list sits just under the word", frame.maxY <= word.minY && frame.maxY > word.minY - 8
                && abs(frame.minX + 32 - word.minX) < 2, "panel \(frame), word \(word)")
        editor.list.hide()

        // Wren and the shader editor use the same list.
        let wren = Typist(.wren)
        wren.reset("import \"studio\" for Workspace\n")
        wren.type("Workspace.fin")
        check("Wren: members after a dot", wren.highlighted == "find(name)"
                && wren.list.highlighted?.detail.contains("Part") == true, "\(wren.labels)")
        wren.key(tab)
        check("Wren: Tab inserts the code, not the label", wren.text.hasSuffix("Workspace.find("), wren.text)
        let metal = Typist(.metal, completions: { MetalCompletion.items(in: $0, caret: $1) })
        metal.type("float a = 0.")
        metal.pause()
        check("Metal: no swizzles after the dot in a number", !metal.list.isOpen, "\(metal.labels)")
        metal.type("5 * baseColor.")
        check("…but after a vector's dot, yes", metal.list.isOpen && metal.labels.contains("rgb"), "\(metal.labels)")
    }

    /// `require(` and what it gives, typed through the list with a scene behind it.
    private static func testModuleSuggestions(_ check: Checker) {
        print("\nScript editor: modules and the scene")
        let scene = SyntaxSelfTest.sampleScene()
        let editor = Typist(.luau, completions: { LuauCompletion.items(in: $0, caret: $1, scene: scene) })

        editor.reset("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n")
        editor.type("local Utils = require(")
        check("require( opens the list at once, with the ModuleScripts",
              editor.list.isOpen && editor.list.items.prefix(3).allSatisfy { $0.kind == .module }, "\(editor.labels)")
        editor.type("Ut")
        editor.key(tab)
        check("Tab puts in the path to the module", editor.text.hasSuffix("local Utils = require(ReplicatedStorage.Utils)"),
              editor.text)

        editor.type("\nUtils.")
        check("the module's functions and values follow", editor.list.isOpen && editor.labels.contains("lerp(a, b, t)"),
              "\(editor.labels)")
        editor.type("le")
        editor.key(tab)
        check("…and go in ready for their arguments", editor.text.hasSuffix("\nUtils.lerp("), editor.text)

        editor.reset("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n")
        editor.type("local Notify = ReplicatedStorage:WaitForChild(\"")
        check("WaitForChild(\" opens the list at once, with the names there",
              editor.list.isOpen && editor.labels == ["Notify", "Shared", "Utils"], "\(editor.labels)")
        editor.type("No")
        editor.key(tab)
        check("…and closes the string and the call", editor.text.hasSuffix("WaitForChild(\"Notify\")"), editor.text)

        editor.reset()
        editor.type("local arm = workspace.Tower:WaitForChild(\"Left A")
        check("a space in a name doesn't close the list", editor.list.isOpen && editor.labels == ["Left Arm"],
              "\(editor.labels)")
        editor.key(tab)
        check("…and the whole name goes in", editor.text.hasSuffix("WaitForChild(\"Left Arm\")"), editor.text)

        editor.reset()
        editor.type("print(\"hello")
        editor.pause()
        check("an ordinary string still has no list", !editor.list.isOpen)
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
