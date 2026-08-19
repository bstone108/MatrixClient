import AppKit
import MatrixCore

private final class SidebarSection {
    enum Kind {
        case accounts
        case spaces
        case settings
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }
}

private final class SidebarAccountNode {
    let summary: AccountSummary
    init(summary: AccountSummary) { self.summary = summary }
}

private final class SidebarSpaceNode {
    let summary: SpaceSummary
    init(summary: SpaceSummary) { self.summary = summary }
}

private final class SidebarSettingsNode {
    let destination: WorkspaceSettingsDestination
    init(destination: WorkspaceSettingsDestination) { self.destination = destination }
}

final class RailViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let state: WorkspaceStateController
    private let outlineView = NSOutlineView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let sections = [
        SidebarSection(kind: .accounts),
        SidebarSection(kind: .spaces),
        SidebarSection(kind: .settings)
    ]
    private let settingsDestinations: [WorkspaceSettingsDestination] = [
        .accounts,
        .notifications,
        .securityVerification
    ]
    private var isApplyingSelection = false
    private var selectionApplicationGeneration = 0

    init(state: WorkspaceStateController) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 26
        outlineView.delegate = self
        outlineView.dataSource = self

        scrollView.documentView = outlineView
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
        state.addSidebarObserver { [weak self] in
            self?.reloadData()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil:
            return sections.count
        case let section as SidebarSection:
            switch section.kind {
            case .accounts:
                return state.accounts.count
            case .spaces:
                return state.spaces.count
            case .settings:
                return settingsDestinations.count
            }
        default:
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil:
            return sections[index]
        case let section as SidebarSection:
            switch section.kind {
            case .accounts:
                return SidebarAccountNode(summary: state.accounts[index])
            case .spaces:
                return SidebarSpaceNode(summary: state.spaces[index])
            case .settings:
                return SidebarSettingsNode(destination: settingsDestinations[index])
            }
        default:
            return NSObject()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is SidebarSection)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView) ?? {
            let newCell = NSTableCellView()
            newCell.identifier = cellIdentifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            newCell.textField = textField
            newCell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
            ])
            return newCell
        }()

        switch item {
        case let section as SidebarSection:
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            switch section.kind {
            case .accounts:
                cell.textField?.stringValue = "Accounts"
            case .spaces:
                cell.textField?.stringValue = "Spaces"
            case .settings:
                cell.textField?.stringValue = "Settings"
            }
        case let account as SidebarAccountNode:
            let isActive = state.selectedAccountID == account.summary.accountID &&
                state.selectedSpaceID == nil &&
                state.selectedSettingsDestination == nil
            cell.textField?.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = account.summary.displayName
        case let space as SidebarSpaceNode:
            let selected = state.selectedSettingsDestination == nil &&
                state.selectedSpaceID == space.summary.spaceID
            cell.textField?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = space.summary.displayName
        case let settings as SidebarSettingsNode:
            let selected = state.selectedSettingsDestination == settings.destination
            cell.textField?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = settings.destination.title
        default:
            cell.textField?.stringValue = ""
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        guard outlineView.selectedRow >= 0 else { return }
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if let account = item as? SidebarAccountNode {
            guard state.selectedAccountID != account.summary.accountID ||
                    state.selectedSpaceID != nil ||
                    state.selectedSettingsDestination != nil else { return }
            state.selectAccount(account.summary.accountID)
        } else if let space = item as? SidebarSpaceNode {
            guard state.selectedSpaceID != space.summary.spaceID || state.selectedSettingsDestination != nil else { return }
            state.selectSpace(space.summary.spaceID)
        } else if let settings = item as? SidebarSettingsNode {
            state.selectSettings(settings.destination)
        }
    }

    private func reloadData() {
        selectionApplicationGeneration += 1
        let generation = selectionApplicationGeneration
        isApplyingSelection = true
        defer {
            // AppKit can deliver the selection notification on the next main
            // run-loop turn after reloadData returns. Keep programmatic
            // selection suppressed until that notification has drained.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionApplicationGeneration == generation else { return }
                self.isApplyingSelection = false
            }
        }
        outlineView.reloadData()
        sections.forEach { outlineView.expandItem($0) }

        let targetRow: Int?
        if let selectedSettingsDestination = state.selectedSettingsDestination {
            targetRow = rowForSettings(selectedSettingsDestination)
        } else if let selectedSpaceID = state.selectedSpaceID {
            targetRow = rowForSpace(selectedSpaceID)
        } else {
            targetRow = state.selectedAccountID.flatMap(rowForAccount)
        }

        guard let targetRow else { return }
        if outlineView.selectedRow != targetRow {
            outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        }
    }

    private func rowForAccount(_ accountID: AccountIdentifier) -> Int? {
        for (index, account) in state.accounts.enumerated() where account.accountID == accountID {
            let item = outlineView.child(index, ofItem: sections[0])
            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }
        return nil
    }

    private func rowForSpace(_ spaceID: SpaceIdentifier) -> Int? {
        let spacesSection = sections[1]

        for index in state.spaces.indices where state.spaces[index].spaceID == spaceID {
            let item = outlineView.child(index, ofItem: spacesSection)
            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }
        return nil
    }

    private func rowForSettings(_ destination: WorkspaceSettingsDestination) -> Int? {
        let settingsSection = sections[2]
        for index in settingsDestinations.indices {
            let item = outlineView.child(index, ofItem: settingsSection)
            guard let node = item as? SidebarSettingsNode, node.destination == destination else { continue }
            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }
        return nil
    }

}
