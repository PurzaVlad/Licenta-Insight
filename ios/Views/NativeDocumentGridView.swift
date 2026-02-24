import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Cell content views (visual only, no gesture handlers)

struct DocGridCell: View {
    let document: Document
    let isSelected: Bool
    let isEditing: Bool
    @EnvironmentObject private var documentManager: DocumentManager

    var body: some View {
        let parts = splitDisplayTitle(document.title)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    if document.type == .zip {
                        RoundedRectangle(cornerRadius: 10).fill(Color("Primary"))
                        Image(systemName: zipSymbolName()).font(.system(size: 28)).foregroundColor(.white)
                    } else if isProtectedPDFPreview(document, documentManager: documentManager) {
                        RoundedRectangle(cornerRadius: 10).fill(Color("Primary"))
                        Image(systemName: "lock.fill").font(.system(size: 28)).foregroundColor(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemBackground))
                        DocumentThumbnailView(document: document, size: CGSize(width: side, height: side))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(width: side, height: side)
            }
            .frame(height: 120)
            .cornerRadius(10)
            .overlay(alignment: .topLeading) {
                if isEditing {
                    NativeGridSelectionIndicator(isSelected: isSelected)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.base)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(fileTypeLabel(documentType: document.type, titleParts: parts))
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct FolderGridCell: View {
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isEditing: Bool
    let isDropTargeted: Bool

    var body: some View {
        let parts = splitDisplayTitle(folder.name)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color("Primary"))
                    Image(systemName: "folder.fill").font(.system(size: 28)).foregroundColor(.white)
                }
                .frame(width: side, height: side)
            }
            .frame(height: 120)
            .cornerRadius(10)
            .overlay(alignment: .topLeading) {
                if isEditing {
                    NativeGridSelectionIndicator(isSelected: isSelected)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.base)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(docCount) item\(docCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color("Primary").opacity(0.18) : Color.clear)
        )
    }
}

// MARK: - NativeDocumentGridView

struct NativeDocumentGridView: UIViewControllerRepresentable {
    let items: [MixedItem]
    @Binding var selectedIds: Set<UUID>
    @Binding var isSelectionMode: Bool
    @Binding var dropTargetedFolderId: UUID?
    let documentManager: DocumentManager
    let onOpenDocument: (Document) -> Void
    let onOpenFolder: (DocumentFolder) -> Void
    let onRenameDocument: (Document) -> Void
    let onMoveDocument: (Document) -> Void
    let onDeleteDocument: (Document) -> Void
    let onConvertDocument: (Document) -> Void
    let onShareDocuments: ([Document]) -> Void
    let onRenameFolderRequest: (DocumentFolder) -> Void
    let onMoveFolderRequest: (DocumentFolder) -> Void
    let onDeleteFolderRequest: (DocumentFolder) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        cv.backgroundColor = .clear
        cv.allowsMultipleSelectionDuringEditing = true
        cv.delegate = context.coordinator
        cv.dragDelegate = context.coordinator
        cv.dropDelegate = context.coordinator
        cv.dragInteractionEnabled = true
        cv.alwaysBounceHorizontal = false
        cv.showsHorizontalScrollIndicator = false

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        cv.addGestureRecognizer(longPress)

        context.coordinator.setup(collectionView: cv)

        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.addSubview(cv)
        cv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cv.topAnchor.constraint(equalTo: vc.view.topAnchor),
            cv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            cv.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let cv = context.coordinator.collectionView else { return }
        let coord = context.coordinator
        coord.parent = self

        if cv.isEditing != isSelectionMode {
            cv.isEditing = isSelectionMode
        }

        coord.applySnapshot(items: items)

        // Sync SwiftUI selection → UIKit
        let uikitSelected = Set(
            cv.indexPathsForSelectedItems?.compactMap { coord.dataSource?.itemIdentifier(for: $0) } ?? []
        )
        if uikitSelected != selectedIds {
            for id in uikitSelected where !selectedIds.contains(id) {
                if let ip = coord.dataSource?.indexPath(for: id) { cv.deselectItem(at: ip, animated: false) }
            }
            for id in selectedIds where !uikitSelected.contains(id) {
                if let ip = coord.dataSource?.indexPath(for: id) { cv.selectItem(at: ip, animated: false, scrollPosition: []) }
            }
        }

        // Reconfigure folder cells when drop target changes
        if dropTargetedFolderId != coord.lastDropTarget {
            var toReconfigure: [UUID] = []
            if let old = coord.lastDropTarget { toReconfigure.append(old) }
            if let new = dropTargetedFolderId { toReconfigure.append(new) }
            coord.lastDropTarget = dropTargetedFolderId
            if !toReconfigure.isEmpty, let ds = coord.dataSource {
                let existing = Set(ds.snapshot().itemIdentifiers)
                let valid = toReconfigure.filter { existing.contains($0) }
                if !valid.isEmpty {
                    var snap = ds.snapshot()
                    snap.reconfigureItems(valid)
                    ds.apply(snap, animatingDifferences: false)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func makeLayout() -> UICollectionViewCompositionalLayout {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1/3), heightDimension: .estimated(170))
        )
        item.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 6, bottom: 9, trailing: 6)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(170)),
            subitems: [item, item, item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 24, trailing: 6)
        return UICollectionViewCompositionalLayout(section: section)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
        UICollectionViewDelegate,
        UICollectionViewDragDelegate,
        UICollectionViewDropDelegate,
        UIGestureRecognizerDelegate
    {
        var parent: NativeDocumentGridView
        var dataSource: UICollectionViewDiffableDataSource<Int, UUID>?
        weak var collectionView: UICollectionView?
        var items: [MixedItem] = []
        var lastDropTarget: UUID?

        init(parent: NativeDocumentGridView) { self.parent = parent }

        func setup(collectionView: UICollectionView) {
            self.collectionView = collectionView
            let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
                guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
                cell.configurationUpdateHandler = { [weak self, item] cell, state in
                    guard let self else { return }
                    let dm = self.parent.documentManager
                    let isDropTargeted = (item.id == self.parent.dropTargetedFolderId)
                    switch item.kind {
                    case .document(let doc):
                        cell.contentConfiguration = UIHostingConfiguration {
                            DocGridCell(document: doc, isSelected: state.isSelected, isEditing: state.isEditing)
                                .environmentObject(dm)
                        }.margins(.all, 0)
                    case .folder(let folder):
                        cell.contentConfiguration = UIHostingConfiguration {
                            FolderGridCell(
                                folder: folder,
                                docCount: dm.itemCount(in: folder.id),
                                isSelected: state.isSelected,
                                isEditing: state.isEditing,
                                isDropTargeted: isDropTargeted
                            )
                        }.margins(.all, 0)
                    }
                }
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: id)
            }
        }

        func applySnapshot(items: [MixedItem]) {
            let ids = items.map(\.id)
            guard ids != (dataSource?.snapshot().itemIdentifiers ?? []) else { return }
            self.items = items
            var snap = NSDiffableDataSourceSnapshot<Int, UUID>()
            snap.appendSections([0])
            snap.appendItems(ids)
            dataSource?.apply(snap, animatingDifferences: true)
        }

        // MARK: Long press → enter selection mode

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let cv = collectionView,
                  !cv.isEditing else { return }
            let point = gesture.location(in: cv)
            guard let ip = cv.indexPathForItem(at: point),
                  let id = dataSource?.itemIdentifier(for: ip) else { return }
            DispatchQueue.main.async {
                self.parent.isSelectionMode = true
                self.parent.selectedIds.insert(id)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: UICollectionViewDelegate – selection

        func collectionView(_ cv: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            true
        }

        func collectionView(_ cv: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            DispatchQueue.main.async { self.parent.isSelectionMode = true }
        }

        func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            if cv.isEditing {
                DispatchQueue.main.async { self.parent.selectedIds.insert(id) }
            } else {
                cv.deselectItem(at: indexPath, animated: true)
                guard let item = items.first(where: { $0.id == id }) else { return }
                switch item.kind {
                case .document(let doc): parent.onOpenDocument(doc)
                case .folder(let folder): parent.onOpenFolder(folder)
                }
            }
        }

        func collectionView(_ cv: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            DispatchQueue.main.async { self.parent.selectedIds.remove(id) }
        }

        // MARK: UICollectionViewDelegate – context menu

        func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                  let item = items.first(where: { $0.id == id }) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return UIMenu() }
                switch item.kind {
                case .document(let doc):
                    return UIMenu(children: [
                        UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.parent.onShareDocuments([doc]) },
                        UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self.parent.onRenameDocument(doc) },
                        UIAction(title: "Move to folder", image: UIImage(systemName: "folder")) { _ in self.parent.onMoveDocument(doc) },
                        UIAction(title: "Convert", image: UIImage(systemName: "arrow.2.circlepath")) { _ in self.parent.onConvertDocument(doc) },
                        UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.parent.onDeleteDocument(doc) }
                    ])
                case .folder(let folder):
                    return UIMenu(children: [
                        UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self.parent.onRenameFolderRequest(folder) },
                        UIAction(title: "Move to folder", image: UIImage(systemName: "folder")) { _ in self.parent.onMoveFolderRequest(folder) },
                        UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.parent.onDeleteFolderRequest(folder) }
                    ])
                }
            }
        }

        // MARK: UICollectionViewDragDelegate

        func collectionView(_ cv: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return [] }
            let provider = NSItemProvider()
            let text = id.uuidString
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                completion(text.data(using: .utf8), nil); return nil
            }
            provider.registerObject(text as NSString, visibility: .all)
            let dragItem = UIDragItem(itemProvider: provider)
            dragItem.localObject = id
            return [dragItem]
        }

        // MARK: UICollectionViewDropDelegate

        func collectionView(_ cv: UICollectionView, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [UTType.plainText.identifier])
        }

        func collectionView(_ cv: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let ip = destinationIndexPath,
                  let id = dataSource?.itemIdentifier(for: ip),
                  let item = items.first(where: { $0.id == id }),
                  case .folder = item.kind else {
                DispatchQueue.main.async { self.parent.dropTargetedFolderId = nil }
                return UICollectionViewDropProposal(operation: .forbidden)
            }
            DispatchQueue.main.async { self.parent.dropTargetedFolderId = id }
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        }

        func collectionView(_ cv: UICollectionView, dropSessionDidEnd session: UIDropSession) {
            DispatchQueue.main.async { self.parent.dropTargetedFolderId = nil }
        }

        func collectionView(_ cv: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let ip = coordinator.destinationIndexPath,
                  let folderId = dataSource?.itemIdentifier(for: ip),
                  let folderItem = items.first(where: { $0.id == folderId }),
                  case .folder = folderItem.kind else { return }
            coordinator.session.loadObjects(ofClass: NSString.self) { [weak self] objects in
                guard let self,
                      let str = objects.first as? String,
                      let id = UUID(uuidString: str) else { return }
                DispatchQueue.main.async {
                    self.parent.dropTargetedFolderId = nil
                    let dm = self.parent.documentManager
                    if dm.documents.contains(where: { $0.id == id }) {
                        dm.moveDocument(documentId: id, toFolder: folderId)
                    } else if dm.folders.contains(where: { $0.id == id }), id != folderId {
                        dm.moveFolder(folderId: id, toParent: folderId)
                    }
                }
            }
        }
    }
}
