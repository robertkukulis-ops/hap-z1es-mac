import Foundation

/// A whole album in one audio file, described by a `.cue` sheet next to it: something the app
/// can split into songs (the player itself doesn't read `.cue` files).
public struct CueAlbum: Sendable, Equatable {
    public let cue: URL
    public let audio: URL
    public let sheet: CueSheet
    /// FLAC or WAV: macOS can read it, so it can be split. APE, WavPack… can't.
    public let supported: Bool

    static let splittable: Set<String> = ["flac", "wav"]
    static let audioExtensions: Set<String> = ["flac", "wav", "ape", "wv", "tta", "m4a", "aif", "aiff"]

    /// The songs' file names: "01 - Title.flac" (safe for the player's drive).
    public var songNames: [String] {
        sheet.tracks.map { track in
            let title = track.title?.trimmingCharacters(in: .whitespaces)
            let name = String(format: "%02d - ", track.number) + ((title?.isEmpty == false ? title : nil) ?? "Track \(track.number)")
            return HAPDrive.safeName(name) + ".flac"
        }
    }

    /// Albums in `folder` (not in its subfolders): `.cue` sheets that name exactly one audio file
    /// that's there. Matched case-insensitively, and with any audio extension, because rippers
    /// often convert `Album.wav` to `Album.flac` without editing the `.cue`.
    public static func find(in folder: URL) -> [CueAlbum] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let visible = names.filter { !$0.hasPrefix(".") }
        let all: [CueAlbum] = visible.filter { $0.lowercased().hasSuffix(".cue") }.sorted().compactMap { cueName in
            let cueURL = folder.appendingPathComponent(cueName)
            guard let data = try? Data(contentsOf: cueURL) else { return nil }
            let sheet = CueSheet(data: data)
            guard sheet.files.count == 1, !sheet.tracks.isEmpty, let named = sheet.files.first else { return nil }
            guard let audio = audioFile(named: named, among: visible, in: folder) else { return nil }
            return CueAlbum(cue: cueURL, audio: audio, sheet: sheet,
                            supported: splittable.contains(audio.pathExtension.lowercased()))
        }
        // Rips often carry two .cue files for one audio file (e.g. two text encodings): each audio
        // file belongs to one album only — the .cue named like it, else the first.
        var chosen: [String: CueAlbum] = [:]
        for album in all {
            let key = album.audio.path
            let named = album.cue.deletingPathExtension().lastPathComponent.lowercased()
                == album.audio.deletingPathExtension().lastPathComponent.lowercased()
            if chosen[key] == nil || named { chosen[key] = album }
        }
        return all.filter { chosen[$0.audio.path] == $0 }
    }

    /// The audio file a `.cue` names, among `names` in `folder`.
    static func audioFile(named: String, among names: [String], in folder: URL) -> URL? {
        let wanted = (named as NSString).lastPathComponent.lowercased()
        let base = (wanted as NSString).deletingPathExtension
        let match = names.first { $0.lowercased() == wanted }
            ?? names.first { name in
                let lower = name.lowercased()
                return (lower as NSString).deletingPathExtension == base
                    && audioExtensions.contains((lower as NSString).pathExtension)
            }
        return match.map { folder.appendingPathComponent($0) }
    }

    /// Whether the `.cue` at `cue` belongs to a big audio file already in `folder` (e.g. an album
    /// copied to the player earlier without its `.cue`): then copying the `.cue` there lets the
    /// album be split.
    public static func cue(_ cue: URL, fitsAudioIn folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: cue) else { return false }
        let sheet = CueSheet(data: data)
        guard sheet.files.count == 1, !sheet.tracks.isEmpty, let named = sheet.files.first else { return false }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        return audioFile(named: named, among: names, in: folder) != nil
    }
}
