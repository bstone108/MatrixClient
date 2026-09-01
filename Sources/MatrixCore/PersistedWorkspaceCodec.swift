import Foundation

enum PersistedWorkspaceCodec {
    static func decodeRoomSummary(from payload: Data) -> RoomSummary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(RoomSummary.self, from: payload)
    }

    static func decodeTimelineItem(from payload: Data) -> TimelineItem? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TimelineItem.self, from: payload)
    }
}
