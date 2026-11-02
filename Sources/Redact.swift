import Foundation

/// Removes secret values from a byte stream before it reaches the caller.
/// Catches the raw value and its common encodings. It cannot catch a value
/// that a program deliberately disguises in some other way.
final class Redactor {
    private var needles: [(find: Data, replace: Data)] = []
    private var longest = 0
    private var buffer = Data()
    private let sink: (Data) -> Void

    init(secrets: [(name: String, value: String)], sink: @escaping (Data) -> Void) {
        self.sink = sink
        for secret in secrets where secret.value.utf8.count >= 4 {
            let mask = Data("<redacted:\(secret.name)>".utf8)
            for form in Redactor.forms(of: secret.value) { needles.append((Data(form.utf8), mask)) }
        }
        needles.sort { $0.find.count > $1.find.count }
        longest = needles.first?.find.count ?? 0
    }

    private static func forms(of value: String) -> Set<String> {
        let raw = Data(value.utf8)
        var out: Set<String> = [value]
        let base64 = raw.base64EncodedString()
        out.insert(base64)
        out.insert(base64.replacingOccurrences(of: "=", with: ""))
        out.insert(base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
        out.insert(raw.map { String(format: "%02x", $0) }.joined())
        out.insert(raw.map { String(format: "%02X", $0) }.joined())
        // URL libraries disagree on which characters to escape, so cover the common choices.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for allowed in [CharacterSet.alphanumerics, unreserved, .urlQueryAllowed, .urlPathAllowed, unreserved.union(CharacterSet(charactersIn: "/"))] {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            out.insert(encoded)
            out.insert(encoded.lowercased())
            out.insert(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        // Private keys span several lines, so catch each body line by itself.
        if value.contains("\n") {
            for line in value.split(separator: "\n") where line.count >= 16 && !line.hasPrefix("-----") {
                out.insert(String(line))
            }
        }
        return out
    }

    private func scrub() {
        for needle in needles {
            var from = buffer.startIndex
            while let hit = buffer.range(of: needle.find, in: from..<buffer.endIndex) {
                buffer.replaceSubrange(hit, with: needle.replace)
                from = hit.lowerBound + needle.replace.count
            }
        }
    }

    func write(_ chunk: Data) {
        buffer.append(chunk)
        scrub()
        // Keep the tail back: a secret may be split across two reads.
        var emit = buffer.endIndex
        if let newline = buffer.lastIndex(of: 0x0A) {
            emit = newline + 1
        } else {
            emit = max(buffer.startIndex, buffer.endIndex - max(longest - 1, 0))
        }
        guard emit > buffer.startIndex else { return }
        sink(Data(buffer[buffer.startIndex..<emit]))
        buffer = Data(buffer[emit..<buffer.endIndex])
    }

    /// Called when the program goes quiet, so a prompt without a newline still shows.
    func flushIdle() { finish() }

    func finish() {
        scrub()
        guard !buffer.isEmpty else { return }
        sink(buffer)
        buffer = Data()
    }
}
