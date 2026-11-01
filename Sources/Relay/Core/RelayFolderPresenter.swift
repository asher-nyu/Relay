import Foundation

/// Watches the default documents folder for files added by Finder or iCloud.
/// Existing documents have their own presenters; this observer only proposes
/// new candidates for coordinated validation by the library actor.
final class RelayFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onCandidate: @Sendable (URL?) -> Void

    init(directory: URL, onCandidate: @escaping @Sendable (URL?) -> Void) {
        presentedItemURL = directory
        self.onCandidate = onCandidate
        let queue = OperationQueue()
        queue.name = "com.asherbloom.Relay.folder-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedSubitemDidAppear(at url: URL) { onCandidate(url) }
    func presentedSubitemDidChange(at url: URL) { onCandidate(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onCandidate(newURL) }
    func presentedItemDidChange() { onCandidate(nil) }
}
