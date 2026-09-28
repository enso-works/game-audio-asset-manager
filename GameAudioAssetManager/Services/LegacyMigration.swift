import Foundation

/// Carries users over from when the app was called Audio Prepare, without moving their files.
enum LegacyMigration {
    static let oldBundleIdentifier = "com.bavrk.audioprepare"
    static let oldProjectFolder = ".audioprepare"
    static let oldLibraryFolder = "AudioPrepare"
    private static let doneKey = "migratedFromAudioPrepare"

    /// Copies old preferences once, and keeps using an existing library folder instead of moving it.
    static func migratePreferences() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        for (key, value) in defaults.persistentDomain(forName: oldBundleIdentifier) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        if defaults.string(forKey: "libraryRoot") == nil {
            let oldRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(oldLibraryFolder, isDirectory: true)
            if FileManager.default.fileExists(atPath: oldRoot.path) {
                defaults.set(oldRoot.path, forKey: "libraryRoot")
            }
        }
    }

    /// Renames a project's old hidden settings folder to the new name the first time it's opened.
    static func migrateProjectFolder(in project: URL, to newName: String) {
        let old = project.appendingPathComponent(oldProjectFolder, isDirectory: true)
        let new = project.appendingPathComponent(newName, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
