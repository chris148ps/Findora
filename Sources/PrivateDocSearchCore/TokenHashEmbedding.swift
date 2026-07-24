import CryptoKit
import Foundation

/// Deterministic, local fallback used before an MLX embedder is installed.
///
/// It supports exercising the complete index transaction and contributes
/// fuzzy token matching, but the UI must not present it as a neural model.
public struct TokenHashEmbedding: EmbeddingProviding {
    public let modelID = "builtin-token-hash"
    public let modelVersion = "1"
    public let dimensions: Int

    public init(dimensions: Int = 384) {
        self.dimensions = dimensions
    }

    public func embed(documents: [String]) async throws -> [[Float]] {
        documents.map(vector)
    }

    public func embed(query: String) async throws -> [Float] {
        vector(query)
    }

    private func vector(_ text: String) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            let data = Data(token.utf8)
            let digest = Array(SHA256.hash(data: data))
            let index = Int(digest[0]) << 8 | Int(digest[1])
            let sign: Float = digest[2] & 1 == 0 ? 1 : -1
            values[index % dimensions] += sign

            if token.count >= 4 {
                let characters = Array(token)
                for start in 0...(characters.count - 3) {
                    let trigram = String(characters[start..<(start + 3)])
                    let triDigest = Array(SHA256.hash(data: Data(trigram.utf8)))
                    let triIndex = Int(triDigest[0]) << 8 | Int(triDigest[1])
                    values[triIndex % dimensions] += 0.2
                }
            }
        }
        return normalize(values)
    }

    private func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
}
