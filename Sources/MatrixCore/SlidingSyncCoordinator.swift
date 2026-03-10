import Foundation

public actor SlidingSyncCoordinator {
    private var spaces: [SpaceSummary]
    private var rooms: [RoomIdentifier: RoomSummary]
    private var broadcasters: [String: AsyncBroadcaster<[RoomSummary]>] = [:]

    public init(spaces: [SpaceSummary], rooms: [RoomSummary]) {
        self.spaces = spaces
        self.rooms = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })
    }

    public func spaceSummaries() -> [SpaceSummary] {
        spaces
    }

    public func stream(spaceID: SpaceIdentifier?) -> AsyncStream<[RoomSummary]> {
        let key = spaceID?.rawValue ?? "__all__"
        if broadcasters[key] == nil {
            broadcasters[key] = AsyncBroadcaster(initialValue: filteredRooms(spaceID: spaceID))
        }
        return broadcasters[key]!.stream()
    }

    public func roomSummary(for roomID: RoomIdentifier) -> RoomSummary? {
        rooms[roomID]
    }

    public func roomSummaries(spaceID: SpaceIdentifier?) -> [RoomSummary] {
        filteredRooms(spaceID: spaceID)
    }

    public func replace(spaces: [SpaceSummary], rooms: [RoomSummary]) {
        if !spaces.isEmpty {
            self.spaces = spaces
        }
        for room in rooms {
            self.rooms[room.roomID] = room
        }
        let keys = broadcasters.keys.isEmpty ? ["__all__"] : Array(broadcasters.keys)
        for key in keys {
            let spaceID = key == "__all__" ? nil : SpaceIdentifier(rawValue: key)
            broadcasters[key]?.yield(filteredRooms(spaceID: spaceID))
        }
    }

    public func updateRoomSummary(_ roomSummary: RoomSummary) {
        rooms[roomSummary.roomID] = roomSummary
        let allKeys = Set(broadcasters.keys)
        for key in allKeys {
            let spaceID = key == "__all__" ? nil : SpaceIdentifier(rawValue: key)
            broadcasters[key]?.yield(filteredRooms(spaceID: spaceID))
        }
    }

    private func filteredRooms(spaceID: SpaceIdentifier?) -> [RoomSummary] {
        let relevantIDs: Set<RoomIdentifier>
        if let spaceID, let space = spaces.first(where: { $0.spaceID == spaceID }) {
            relevantIDs = Set(space.roomIDs)
        } else {
            relevantIDs = Set(rooms.keys)
        }
        return rooms.values
            .filter { relevantIDs.contains($0.roomID) }
            .sorted { $0.timestamp > $1.timestamp }
    }
}
