import Foundation
import Testing
@testable import Dusk

@Suite("Plex media part decoding")
struct PlexMediaPartDecodingTests {
    /// Plex can omit `id` on a stream (seen on an embedded EIA-608 caption
    /// track); that stream is dropped instead of failing the whole item.
    @Test func streamWithoutIDOrUnknownTypeIsDroppedNotFatal() throws {
        let json = """
        {
            "id": 1,
            "key": "/library/parts/1/file.mkv",
            "container": "mkv",
            "Stream": [
                { "id": 175569, "streamType": 1, "codec": "h264" },
                { "id": 175568, "streamType": 2, "codec": "eac3", "channels": 6 },
                { "streamType": 3, "codec": "eia_608", "embeddedInVideo": "1" },
                { "id": 175572, "streamType": 9, "codec": "unknown" },
                { "id": 175571, "streamType": 3, "codec": "srt", "key": "/library/streams/175571" }
            ]
        }
        """

        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(json.utf8))

        #expect(part.streams.map(\.id) == [175569, 175568, 175571])
        #expect(part.streams.map(\.streamType) == [.video, .audio, .subtitle])
    }
}
