import MatrixCore
import Testing

@Test
func ownQueuedMessageWithServerEventIDIsShownAsAccepted() {
    let state = MessageDeliveryState.reconciled(
        mappedState: .queued,
        isOwnMessage: true,
        eventID: "$event:example.com",
        hasReadReceipts: false
    )

    #expect(state == .accepted)
}

@Test
func ownAcceptedMessageWithReadReceiptsIsShownAsEchoed() {
    let state = MessageDeliveryState.reconciled(
        mappedState: .accepted,
        isOwnMessage: true,
        eventID: "$event:example.com",
        hasReadReceipts: true
    )

    #expect(state == .echoed)
}

@Test
func ownSendingMessageWithServerEventIDIsShownAsAccepted() {
    let state = MessageDeliveryState.reconciled(
        mappedState: .sending,
        isOwnMessage: true,
        eventID: "$event:example.com",
        hasReadReceipts: false
    )

    #expect(state == .accepted)
}

@Test
func permanentFailureWithoutServerAcceptanceStaysRejected() {
    let state = MessageDeliveryState.reconciled(
        mappedState: .permanentFailure,
        isOwnMessage: true,
        eventID: nil,
        hasReadReceipts: false
    )

    #expect(state == .permanentFailure)
}
