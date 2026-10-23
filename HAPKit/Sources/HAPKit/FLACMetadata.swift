import Foundation

/// Tags and cover pictures inside a FLAC file (the player reads FLAC's own "Vorbis comments").
/// Only the list of metadata blocks at the start is rewritten; the audio frames after it are
/// copied byte for byte.
public enum FLACMetadata {
    enum BlockType: UInt8 {
        case streamInfo = 0, padding = 1, application = 2, seekTable = 3, vorbisComment = 4, cueSheet = 5, picture = 6
    }

    struct Block {
        var type: UInt8
        var body: Data
    }

    public enum MetadataError: Error, LocalizedError {
        case notFLAC(String)

        public var errorDescription: String? {
            switch self {
            case .notFLAC(let name): "“\(name)” isn't a FLAC file the app can tag."
            }
        }
    }

    /// Replaces the tags (and picture, if one is given) of the FLAC file at `url`.
    public static func write(comments: [(String, String)], picture: Data?, to url: URL) throws {
        let (blocks, audio) = try read(url)
        var kept = blocks.filter {
            ![BlockType.vorbisComment, .picture, .padding].map(\.rawValue).contains($0.type)
        }
        kept.append(Block(type: BlockType.vorbisComment.rawValue, body: vorbisComment(comments)))
        if let picture { kept.append(Block(type: BlockType.picture.rawValue, body: picture)) }
        kept.append(Block(type: BlockType.padding.rawValue, body: Data(count: 4096)))  // room for later edits

        var out = Data("fLaC".utf8)
        for (i, block) in kept.enumerated() {
            let last: UInt8 = i == kept.count - 1 ? 0x80 : 0
            let length = block.body.count
            out.append(contentsOf: [block.type | last, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            out.append(block.body)
        }
        out.append(audio)
        try out.write(to: url, options: .atomic)
    }

    /// The tags as KEY → value (keys in capitals; the first value of a repeated key).
    public static func readComments(_ url: URL) throws -> [String: String] {
        guard let body = try headerBlocks(url).blocks.first(where: { $0.type == BlockType.vorbisComment.rawValue })?.body else { return [:] }
        var pos = 0
        func u32() -> Int {
            defer { pos += 4 }
            return body[body.startIndex + pos..<body.startIndex + pos + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        pos += u32()  // vendor string
        var result: [String: String] = [:]
        for _ in 0..<u32() {
            let length = u32()
            let text = String(decoding: body[body.startIndex + pos..<body.startIndex + pos + length], as: UTF8.self)
            pos += length
            if let equals = text.firstIndex(of: "=") {
                let key = text[..<equals].uppercased()
                if result[key] == nil { result[key] = String(text[text.index(after: equals)...]) }
            }
        }
        return result
    }

    /// The raw body of the file's first PICTURE block (to copy it into other files).
    public static func pictureBlock(_ url: URL) throws -> Data? {
        try headerBlocks(url).blocks.first { $0.type == BlockType.picture.rawValue }?.body
    }

    /// Where the audio starts: the size of "fLaC" plus all metadata blocks.
    public static func headerLength(of url: URL) throws -> Int {
        try headerBlocks(url).length
    }

    /// Reads only the metadata blocks at the start, stopping at the last one (an album file can
    /// be gigabytes, possibly on the player's drive).
    static func headerBlocks(_ url: URL) throws -> (blocks: [Block], length: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func next(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw MetadataError.notFLAC(url.lastPathComponent) }
            return data
        }
        guard try next(4) == Data("fLaC".utf8) else { throw MetadataError.notFLAC(url.lastPathComponent) }
        var blocks: [Block] = [], length = 4
        while true {
            let header = try next(4)
            let size = Int(header[0 + header.startIndex + 1]) << 16 | Int(header[header.startIndex + 2]) << 8 | Int(header[header.startIndex + 3])
            blocks.append(Block(type: header[header.startIndex] & 0x7F, body: try next(size)))
            length += 4 + size
            if header[header.startIndex] & 0x80 != 0 { return (blocks, length) }
        }
    }

    // MARK: - Plumbing

    static func read(_ url: URL) throws -> (blocks: [Block], audio: Data) {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { throw MetadataError.notFLAC(url.lastPathComponent) }
        var blocks: [Block] = [], pos = 4
        while pos + 4 <= data.count {
            let header = data[pos]
            let length = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard pos + 4 + length <= data.count else { throw MetadataError.notFLAC(url.lastPathComponent) }
            blocks.append(Block(type: header & 0x7F, body: data.subdata(in: pos + 4..<pos + 4 + length)))
            pos += 4 + length
            if header & 0x80 != 0 { break }
        }
        return (blocks, data.subdata(in: pos..<data.count))
    }

    static func vorbisComment(_ comments: [(String, String)]) -> Data {
        var body = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { body.append(contentsOf: $0) } }
        let vendor = Data("HAP Player".utf8)
        u32(vendor.count)
        body.append(vendor)
        u32(comments.count)
        for (key, value) in comments {
            let entry = Data("\(key)=\(value)".utf8)
            u32(entry.count)
            body.append(entry)
        }
        return body
    }
}
