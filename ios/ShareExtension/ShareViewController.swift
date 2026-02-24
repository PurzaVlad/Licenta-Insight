import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.com.purzavlad.identity"
    private let sharedInboxFolderName = "ShareInbox"
    private var didStartProcessing = false

    private let activityIndicator: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = false
        return spinner
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.text = "Saving to Insight..."
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(activityIndicator)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -18),
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        activityIndicator.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartProcessing else { return }
        didStartProcessing = true
        processIncomingItems()
    }

    private func processIncomingItems() {
        guard let inboxURL = sharedInboxURL(createIfMissing: true) else {
            complete(withStatus: "Unable to access shared storage.", delay: 0.7)
            return
        }

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete(withStatus: "Nothing to save.", delay: 0.35)
            return
        }

        let providers = extensionItems
            .compactMap { $0.attachments }
            .flatMap { $0 }

        guard !providers.isEmpty else {
            complete(withStatus: "Nothing to save.", delay: 0.35)
            return
        }

        let dispatchGroup = DispatchGroup()
        let lock = NSLock()
        var savedCount = 0

        for provider in providers {
            dispatchGroup.enter()
            persistProvider(provider, to: inboxURL) { didSave in
                if didSave {
                    lock.lock()
                    savedCount += 1
                    lock.unlock()
                }
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            if savedCount > 0 {
                self.complete(withStatus: "Saved \(savedCount) item(s) to Insight.", delay: 0.35)
            } else {
                self.complete(withStatus: "No supported item found.", delay: 0.7)
            }
        }
    }

    private func persistProvider(_ provider: NSItemProvider, to inboxURL: URL, completion: @escaping (Bool) -> Void) {
        let preferredTypeIdentifiers = resolveCandidateTypeIdentifiers(for: provider)
        guard !preferredTypeIdentifiers.isEmpty else {
            completion(false)
            return
        }
        loadAndPersist(
            provider: provider,
            candidateTypeIdentifiers: preferredTypeIdentifiers,
            index: 0,
            inboxURL: inboxURL,
            completion: completion
        )
    }

    private func resolveCandidateTypeIdentifiers(for provider: NSItemProvider) -> [String] {
        var ordered: [String] = [
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.image.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier,
            UTType.data.identifier
        ]

        for identifier in provider.registeredTypeIdentifiers where !ordered.contains(identifier) {
            ordered.append(identifier)
        }

        return ordered.filter { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private func loadAndPersist(
        provider: NSItemProvider,
        candidateTypeIdentifiers: [String],
        index: Int,
        inboxURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < candidateTypeIdentifiers.count else {
            completion(false)
            return
        }

        let typeIdentifier = candidateTypeIdentifiers[index]
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            if let item, self.persistItem(
                item,
                typeIdentifier: typeIdentifier,
                suggestedName: provider.suggestedName,
                inboxURL: inboxURL
            ) {
                completion(true)
                return
            }

            self.loadAndPersist(
                provider: provider,
                candidateTypeIdentifiers: candidateTypeIdentifiers,
                index: index + 1,
                inboxURL: inboxURL,
                completion: completion
            )
        }
    }

    private func persistItem(
        _ item: NSSecureCoding,
        typeIdentifier: String,
        suggestedName: String?,
        inboxURL: URL
    ) -> Bool {
        if let url = item as? URL {
            if url.isFileURL {
                return copyFileToInbox(url, preferredName: suggestedName ?? url.lastPathComponent, inboxURL: inboxURL)
            }
            return writeData(
                Data(url.absoluteString.utf8),
                preferredName: suggestedName ?? "Shared Link.url",
                fallbackExtension: "url",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let nsurl = item as? NSURL {
            let url = nsurl as URL
            if url.isFileURL {
                return copyFileToInbox(url, preferredName: suggestedName ?? url.lastPathComponent, inboxURL: inboxURL)
            }
            return writeData(
                Data(url.absoluteString.utf8),
                preferredName: suggestedName ?? "Shared Link.url",
                fallbackExtension: "url",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
            return writeData(
                data,
                preferredName: suggestedName ?? "Shared Image.jpg",
                fallbackExtension: "jpg",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let data = item as? Data {
            return writeData(
                data,
                preferredName: suggestedName ?? "Shared File",
                fallbackExtension: "dat",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let data = item as? NSData {
            return writeData(
                data as Data,
                preferredName: suggestedName ?? "Shared File",
                fallbackExtension: "dat",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let attributed = item as? NSAttributedString {
            return writeData(
                Data(attributed.string.utf8),
                preferredName: suggestedName ?? "Shared Text.txt",
                fallbackExtension: "txt",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let text = item as? String {
            return writeData(
                Data(text.utf8),
                preferredName: suggestedName ?? "Shared Text.txt",
                fallbackExtension: "txt",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        if let text = item as? NSString {
            return writeData(
                Data((text as String).utf8),
                preferredName: suggestedName ?? "Shared Text.txt",
                fallbackExtension: "txt",
                typeIdentifier: typeIdentifier,
                inboxURL: inboxURL
            )
        }

        return false
    }

    private func copyFileToInbox(_ sourceURL: URL, preferredName: String, inboxURL: URL) -> Bool {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL = uniqueDestinationURL(
            for: preferredName.isEmpty ? sourceURL.lastPathComponent : preferredName,
            inboxURL: inboxURL
        )

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            guard let data = try? Data(contentsOf: sourceURL) else { return false }
            do {
                try data.write(to: destinationURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    private func writeData(
        _ data: Data,
        preferredName: String,
        fallbackExtension: String,
        typeIdentifier: String,
        inboxURL: URL
    ) -> Bool {
        var finalName = preferredName
        let parsed = URL(fileURLWithPath: preferredName)
        let baseName = parsed.deletingPathExtension().lastPathComponent
        let existingExtension = parsed.pathExtension

        if existingExtension.isEmpty {
            let inferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? fallbackExtension
            let safeBase = baseName.isEmpty ? "Shared Item" : baseName
            finalName = "\(safeBase).\(inferredExtension)"
        }

        let destinationURL = uniqueDestinationURL(for: finalName, inboxURL: inboxURL)
        do {
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func uniqueDestinationURL(for preferredName: String, inboxURL: URL) -> URL {
        let safeName = sanitizeFileName(preferredName)
        let parsed = URL(fileURLWithPath: safeName)
        let base = parsed.deletingPathExtension().lastPathComponent
        let ext = parsed.pathExtension
        let finalBase = base.isEmpty ? "Shared Item" : base

        var index = 0
        let fm = FileManager.default
        while true {
            let suffix = index == 0 ? "" : " \(index)"
            let candidateName = ext.isEmpty
                ? "\(finalBase)\(suffix)"
                : "\(finalBase)\(suffix).\(ext)"
            let candidateURL = inboxURL.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = value.components(separatedBy: invalid)
        let merged = parts.joined(separator: "-")
        let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared Item" : trimmed
    }

    private func sharedInboxURL(createIfMissing: Bool) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        let inbox = container.appendingPathComponent(sharedInboxFolderName, isDirectory: true)
        if createIfMissing && !FileManager.default.fileExists(atPath: inbox.path) {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }

    private func complete(withStatus message: String, delay: TimeInterval) {
        DispatchQueue.main.async {
            self.statusLabel.text = message
            self.activityIndicator.stopAnimating()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
