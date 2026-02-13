import Foundation
import GRDB

final class DatabaseContainer {
    static let shared = DatabaseContainer()

    let db: AppDatabase
    let writer: DatabaseWriter

    private init() {
        do {
            let fileManager = FileManager.default
            let folderURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            let dbURL = folderURL.appendingPathComponent("wakelight.sqlite")
            let writer = try DatabaseQueue(path: dbURL.path)
            self.writer = writer
            self.db = try AppDatabase(writer)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
}
