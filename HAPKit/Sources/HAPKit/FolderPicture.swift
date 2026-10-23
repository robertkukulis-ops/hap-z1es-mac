import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An album folder's picture (cover.jpg, folder.jpg, front.png, …), and turning it into a FLAC
/// cover (a PICTURE block) for split songs. Only reads; the picture file is never changed.
public enum FolderPicture {
    static let extensions: Set<String> = ["jpg", "jpeg", "png"]
    /// Names rippers and shops give the front cover, best first.
    static let coverNames = ["cover", "folder", "front", "albumart", "album"]
    /// Covers bigger than this are made smaller (as JPEG) before going into songs.
    static let largestSide = 1000

    /// The folder's album picture: one named like a cover (cover, folder, front, …), else one
    /// whose name contains "cover" or "front" (not "back"), else the folder's only picture.
    /// Nil when there's none, or several and none named like a cover (e.g. booklet scans).
    public static func find(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let pictures = files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        for name in coverNames {
            if let picture = pictures.first(where: { stem($0) == name }) { return picture }
        }
        if let picture = pictures.first(where: {
            (stem($0).contains("cover") || stem($0).contains("front")) && !stem($0).contains("back")
        }) { return picture }
        return pictures.count == 1 ? pictures[0] : nil
    }

    /// A FLAC PICTURE block body (front cover) for a JPEG or PNG file; nil if it isn't one.
    /// Pictures larger than 1000 pixels a side are made smaller (as JPEG), so every song
    /// doesn't carry a big image.
    public static func flacPictureBlock(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        var mime: String
        switch type {
        case UTType.jpeg.identifier: mime = "image/jpeg"
        case UTType.png.identifier: mime = "image/png"
        default: return nil
        }
        var picture = data, size = (width, height)
        let depth = properties[kCGImagePropertyHasAlpha] as? Bool == true ? 32 : 24
        if max(width, height) > largestSide {
            guard let smaller = smallerJPEG(source) else { return nil }
            (picture, size, mime) = (smaller.data, (smaller.width, smaller.height), "image/jpeg")
        }
        guard picture.count < 1 << 24 - 100 else { return nil }  // a block's length has 3 bytes
        return pictureBody(picture, mime: mime, width: size.0, height: size.1, depth: mime == "image/png" ? depth : 24)
    }

    /// The parts of a PICTURE block: type 3 (front cover), MIME type, empty description,
    /// width, height, colour depth, colours (0 = not a palette image), the picture.
    static func pictureBody(_ picture: Data, mime: String, width: Int, height: Int, depth: Int = 24) -> Data {
        var body = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).bigEndian) { body.append(contentsOf: $0) } }
        u32(3)
        u32(mime.utf8.count); body.append(contentsOf: Array(mime.utf8))
        u32(0)
        u32(width); u32(height); u32(depth); u32(0)
        u32(picture.count); body.append(picture)
        return body
    }

    private static func smallerJPEG(_ source: CGImageSource) -> (data: Data, width: Int, height: Int)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: largestSide,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }
}

/// A Mac album folder's picture, and the songs from that folder as they are (or will be)
/// named on the player.
public struct PlannedPicture: Sendable, Equatable {
    public let picture: URL
    public let songs: [URL]
}

extension UploadPlan {
    /// The pictures of the Mac folders this copy's music comes from (see `FolderPicture.find`),
    /// each with its own songs on the player: ones being copied, split .cue songs, and ones
    /// that are already there. Only those songs' albums get the picture (not every album in a
    /// shared player folder).
    public func folderPictures() -> [PlannedPicture] {
        var byFolder: [String: (folder: URL, songs: [URL])] = [:]  // Mac folder → its songs on the player
        func add(_ macFolder: URL, _ song: URL) {
            byFolder[macFolder.standardizedFileURL.path, default: (macFolder, [])].songs.append(song)
        }
        for item in items { add(item.source.deletingLastPathComponent(), item.destination) }
        for skip in skipped { if let destination = skip.destination { add(skip.source.deletingLastPathComponent(), destination) } }
        for split in albumsToSplit {
            for name in split.album.songNames { add(split.album.cue.deletingLastPathComponent(), split.destinationFolder.appendingPathComponent(name)) }
        }
        return byFolder.values
            .compactMap { entry in FolderPicture.find(in: entry.folder).map { PlannedPicture(picture: $0, songs: entry.songs) } }
            .sorted { $0.picture.path < $1.picture.path }
    }
}
