import Foundation

/// Locates `protocol/fixtures` by walking up from this file (never copied).
enum Fixtures {
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("protocol/fixtures")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("gen.py").path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        fatalError("protocol/fixtures not found above \(#filePath)")
    }()

    static func allNames() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".hex") }.map { String($0.dropLast(4)) })
    }

    /// Strips `#` comments and whitespace, returns the bytes.
    static func bytes(_ name: String) -> [UInt8] {
        let text = try! String(contentsOf: directory.appendingPathComponent(name + ".hex"), encoding: .utf8)
        var digits = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            digits += code.filter { !$0.isWhitespace }
        }
        precondition(digits.count % 2 == 0, "odd hex digit count in \(name)")
        var out: [UInt8] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            out.append(UInt8(digits[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
