import SwiftUI
import UIKit

/// The browser's items, as a UIKit collection view showing a list or a grid.
///
/// UIKit rather than SwiftUI's `List`: `listRowBackground` replaces the system's
/// state-aware row background wholesale, so rows could not be clear at rest yet show a
/// fill while swiped or pressed. One collection view also serves both layouts, switching
/// between them in place.
/// An entry of an item's long-press menu.
struct BrowserAction {
    let title: String
    let symbol: String
    var isDestructive = false
    let perform: () -> Void
}

struct BrowserList: UIViewRepresentable {
    let items: [BrowserItem]
    let mode: BrowserViewMode
    /// Non-nil while items are being picked for a batch action: the picked ones. A tap then
    /// picks instead of opening.
    let selection: Set<URL>?
    /// Whether swiping a row deletes it.
    let canDelete: (BrowserItem) -> Bool
    let onSelect: (BrowserItem) -> Void
    let onDelete: (BrowserItem) -> Void
    /// The long-press menu of an item; empty for none.
    let actions: (BrowserItem) -> [BrowserAction]

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, canDelete: canDelete, onSelect: onSelect, onDelete: onDelete, actions: actions)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let layout = UICollectionViewCompositionalLayout { [weak coordinator] _, environment in
            coordinator?.section(in: environment)
        }
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = coordinator
        coordinator.attach(to: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.canDelete = canDelete
        context.coordinator.onSelect = onSelect
        context.coordinator.onDelete = onDelete
        context.coordinator.actions = actions
        context.coordinator.setSelection(selection)
        context.coordinator.apply(items, mode: mode)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var canDelete: (BrowserItem) -> Bool
        var onSelect: (BrowserItem) -> Void
        var onDelete: (BrowserItem) -> Void
        var actions: (BrowserItem) -> [BrowserAction]
        private var selection: Set<URL>?
        private var mode: BrowserViewMode
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, BrowserItem>?
        private var hasAppliedItems = false

        private enum Grid {
            /// The narrowest a tile may get before a column is dropped.
            static let minimumTileWidth: CGFloat = 200
            static let columnSpacing: CGFloat = 12
            static let rowSpacing: CGFloat = 18
            static let margin: CGFloat = 16
        }

        init(
            mode: BrowserViewMode,
            canDelete: @escaping (BrowserItem) -> Bool,
            onSelect: @escaping (BrowserItem) -> Void,
            onDelete: @escaping (BrowserItem) -> Void,
            actions: @escaping (BrowserItem) -> [BrowserAction]
        ) {
            self.mode = mode
            self.canDelete = canDelete
            self.onSelect = onSelect
            self.onDelete = onDelete
            self.actions = actions
        }

        /// Whether `item` is picked; nil when nothing is being picked.
        private func isPicked(_ item: BrowserItem) -> Bool? {
            selection.map { $0.contains(item.url) }
        }

        func setSelection(_ selection: Set<URL>?) {
            guard selection != self.selection, let dataSource else { return }
            self.selection = selection
            // Every cell shows or hides its mark, so all are rebuilt in place.
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func attach(to collectionView: UICollectionView) {
            self.collectionView = collectionView

            let listCell = UICollectionView.CellRegistration<UICollectionViewListCell, BrowserItem> { [weak self] cell, _, item in
                let isPicked = self?.isPicked(item)
                cell.contentConfiguration = UIHostingConfiguration {
                    BrowserCell(item: item, mode: .list, isPicked: isPicked)
                }
                cell.accessories = item.isDirectory && isPicked == nil ? [.disclosureIndicator()] : []
                cell.configurationUpdateHandler = { cell, state in
                    var background = UIBackgroundConfiguration.listCell().updated(for: state)
                    // Clear at rest; a soft fill while swiped, pressed or selected.
                    let isActive = state.isSwiped || state.isHighlighted || state.isSelected
                    background.backgroundColor = isActive ? UIColor.white.withAlphaComponent(0.09) : .clear
                    cell.backgroundConfiguration = background
                }
            }
            let gridCell = UICollectionView.CellRegistration<UICollectionViewCell, BrowserItem> { [weak self] cell, _, item in
                let isPicked = self?.isPicked(item)
                cell.configurationUpdateHandler = { cell, state in
                    cell.contentConfiguration = UIHostingConfiguration {
                        BrowserCell(item: item, mode: .grid, isHighlighted: state.isHighlighted, isPicked: isPicked)
                    }
                    .margins(.all, 0)
                }
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
                switch self?.mode ?? .list {
                case .list: collectionView.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: item)
                case .grid: collectionView.dequeueConfiguredReusableCell(using: gridCell, for: indexPath, item: item)
                }
            }
        }

        func apply(_ items: [BrowserItem], mode: BrowserViewMode) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, BrowserItem>()
            snapshot.appendSections([0])
            snapshot.appendItems(items)

            guard mode != self.mode, let collectionView else {
                // The first population should not animate in.
                dataSource?.apply(snapshot, animatingDifferences: hasAppliedItems)
                hasAppliedItems = true
                return
            }
            // The two layouts use different cell classes, so every cell is rebuilt.
            self.mode = mode
            UIView.transition(with: collectionView, duration: 0.25, options: .transitionCrossDissolve) {
                collectionView.collectionViewLayout.invalidateLayout()
                self.dataSource?.applySnapshotUsingReloadData(snapshot)
            }
        }

        // MARK: Layout

        func section(in environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
            switch mode {
            case .list: listSection(in: environment)
            case .grid: gridSection(in: environment)
            }
        }

        private func listSection(in environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            configuration.showsSeparators = false
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            return .list(using: configuration, layoutEnvironment: environment)
        }

        private func gridSection(in environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
            let width = environment.container.effectiveContentSize.width - Grid.margin * 2
            let columns = max(2, Int((width + Grid.columnSpacing) / (Grid.minimumTileWidth + Grid.columnSpacing)))
            // Tile widths are spelled out: left to divide a fractional width itself, the
            // layout sizes self-sizing tiles from their content instead.
            let tileWidth = ((width - Grid.columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            let estimatedHeight = NSCollectionLayoutDimension.estimated(tileWidth * 9 / 16 + 50)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(tileWidth), heightDimension: estimatedHeight)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: estimatedHeight),
                subitems: [item]
            )
            group.interItemSpacing = .fixed(Grid.columnSpacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Grid.rowSpacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 8, leading: Grid.margin, bottom: 24, trailing: Grid.margin
            )
            return section
        }

        // MARK: Actions

        private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard selection == nil, let item = dataSource?.itemIdentifier(for: indexPath), canDelete(item) else {
                return nil
            }
            let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, completion in
                self?.onDelete(item)
                completion(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            onSelect(item)
        }

        // Long press: the only way to delete in the grid, where there is nothing to swipe.
        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard selection == nil, let indexPath = indexPaths.first,
                  let item = dataSource?.itemIdentifier(for: indexPath) else {
                return nil
            }
            let actions = actions(item)
            guard !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(children: actions.map { action in
                    UIAction(
                        title: action.title,
                        image: UIImage(systemName: action.symbol),
                        attributes: action.isDestructive ? .destructive : []
                    ) { _ in
                        action.perform()
                    }
                })
            })
        }
    }
}
