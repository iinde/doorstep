import Foundation

/// The CLIP byte-level BPE tokenizer (OpenAI's `simple_tokenizer`, as used by open_clip and
/// MobileCLIP). Built from the merges list alone: the vocabulary is the 256 byte symbols, the
/// same with `</w>`, one entry per merge in rank order, then `<|startoftext|>` and
/// `<|endoftext|>`, which gives OpenAI's ids exactly (49,408 entries with the full list).
///
/// The merges file is `merges.txt` from huggingface.co/openai/clip-vit-base-patch32: the first
/// 48,894 merges of `bpe_simple_vocab_16e6.txt.gz` (the only ones CLIP uses), uncompressed.
public struct CLIPTokenizer: Sendable {
    public static let contextLength = 77

    public let startToken: Int32
    public let endToken: Int32
    /// Merge rank keyed by "left right".
    private let ranks: [String: Int]
    private let encoder: [String: Int32]
    /// Byte value to symbol, and the symbols in vocabulary order.
    private static let byteTable = makeByteSymbols()

    /// - Parameter merges: the merges file's text. A `#version` first line is skipped.
    public init(merges: String) {
        var lines = merges.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let first = lines.first, first.hasPrefix("#version") || first.hasPrefix("\"bpe_simple_vocab") {
            lines.removeFirst()
        }
        // open_clip uses merges[1 : 49152 - 256 - 2 + 1].
        if lines.count > 48_894 { lines = Array(lines.prefix(48_894)) }

        var vocab: [String] = Self.byteTable.vocabOrder
        vocab += Self.byteTable.vocabOrder.map { $0 + "</w>" }
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks["\(parts[0]) \(parts[1])"] = i
            vocab.append(String(parts[0]) + String(parts[1]))
        }
        vocab += ["<|startoftext|>", "<|endoftext|>"]
        var encoder: [String: Int32] = [:]
        encoder.reserveCapacity(vocab.count)
        for (i, v) in vocab.enumerated() where encoder[v] == nil { encoder[v] = Int32(i) }
        self.ranks = ranks
        self.encoder = encoder
        startToken = encoder["<|startoftext|>"]!
        endToken = encoder["<|endoftext|>"]!
    }

    public init(mergesURL: URL) throws {
        self.init(merges: try String(contentsOf: mergesURL, encoding: .utf8))
    }

    public var vocabularySize: Int { encoder.count }

    /// Token ids for the text, without start/end tokens or padding.
    public func tokenIds(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for word in Self.preTokenize(Self.clean(text)) {
            let table = Self.byteTable.byByte
            let symbols = word.utf8.map { table[Int($0)] }
            for piece in bpe(symbols) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        return ids
    }

    /// What the text model takes: start, tokens, end, zero padding, `contextLength` long.
    /// Over-long text is cut and still ends with the end token (as open_clip does).
    public func encode(_ text: String, contextLength: Int = CLIPTokenizer.contextLength) -> [Int32] {
        var tokens = [startToken] + tokenIds(text) + [endToken]
        if tokens.count > contextLength {
            tokens = Array(tokens.prefix(contextLength))
            tokens[contextLength - 1] = endToken
        }
        return tokens + Array(repeating: 0, count: contextLength - tokens.count)
    }

    // MARK: - Steps

    /// open_clip's basic + whitespace clean, then lower case (ftfy is not reproduced).
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive])

    static func preTokenize(_ text: String) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    /// Byte-pair merge one word (already mapped to byte symbols). Returns vocabulary entries.
    func bpe(_ symbols: [String]) -> [String] {
        guard !symbols.isEmpty else { return [] }
        var word = symbols
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks["\(word[i]) \(word[i + 1])"], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            // Merge every occurrence of this pair, left to right (as the reference does).
            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }

    /// GPT-2's reversible byte to printable-character table, in OpenAI's order.
    private static func makeByteSymbols() -> (byByte: [String], vocabOrder: [String]) {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        // Vocabulary order follows bs (printables first); byte lookups need it by byte value.
        var byByte = Array(repeating: "", count: 256)
        for (b, c) in zip(bs, cs) { byByte[b] = String(UnicodeScalar(UInt32(c))!) }
        return (byByte, cs.map { String(UnicodeScalar(UInt32($0))!) })
    }
}
