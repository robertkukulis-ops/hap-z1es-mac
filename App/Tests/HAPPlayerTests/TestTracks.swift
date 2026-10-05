import Foundation
import HAPKit

/// Builds a `Track` the way the player describes one (decoded from JSON), for tests.
func makeTrack(_ id: Int, artist: String = "Someone", title: String? = nil, album: String? = nil,
               albumArtist: String? = nil, albumYear: String? = nil, year: String? = nil,
               bits: Int? = nil, rate: Int? = nil, codec: String? = nil,
               plays: Int? = nil, genre: String? = nil, duration: Int? = nil) throws -> Track {
    var json: [String: Any] = ["trackid": id, "name": title ?? "Song \(id)", "artist": ["name": artist]]
    if let album {
        var a: [String: Any] = ["albumid": 1, "name": album]
        if let albumArtist { a["album_artist"] = ["name": albumArtist] }
        if let albumYear { a["release_date"] = albumYear }
        json["album"] = a
    }
    if let year { json["release_date"] = year }
    if bits != nil || rate != nil || codec != nil {
        var c: [String: Any] = [:]
        if let bits { c["bit_width"] = bits }
        if let rate { c["sample_rate"] = rate }
        if let codec { c["codec_type"] = codec }
        json["codec"] = c
    }
    if let plays { json["number_of_plays"] = plays }
    if let genre { json["genre"] = ["name": genre] }
    if let duration { json["duration"] = duration }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
}
