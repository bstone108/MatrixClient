import Foundation

public actor SlidingSyncCoordinator {
    private var rooms: [RoomIdentifier: RoomSummary]
    private var broadcasters: [String: AsyncBroadcaster<[RoomSummary]>] = [:]

    public init(spaces: [SpaceSummary], rooms: [RoomSummary]) {
        self.rooms = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })
    }

    public func spaceSummaries() -> [SpaceSummary] {
        derivedSpaces()
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

    public func allKnownRoomSummaries() -> [RoomSummary] {
        rooms.values.sorted(by: roomSort(lhs:rhs:))
    }

    public func replace(spaces _: [SpaceSummary], rooms: [RoomSummary]) {
        for room in rooms {
            self.rooms[room.roomID] = room
        }
        yieldRoomLists()
    }

    /// Applies a reconciliation as one observable room-list change. Space
    /// membership updates otherwise arrive one room at a time and make rooms
    /// visibly jump between the top-level and space-filtered lists.
    public func apply(roomSummaries: [RoomSummary], removing roomIDs: Set<RoomIdentifier> = []) {
        for roomID in roomIDs {
            rooms.removeValue(forKey: roomID)
        }
        for roomSummary in roomSummaries {
            rooms[roomSummary.roomID] = roomSummary
        }
        yieldRoomLists()
    }

    private func yieldRoomLists() {
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
        let summaries = rooms.values.filter { summary in
            guard summary.roomKind == .room, summary.membership.isVisibleInLists else {
                return false
            }

            if let spaceID {
                return summary.spaceIDs.contains(spaceID)
            }

            return !summary.belongsToSpace
        }

        return summaries.sorted(by: roomSort(lhs:rhs:))
    }

    private func derivedSpaces() -> [SpaceSummary] {
        let allRooms = Array(rooms.values)
        let visibleSpaces = allRooms.filter { summary in
            summary.roomKind == .space && summary.membership.isVisibleInLists
        }

        return visibleSpaces
            .map { spaceSummary in
                let childRooms = allRooms.filter { room in
                    room.roomKind == .room &&
                        room.membership.isVisibleInLists &&
                        room.spaceIDs.contains(spaceSummary.roomID.asSpaceIdentifier)
                }.sorted(by: roomSort(lhs:rhs:))
                let unreadCount = childRooms
                    .filter(\.isJoined)
                    .reduce(0) { $0 + $1.unreadCount }

                return SpaceSummary(
                    spaceID: spaceSummary.roomID.asSpaceIdentifier,
                    displayName: spaceSummary.displayName,
                    unreadCount: unreadCount,
                    roomIDs: childRooms.map(\.roomID)
                )
            }
            .sorted { lhs, rhs in
                guard let lhsSummary = rooms[RoomIdentifier(rawValue: lhs.spaceID.rawValue)],
                      let rhsSummary = rooms[RoomIdentifier(rawValue: rhs.spaceID.rawValue)] else {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                if lhsSummary.membership.listPriority != rhsSummary.membership.listPriority {
                    return lhsSummary.membership.listPriority < rhsSummary.membership.listPriority
                }

                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func roomSort(lhs: RoomSummary, rhs: RoomSummary) -> Bool {
        if lhs.membership.listPriority != rhs.membership.listPriority {
            return lhs.membership.listPriority < rhs.membership.listPriority
        }

        if lhs.membership == .notJoined || rhs.membership == .notJoined {
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private extension RoomIdentifier {
    var asSpaceIdentifier: SpaceIdentifier {
        SpaceIdentifier(rawValue: rawValue)
    }
}
