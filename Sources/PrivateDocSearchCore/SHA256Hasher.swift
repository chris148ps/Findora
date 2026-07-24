import CryptoKit
import Foundation

public struct SHA256Hasher: Sendable {
    public init() {}

    public func hash(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw PrivateDocSearchError.folderUnavailable(url.path)
        }

        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1_048_576
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? PrivateDocSearchError.invalidPDF("Datei konnte nicht gelesen werden.")
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

