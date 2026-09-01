import Foundation
import MatrixCore
import Testing

@Test
func roomHeaderStartsCollapsedAndHidesTheTopic() {
    #expect(RoomHeaderExpansionPolicy.defaultExpanded == false)
    let subtitle = RoomHeaderExpansionPolicy.subtitle(
        for: .joined,
        topic: "A long topic that used to consume the top of the room."
    )
    #expect(!RoomHeaderExpansionPolicy.showsSubtitle(isExpanded: false, subtitle: subtitle))
    #expect(RoomHeaderExpansionPolicy.showsSubtitle(isExpanded: true, subtitle: subtitle))
}

@Test
func clickingTheHeaderTogglesTopicVisibilityAndReturnsToCollapsed() {
    var expanded = RoomHeaderExpansionPolicy.defaultExpanded
    expanded = RoomHeaderExpansionPolicy.expandedAfterToggle(expanded)
    #expect(expanded)
    #expect(
        RoomHeaderExpansionPolicy.showsSubtitle(
            isExpanded: expanded,
            subtitle: "Desktop layout and inspector experiments"
        )
    )

    expanded = RoomHeaderExpansionPolicy.expandedAfterToggle(expanded)
    #expect(!expanded)
    #expect(
        !RoomHeaderExpansionPolicy.showsSubtitle(
            isExpanded: expanded,
            subtitle: "Desktop layout and inspector experiments"
        )
    )
}

@Test
func changingRoomsResetsTheHeaderToCollapsed() {
    let expanded = RoomHeaderExpansionPolicy.expandedAfterToggle(false)
    #expect(expanded)
    #expect(RoomHeaderExpansionPolicy.expandedAfterRoomChange() == false)
}

@Test
func headerControlHasAnAccessibleExpandedAndCollapsedLabel() {
    let collapsed = RoomHeaderExpansionPolicy.accessibilityLabel(
        roomName: "General",
        isExpanded: false,
        canRevealSubtitle: true
    )
    let revealed = RoomHeaderExpansionPolicy.accessibilityLabel(
        roomName: "General",
        isExpanded: true,
        canRevealSubtitle: true
    )
    #expect(collapsed == "General, collapsed. Show room topic.")
    #expect(revealed == "General, expanded. Hide room topic.")
    #expect(RoomHeaderExpansionPolicy.accessibilityHelp(canRevealSubtitle: true) == "Show or hide the room topic")
}

@Test
func membershipStatusIsTheExpandedSubtitleAndStaysHiddenWhileCollapsed() {
    let invited = RoomHeaderExpansionPolicy.subtitle(for: .invited, topic: "Welcome")
    #expect(invited == "Invited  •  Welcome")
    #expect(!RoomHeaderExpansionPolicy.showsSubtitle(isExpanded: false, subtitle: invited))
    #expect(RoomHeaderExpansionPolicy.showsSubtitle(isExpanded: true, subtitle: invited))
}
