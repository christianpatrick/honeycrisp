import Foundation

/// .emlx files are a decimal byte count on the first line, the raw RFC822
/// message of exactly that many bytes, then an XML plist of flags.
enum Emlx {
    static func bodyText(from data: Data) -> String? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let countText = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(countText), count > 0 else { return nil }
        let start = data.index(after: newline)
        let end = data.index(start, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
        return MimeText.bodyText(fromRFC822: Data(data[start..<end]))
    }
}

/// Just enough MIME to hand an assistant readable mail text: header
/// unfolding, multipart walking preferring text/plain, quoted-printable and
/// base64 decoding, UTF-8 with a Latin-1 fallback.
enum MimeText {
    static func bodyText(fromRFC822 data: Data) -> String? {
        let text = decodeCharset(data)
        let (headers, body) = splitHeaders(text)
        return extract(headers: headers, body: body)
    }

    private static func extract(headers: [String: String], body: String) -> String? {
        let contentType = (headers["content-type"] ?? "text/plain").lowercased()

        if contentType.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: headers["content-type"] ?? "") else {
                return nil
            }
            var plain: String?
            var html: String?
            for part in parts(of: body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                let partType = (partHeaders["content-type"] ?? "text/plain").lowercased()
                if partType.hasPrefix("multipart/") {
                    if let nested = extract(headers: partHeaders, body: partBody) {
                        plain = plain ?? nested
                    }
                } else if partType.hasPrefix("text/plain"), plain == nil {
                    plain = decodePart(headers: partHeaders, body: partBody)
                } else if partType.hasPrefix("text/html"), html == nil {
                    html = decodePart(headers: partHeaders, body: partBody).map(stripTags)
                }
            }
            return plain ?? html
        }
        if contentType.hasPrefix("text/html") {
            return decodePart(headers: headers, body: body).map(stripTags)
        }
        return decodePart(headers: headers, body: body)
    }

    private static func decodePart(headers: [String: String], body: String) -> String? {
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
            .trimmingCharacters(in: .whitespaces)
        let decoded: String?
        switch encoding {
        case "quoted-printable":
            decoded = decodeQuotedPrintable(body)
        case "base64":
            let compact = body.filter { !$0.isWhitespace }
            decoded = Data(base64Encoded: compact).map(decodeCharset)
        default:
            decoded = body
        }
        return decoded?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pieces

    private static func splitHeaders(_ text: String) -> ([String: String], String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let split = normalized.range(of: "\n\n") else { return ([:], normalized) }
        let head = String(normalized[..<split.lowerBound])
        let body = String(normalized[split.upperBound...])

        var headers: [String: String] = [:]
        var currentName: String?
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if let name = currentName {
                    headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            currentName = name
        }
        return (headers, body)
    }

    private static func parameter(_ name: String, in headerValue: String) -> String? {
        for piece in headerValue.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name
            else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    private static func parts(of body: String, boundary: String) -> [String] {
        body.components(separatedBy: "--" + boundary)
            .dropFirst()
            .filter { !$0.hasPrefix("--") }
            .map { $0.trimmingCharacters(in: .newlines) }
    }

    private static func decodeQuotedPrintable(_ text: String) -> String {
        var bytes: [UInt8] = []
        let input = Array(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "="), index + 1 < input.count {
                if input[index + 1] == UInt8(ascii: "\n") {
                    index += 2  // soft line break
                    continue
                }
                if index + 2 < input.count,
                    let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2])
                {
                    bytes.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return decodeCharset(Data(bytes))
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    private static func decodeCharset(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func stripTags(_ html: String) -> String {
        var text = html

        // Style, script, and head contents are not prose; drop the whole
        // blocks before de-tagging or a newsletter's body leads with CSS.
        for element in ["style", "script", "head"] {
            while let start = text.range(of: "<\(element)", options: .caseInsensitive),
                let end = text.range(
                    of: "</\(element)>", options: .caseInsensitive,
                    range: start.upperBound..<text.endIndex)
            {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }

        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</tr>", "</li>", "</h1>", "</h2>", "</h3>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true } else if character == ">" {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }

        for (entity, value) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&copy;", "(c)"),
        ] {
            result = result.replacingOccurrences(of: entity, with: value)
        }

        // One trimmed line per content run; layout tables leave oceans of
        // blank space otherwise.
        return result
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
