import AppKit
import MatrixCore

final class RoomListCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        previewField.font = .systemFont(ofSize: 11)
        previewField.textColor = .secondaryLabelColor
        badgeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badgeField.textColor = .controlAccentColor

        let topRow = NSStackView(views: [titleField, NSView(), badgeField])
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

    func configure(room: RoomSummary, selected: Bool) {
        titleField.stringValue = room.displayName
        previewField.stringValue = roomListPreview(for: room)
        badgeField.stringValue = room.unreadCount > 0 ? String(room.unreadCount) : ""
        titleField.font = .systemFont(ofSize: 13, weight: selected ? .bold : .semibold)
        titleField.textColor = room.membership == .notJoined ? .systemRed : .labelColor

        if room.membership == .notJoined {
            previewField.textColor = .systemRed.withAlphaComponent(0.85)
            if selected {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderWidth = 0
                layer?.borderColor = NSColor.clear.cgColor
            } else {
                layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
                layer?.borderWidth = 1
                layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.22).cgColor
            }
        } else if room.membership == .invited {
            previewField.textColor = .systemOrange
            layer?.backgroundColor = NSColor.clear.cgColor
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

final class RoomListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let state: WorkspaceStateController
    private let tableView = NSTableView(frame: .zero)
    private var isApplyingSelection = false

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

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
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
        state.rooms.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RoomCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RoomListCellView) ?? {
            let newCell = RoomListCellView()
            newCell.identifier = identifier
            return newCell
        }()
        let room = state.rooms[row]
        cell.configure(room: room, selected: state.selectedRoomID == room.roomID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        guard tableView.selectedRow >= 0, tableView.selectedRow < state.rooms.count else { return }

        let selectedRoomID = state.rooms[tableView.selectedRow].roomID
        guard state.selectedRoomID != selectedRoomID else { return }
        state.selectRoom(selectedRoomID)
    }

    private func reloadData() {
        tableView.reloadData()
        guard let selectedRoomID = state.selectedRoomID,
              let row = state.rooms.firstIndex(where: { $0.roomID == selectedRoomID }) else {
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
}
