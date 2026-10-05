import Foundation
import HAPKit

/// A playlist as a standard .m3u file (a backup, or for other players). Each song's line is
/// its path on the player's drive, or its file name when the path isn't known.
enum M3UExport {
    static func text(name: String, tracks: [Track], paths: [Int: String]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        for track in tracks {
            lines.append("#EXTINF:\(track.duration ?? -1),\(track.artist?.name ?? "") - \(track.name)")
            lines.append(paths[track.trackid] ?? track.filename ?? track.name)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
