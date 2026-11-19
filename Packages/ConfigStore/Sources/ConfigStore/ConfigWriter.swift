public import Foundation

/// Writes files in a config folder safely: a backup first, then a temporary file renamed into place.
///
/// Espanso reloads for any path in the folder that ends in `.yml` or `.yaml` or has no extension, so backups
/// end in `.bak`, temporary files in `.tmp`, and the backup folder is created only once.
///
/// Paths are relative to the config folder and may not leave it. A file that is a symbolic link is written
/// through: the file it points at gets the new contents and the link stays, so a set kept in a synced folder
/// and linked into the config folder keeps working.
public struct ConfigWriter: Sendable {
    public var root: URL
    /// How many earlier versions of each file are kept.
    public var backupLimit = 20

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var backupDirectory: URL {
        root.appendingPathComponent(".abbrio/backups", isDirectory: true)
    }

    public func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// True when `path` names something inside the config folder: relative, and with no `..` or empty part.
    public static func isConfined(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != ".." && part != "."
        }
    }

    public func read(_ path: String) throws(EditError) -> Data {
        guard Self.isConfined(path) else { throw .fileSystem("\(path) is outside the config folder.") }
        let target = url(for: path)
        // Reading a pipe or a device would never finish, so only regular files are read.
        if case .some(let kind) = Self.kind(at: target.resolvingSymlinksInPath()), kind != .typeRegular {
            throw .fileSystem("\(path) is not a regular file.")
        }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw .fileSystem("\(path) could not be read: \(error.localizedDescription)")
        }
    }

    /// Writes `data` to the file at `path`, relative to the config folder.
    ///
    /// - Parameter expected: The bytes the change was based on. The write is refused with `changedOnDisk`
    ///   when the file holds something else by now. Pass nil for a file that must not exist yet.
    public func write(_ data: Data, to path: String, replacing expected: Data?) throws(EditError) {
        guard Self.isConfined(path) else { throw .fileSystem("\(path) is outside the config folder.") }
        let manager = FileManager.default
        let target = try destination(of: path)
        let exists = manager.fileExists(atPath: target.path)

        if let expected {
            guard exists, (try? Data(contentsOf: target)) == expected else { throw .changedOnDisk }
            guard data != expected else { return }
            try backUp(expected, of: path)
        } else if exists || Self.kind(at: url(for: path)) != nil {
            throw .alreadyExists(url(for: path).lastPathComponent)
        }

        // Next to the target so the rename stays on one volume. The name is new each time and the file is
        // created exclusively, so nothing already there can be written through.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        do {
            var permissions: mode_t = 0o644
            if exists, let mode = try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber {
                permissions = mode_t(mode.uint16Value)
            }
            try Self.createExclusively(temporary, with: data, permissions: permissions)
            guard rename(temporary.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw .fileSystem("\(path) could not be saved: \(error.localizedDescription)")
        }
    }

    /// The file a write to `path` changes: the path itself, or what it links to. A link that leads nowhere
    /// or to something other than a regular file is refused.
    private func destination(of path: String) throws(EditError) -> URL {
        let target = url(for: path)
        guard Self.kind(at: target) == .typeSymbolicLink else {
            if let kind = Self.kind(at: target), kind != .typeRegular {
                throw .fileSystem("\(path) is not a regular file.")
            }
            return target
        }
        let resolved = target.resolvingSymlinksInPath()
        guard let kind = Self.kind(at: resolved) else {
            throw .fileSystem("\(path) is a link to a file that is not there.")
        }
        guard kind == .typeRegular else {
            throw .fileSystem("\(path) is a link to something that is not a regular file.")
        }
        return resolved
    }

    /// The kind of item at a URL, without following a link there. Nil when nothing is there.
    static func kind(at url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return nil }
        return type
    }

    /// Creates a file that must not exist yet, not even as a link, and fills it.
    public static func createExclusively(_ url: URL, with data: Data, permissions: mode_t = 0o644) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(url.path)
            throw error
        }
        // The process umask may have narrowed the mode given to open.
        chmod(url.path, permissions)
    }

    // MARK: Backups

    /// The name backups of a file start with: its path with the slashes replaced.
    func backupStem(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "__")
    }

    /// Backup files of `path`, oldest first, with their numbers.
    public func backups(of path: String) -> [(number: Int, url: URL)] {
        let prefix = backupStem(for: path) + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        return names.compactMap { name -> (number: Int, url: URL)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".bak"),
                  let number = Int(name.dropFirst(prefix.count).dropLast(".bak".count))
            else { return nil }
            return (number, backupDirectory.appendingPathComponent(name))
        }
        .sorted { $0.number < $1.number }
    }

    private func backUp(_ data: Data, of path: String) throws(EditError) {
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: backupDirectory.path) {
                try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            }
            let existing = backups(of: path)
            let number = (existing.last?.number ?? 0) + 1
            let name = "\(backupStem(for: path)).\(number).bak"
            try Self.createExclusively(backupDirectory.appendingPathComponent(name), with: data)
            for old in existing.dropLast(max(backupLimit - 1, 0)) {
                try? manager.removeItem(at: old.url)
            }
        } catch {
            throw .fileSystem("A backup of \(path) could not be made, so nothing was saved: \(error.localizedDescription)")
        }
    }
}
