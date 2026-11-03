import Foundation

struct GuardScanner {
    enum Rule: String, CaseIterable, Sendable {
        case press, buttons, font, size, color, nativeControls, scheme, motion, sheet, purity, createAction
    }

    struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let rule: String
        var description: String { "\(file):\(line): \(rule)" }
    }

    struct Token {
        let text: String
        let line: Int
        var literal: String? = nil
    }

    // Lexing rather than replacing regex matches preserves lines and nested comments.
    static func tokens(_ source: String) -> [Token] {
        let chars = Array(source)
        var result: [Token] = []
        var i = 0
        var line = 1
        func at(_ offset: Int) -> Character { i + offset < chars.count ? chars[i + offset] : "\0" }
        func advance(_ count: Int = 1) {
            for _ in 0..<count where i < chars.count {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
        }
        while i < chars.count {
            if at(0).isWhitespace { advance(); continue }
            if at(0) == "/", at(1) == "/" {
                while i < chars.count && at(0) != "\n" { advance() }
                continue
            }
            if at(0) == "/", at(1) == "*" {
                advance(2)
                var depth = 1
                while i < chars.count && depth > 0 {
                    if at(0) == "/", at(1) == "*" { depth += 1; advance(2) }
                    else if at(0) == "*", at(1) == "/" { depth -= 1; advance(2) }
                    else { advance() }
                }
                continue
            }
            var hashes = 0
            while at(hashes) == "#" { hashes += 1 }
            if at(hashes) == "\"" {
                let startLine = line
                advance(hashes)
                let quotes = at(1) == "\"" && at(2) == "\"" ? 3 : 1
                advance(quotes)
                let contentStart = i
                var contentEnd = i
                while i < chars.count {
                    if at(0) == "\\", hashes == 0 { advance(2); continue }
                    let closes = (0..<quotes).allSatisfy { at($0) == "\"" }
                        && (0..<hashes).allSatisfy { at(quotes + $0) == "#" }
                    if closes { contentEnd = i; advance(quotes + hashes); break }
                    advance()
                }
                // Keep an opaque marker so a string cannot join adjacent code tokens.
                result.append(Token(text: "<string>", line: startLine,
                                    literal: String(chars[contentStart..<contentEnd])))
                continue
            }
            let start = i
            let startLine = line
            if at(0).isLetter || at(0) == "_" || at(0) == "`" {
                advance()
                while at(0).isLetter || at(0).isNumber || at(0) == "_" || at(0) == "`" { advance() }
            } else if at(0).isNumber {
                advance()
                while at(0).isNumber || at(0) == "." || at(0) == "_" || at(0).isLetter { advance() }
            } else { advance() }
            result.append(Token(text: String(chars[start..<i]).replacingOccurrences(of: "`", with: ""), line: startLine))
        }
        return result
    }

    static func files(in root: URL) throws -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return walk.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift" || $0.lastPathComponent.hasSuffix(".swift.txt")
        }.sorted { $0.path < $1.path }
    }

    static func violations(guard rule: Rule, in files: [URL]) throws -> [Violation] {
        let sources = try files.map { ($0, tokens(try String(contentsOf: $0, encoding: .utf8))) }
        func role(_ url: URL) -> String {
            if url.pathComponents.contains("Kit") { return "kit" }
            if url.pathComponents.contains("Store") { return "store" }
            return "view"
        }
        let declarations = Set(sources.filter { role($0.0) != "kit" }.flatMap { _, tokens in
            tokens.indices.compactMap { index -> String? in
                guard ["struct", "class", "enum", "actor", "protocol", "typealias"].contains(tokens[index].text),
                      index + 1 < tokens.count else { return nil }
                return tokens[index + 1].text
            }
        })
        var found: [Violation] = []
        var performs: [(URL, Int)] = []
        var floatingActions: [(URL, Int)] = []
        for (url, tokens) in sources {
            let words = tokens.map(\.text)
            let kit = role(url) == "kit"
            let view = role(url) == "view"
            let name = url.lastPathComponent.replacingOccurrences(of: ".txt", with: "")
            func matches(_ index: Int, _ pattern: [String]) -> Bool {
                index + pattern.count <= words.count && Array(words[index..<(index + pattern.count)]) == pattern
            }
            for index in words.indices {
                let word = words[index]
                func hit(_ reason: String) { found.append(Violation(file: url.path, line: tokens[index].line, rule: reason)) }
                let dot = index > 0 && words[index - 1] == "."
                switch rule {
                case .createAction:
                    guard url.path.contains("/Views/Panel/") else { continue }
                    if dot && matches(index, ["floatingAction", "("]) {
                        floatingActions.append((url, tokens[index].line))
                    }
                    if ["ChipButton", "PillButton", "AsyncPillButton"].contains(word), matches(index + 1, ["("]) {
                        // Inspect only labelled arguments at this call's own depth;
                        // nested calls/closures must not donate their title or symbol.
                        var depth = 1
                        var cursor = index + 2
                        var argument: String?
                        while cursor < words.count && depth > 0 {
                            let text = words[cursor]
                            if depth == 1 && (cursor == index + 2 || words[cursor - 1] == ",")
                                && cursor + 1 < words.count && words[cursor + 1] == ":" {
                                argument = text
                            }
                            if depth == 1, let literal = tokens[cursor].literal {
                                if (argument == "title" && (literal.hasPrefix("New ") || literal.hasPrefix("Add ")))
                                    || (argument == "symbol" && literal == "plus") {
                                    hit("Create action: use FloatingPill through .floatingAction(_:)")
                                    break
                                }
                            }
                            if ["(", "[", "{"].contains(text) { depth += 1 }
                            if [")", "]", "}"].contains(text) { depth -= 1 }
                            if depth == 1 && text == "," { argument = nil }
                            cursor += 1
                        }
                    }
                case .press:
                    if matches(index, ["inFlight", ".", "perform", "("]) { performs.append((url, tokens[index].line)) }
                    if view && (["Task", "DispatchQueue", "await"].contains(word) || matches(index, ["async", "let"])) {
                        hit("Press: async work belongs in AsyncPress or Store")
                    }
                case .buttons:
                    if view && ((word == "Button" && matches(index + 1, ["("])) || (dot && ["onTapGesture", "gesture"].contains(word))) {
                        hit("Buttons: use kit presses")
                    }
                case .font:
                    if view && (word == "Font" || (dot && word == "system")) { hit("Font: use house tokens") }
                    let fonts = ["eyebrow", "badge", "meta", "control", "body", "rowTitle", "header", "sectionTitle", "modalTitle", "paneTitle", "statSmall", "statValue", "mono"]
                    let houseFont = matches(index + 1, ["(", ".", "house", "."])
                        && index + 6 < words.count && fonts.contains(words[index + 5]) && words[index + 6] == ")"
                    if view && dot && word == "font" && !houseFont {
                        hit("Font: only .font(.house.<token>)")
                    }
                case .size:
                    if view && word.first?.isNumber == true && !["0", "1"].contains(word) {
                        let arrayIndex = index > 0 && words[index - 1] == "[" && matches(index + 1, ["]"])
                        if !arrayIndex { hit("Size: use Size, Space, Radius or Theme.opacity tokens") }
                    }
                case .color:
                    let colors = ["white", "black", "primary", "secondary", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "grey", "clear", "accentColor"]
                    if view && (["Color", "NSColor"].contains(word) || (dot && colors.contains(word))) { hit("Color: use Theme tokens") }
                case .nativeControls:
                    if view && (["Toggle", "Picker", "Menu", "Stepper", "Slider", "TextField", "SecureField"].contains(word)
                        || (dot && ["alert", "confirmationDialog", "popover", "sheet"].contains(word))) { hit("Native controls: use kit components") }
                case .scheme:
                    if !(kit && name == "HouseScheme.swift") && dot && (word == "preferredColorScheme"
                        || matches(index, ["environment", "(", "\\", ".", "colorScheme"])) { hit("Scheme: only HouseScheme sets the scheme") }
                case .motion:
                    if view && (["withAnimation", "TimelineView"].contains(word) || (dot && ["animation", "repeatForever"].contains(word))) { hit("Motion: use kit motion") }
                case .sheet:
                    if !(kit && name == "HouseSheet.swift") && ((dot && ["sheet", "popover", "fullScreenCover"].contains(word))
                        || word == "ModalFrame") { hit("Sheet: present through houseSheet(item:)") }
                    if view && dot && word == "houseSheet" && !matches(index + 1, ["(", "item", ":"]) { hit("Sheet: requires item presentation") }
                case .purity:
                    if kit && word == "import" {
                        var next = index + 1
                        if next < words.count && ["struct", "class", "enum", "func", "var", "let", "protocol", "typealias"].contains(words[next]) { next += 1 }
                        if next < words.count && !["SwiftUI", "AppKit", "QuartzCore", "Foundation"].contains(words[next]) { hit("Kit purity: forbidden import") }
                    }
                    if kit && declarations.contains(word) { hit("Kit purity: references app type \(word)") }
                }
            }
        }
        if rule == .createAction {
            for (url, line) in floatingActions.dropFirst() {
                found.append(Violation(file: url.path, line: line,
                                       rule: "Create action: at most one .floatingAction in Views/Panel/"))
            }
        }
        if rule == .press {
            for (url, line) in performs where !url.pathComponents.contains("Kit") || url.lastPathComponent.replacingOccurrences(of: ".txt", with: "") != "AsyncPress.swift" {
                found.append(Violation(file: url.path, line: line, rule: "Press: perform belongs in Kit/AsyncPress.swift"))
            }
            if performs.count != 1 {
                found.append(Violation(file: performs.first?.0.path ?? files.first?.path ?? "Sources/Agencil/Kit/AsyncPress.swift",
                                       line: performs.first?.1 ?? 1, rule: "Press: expected exactly one inFlight.perform, found \(performs.count)"))
            }
        }
        return found
    }
}
