import Foundation

struct RelayStorageLocation: Sendable {
    let directory: URL
    let usesICloud: Bool

    var description: String { usesICloud ? "iCloud Drive" : "On My Mac" }

    static var localDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
    }

    static var bookmarksURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
            .appendingPathComponent("Recent Documents.json")
    }

    /// Ubiquity lookup may block while the file provider initializes. Perform it
    /// away from the main actor, then create the app's visible Documents folder.
    static func resolve() async throws -> RelayStorageLocation {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let cloud = manager.url(forUbiquityContainerIdentifier: "iCloud.com.asherbloom.Relay")
            let directory = cloud?.appendingPathComponent("Documents", isDirectory: true) ?? localDirectory
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            return RelayStorageLocation(directory: directory, usesICloud: cloud != nil)
        }.value
    }
}
