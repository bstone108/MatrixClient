import AppKit
import MatrixCore

final class RoomListCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private let modeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewField.font = .systemFont(ofSize: 11)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.maximumNumberOfLines = 1
        previewField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badgeField.textColor = .controlAccentColor
        modeField.font = .systemFont(ofSize: 10, weight: .medium)
        modeField.textColor = .tertiaryLabelColor

        let topRow = NSStackView(views: [titleField, NSView(), modeField, badgeField])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        let stack = NSStackView(views: [topRow, previewField])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(room: RoomSummary, selected: Bool, notificationMode: RoomNotificationMode) {
        titleField.stringValue = RoomListPresentationPolicy.displayTitle(for: room)
        titleField.setAccessibilityLabel(RoomListPresentationPolicy.accessibilityLabel(for: room))
        setAccessibilityLabel(RoomListPresentationPolicy.accessibilityLabel(for: room))
        previewField.stringValue = roomListPreview(for: room)
        badgeField.stringValue = ""
        badgeField.isHidden = true
        modeField.stringValue = notificationMode.shortLabel ?? ""
        modeField.isHidden = notificationMode.shortLabel == nil
        titleField.font = .systemFont(ofSize: 13, weight: (selected || RoomListPresentationPolicy.hasUnread(room)) ? .bold : .semibold)
        titleField.textColor = room.membership == .notJoined ? .systemRed : .labelColor

        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            previewField.textColor = .labelColor
        } else if room.membership == .notJoined {
            previewField.textColor = .systemRed.withAlphaComponent(0.85)
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.22).cgColor
        } else if room.membership == .invited {
            previewField.textColor = .systemOrange
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
        } else {
            previewField.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
        }
    }

    private func roomListPreview(for room: RoomSummary) -> String {
        switch room.membership {
        case .notJoined:
            return room.topic.isEmpty ? "Not joined" : "Not joined  •  \(room.topic)"
        case .invited:
            return room.topic.isEmpty ? "Invited" : "Invited  •  \(room.topic)"
        case .left:
            return room.topic.isEmpty ? "Left room" : "Left room  •  \(room.topic)"
        case .joined:
            break
        }

        if room.lastMessagePreview.isEmpty {
            return room.topic.isEmpty ? "No messages yet" : room.topic
        }
        if room.lastSenderDisplayName.isEmpty {
            return room.lastMessagePreview
        }
        return "\(room.lastSenderDisplayName): \(room.lastMessagePreview)"
    }
}

private final class RoomListSectionView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) { label.stringValue = title }
}

final class RoomListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum ListRow {
        case room(RoomSummary)
        case section(String)
    }

    private let state: WorkspaceStateController
    private let tableView = NSTableView(frame: .zero)
    private let emptyField = NSTextField(wrappingLabelWithString: "No rooms in this list yet.")
    private var isApplyingSelection = false
    private var rows: [ListRow] = []

    init(state: WorkspaceStateController) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rooms"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 58
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.menu = makeRoomMenu()

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        emptyField.font = .systemFont(ofSize: 12)
        emptyField.textColor = .secondaryLabelColor
        emptyField.alignment = .center
        emptyField.maximumNumberOfLines = 0
        emptyField.translatesAutoresizingMaskIntoConstraints = false
        emptyField.isHidden = true
        root.addSubview(emptyField)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            emptyField.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addRoomListObserver { [weak self] in
            self?.reloadData()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .section(title):
            let identifier = NSUserInterfaceItemIdentifier("RoomSection")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RoomListSectionView) ?? {
                let newCell = RoomListSectionView()
                newCell.identifier = identifier
                return newCell
            }()
            cell.configure(title: title)
            return cell
        case let .room(room):
            let identifier = NSUserInterfaceItemIdentifier("RoomCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RoomListCellView) ?? {
                let newCell = RoomListCellView()
                newCell.identifier = identifier
                return newCell
            }()
            cell.configure(
                room: room,
                selected: state.selectedRoomID == room.roomID,
                notificationMode: state.roomNotificationMode(for: room.roomID)
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return 28 }
        return 58
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        guard tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return }
        guard case let .room(room) = rows[tableView.selectedRow] else {
            tableView.deselectAll(nil)
            return
        }

        let selectedRoomID = room.roomID
        guard state.selectedRoomID != selectedRoomID else { return }
        state.selectRoom(selectedRoomID)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return false }
        return true
    }

    private func reloadData() {
        rebuildRows()
        tableView.reloadData()
        emptyField.isHidden = !rows.isEmpty
        emptyField.stringValue = state.displayedSpaceID == nil
            ? "No rooms yet. When this account syncs, they will appear here."
            : "No rooms in this space yet."
        guard let selectedRoomID = state.selectedRoomID,
              let row = rows.firstIndex(where: {
                  if case let .room(room) = $0 { return room.roomID == selectedRoomID }
                  return false
              }) else {
            guard tableView.selectedRow != -1 else { return }
            isApplyingSelection = true
            tableView.deselectAll(nil)
            isApplyingSelection = false
            return
        }

        if tableView.selectedRow != row {
            isApplyingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingSelection = false
        }
    }

    private func rebuildRows() {
        let sections = RoomListPresentationPolicy.sections(
            rooms: state.rooms,
            inSpace: state.displayedSpaceID != nil
        )
        var grouped: [ListRow] = []
        for section in sections {
            grouped.append(.section(section.title))
            grouped.append(contentsOf: section.rooms.map(ListRow.room))
        }
        rows = grouped
    }

    private func makeRoomMenu() -> NSMenu {
        let menu = NSMenu(title: "Room")
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func roomAtClickedRow() -> RoomSummary? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count, case let .room(room) = rows[row] else {
            return nil
        }
        return room
    }

    @objc
    private func setClickedRoomNotificationMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = RoomNotificationMode(rawValue: raw),
              let room = roomAtClickedRow() else {
            return
        }
        state.setRoomNotificationMode(mode, for: room.roomID)
    }
}

extension RoomListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let room = roomAtClickedRow() else { return }
        let current = state.roomNotificationMode(for: room.roomID)
        for mode in RoomNotificationMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(setClickedRoomNotificationMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == current ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
        }
    }
}
