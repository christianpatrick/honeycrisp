import Foundation

/// Builds the HTML Notes' scripting body property speaks. Notes derives a
/// note's name from its first line, so the title travels as a leading
/// heading block instead of a separate property, and plain newlines mean
/// nothing to the body, so every line rides its own div.
enum NoteHTML {
    static func body(title: String?, text: String?) -> String {
        var blocks: [String] = []
        if let title, !title.isEmpty {
            blocks.append("<div><h1>\(escape(title))</h1></div>")
        }
        if let text, !text.isEmpty {
            blocks.append(paragraphs(text))
        }
        return blocks.joined()
    }

    static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line.isEmpty ? "<div><br></div>" : "<div>\(escape(line))</div>"
            }
            .joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
