import Foundation

enum RelayFileEvent: Sendable {
    case changed
    case moved(URL)
    case removed
}

/// Finder can move or rename a document while transcription is active. Keep
/// the presented URL current before notifying the library actor, so a queued
/// autosave follows the actual file instead of recreating its previous path.
final class RelayDocumentPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var location: URL
    private let onEvent: @Sendable (RelayFileEvent) -> Void
    let presentedItemOperationQueue: OperationQueue

    init(url: URL, onEvent: @escaping @Sendable (RelayFileEvent) -> Void) {
        location = url
        self.onEvent = onEvent
        let queue = OperationQueue()
        queue.name = "com.asherbloom.Relay.document-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    var presentedItemURL: URL? { lock.withLock { location } }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { location = newURL }
        onEvent(.moved(newURL))
    }

    func presentedItemDidChange() { onEvent(.changed) }

    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        // Atomic replacement also requests deletion accommodation. Inspect the
        // coordinated file after the operation instead of treating that request
        // as proof that the user's document was deleted.
        onEvent(.changed)
        completionHandler(nil)
    }
}
