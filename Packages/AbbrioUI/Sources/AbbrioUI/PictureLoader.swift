public import Foundation
public import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Why a file can't be shown or used as a picture.
public nonisolated enum PictureProblem: Error, Equatable, Sendable {
    /// Nothing is at the path.
    case missing
    /// The path names a folder, a pipe, a device or anything else that isn't an ordinary file.
    case notRegularFile
    /// The file is larger than ``PictureLoader/maximumFileSize``.
    case tooLarge
    /// The file is there but could not be read.
    case unreadable
    /// The file is not in a picture format the system can read.
    case notPicture
    /// The picture has more than ``PictureLoader/maximumPixelCount`` pixels.
    case tooManyPixels

    /// The reason, as the end of a sentence that starts with the file's name.
    var reason: String {
        switch self {
        case .missing: return "is not there"
        case .notRegularFile: return "is not an ordinary file"
        case .tooLarge: return "is larger than 32 MB"
        case .unreadable: return "could not be read"
        case .notPicture: return "is not a picture"
        case .tooManyPixels: return "has more than 40 million pixels"
        }
    }
}

/// A picture file that passed the checks: the bytes that were checked and a small preview made from them.
nonisolated struct CheckedPicture: Sendable {
    var contents: Data
    var thumbnail: CGImage
}

/// Reads picture files for previews and before they are copied, within fixed limits.
///
/// A picture item's path can come from someone else (a package's author, a hand-written file), so the file
/// is never trusted: only an ordinary file of at most 32 MB is opened, it is read in full before any
/// decoding, and a picture of more than 40 million pixels is refused before it is decoded. The work is
/// done off the main actor, and previews are kept by path, modification date and size.
///
/// Bitmap formats and PDF are read with ImageIO. SVG is drawn with `NSImage`, because Espanso loads
/// `image_path` with `NSImage` too and so accepts SVG and PDF as well as bitmaps.
public nonisolated enum PictureLoader {
    /// The largest file that is opened.
    public static let maximumFileSize = 32 * 1024 * 1024
    /// The most pixels a picture may have.
    public static let maximumPixelCount = 40_000_000
    /// The longest side of a preview, in pixels.
    public static let thumbnailPixelSize = 256

    /// How many previews are kept.
    private static let cacheLimit = 64

    /// What identifies one version of a file.
    private struct Stamp: Hashable {
        var path: String
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int

        init(path: String, _ info: stat) {
            self.path = path
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Stamp: Result<CGImage, PictureProblem>]())

    /// A preview of the picture at `url`, at most ``thumbnailPixelSize`` pixels on its longest side.
    @concurrent
    public static func thumbnail(for url: URL) async -> Result<CGImage, PictureProblem> {
        let path = url.path
        var info = stat()
        if stat(path, &info) == 0 {
            let current = Stamp(path: path, info)
            if let cached = cache.withLock({ $0[current] }) { return cached }
        }
        let result: Result<CGImage, PictureProblem>
        var stamp: Stamp?
        do {
            let (contents, opened) = try readContents(of: url)
            stamp = opened
            result = .success(try makeThumbnail(from: contents, fileExtension: url.pathExtension))
        } catch {
            result = .failure(error)
        }
        // Only what was found in an opened file is kept; the other answers cost a single stat.
        if let stamp {
            cache.withLock { entries in
                if entries.count >= cacheLimit { entries.removeAll() }
                entries[stamp] = result
            }
        }
        return result
    }

    /// Checks the picture at `url` and returns the bytes that passed, so what is copied is what was checked.
    @concurrent
    static func check(_ url: URL) async throws(PictureProblem) -> CheckedPicture {
        try load(url)
    }

    /// Reads and checks the picture at `url`. Blocks for as long as reading at most 32 MB takes.
    static func load(_ url: URL) throws(PictureProblem) -> CheckedPicture {
        let (contents, _) = try readContents(of: url)
        let thumbnail = try makeThumbnail(from: contents, fileExtension: url.pathExtension)
        return CheckedPicture(contents: contents, thumbnail: thumbnail)
    }

    // MARK: Reading

    /// The bytes of an ordinary file of at most ``maximumFileSize`` bytes, read with the same care as a
    /// picture.
    static func contents(of url: URL) throws(PictureProblem) -> Data {
        try readContents(of: url).0
    }

    /// Reads an ordinary file of at most ``maximumFileSize`` bytes.
    ///
    /// The path is looked at before it is opened, so a pipe or a device is never opened, and the open file
    /// is looked at again, so one swapped in between is refused too. The open doesn't wait for a writer.
    private static func readContents(of url: URL) throws(PictureProblem) -> (Data, Stamp) {
        let path = url.path
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        try checkKindAndSize(info)

        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else {
            throw errno == ENOENT ? .missing : .unreadable
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw .unreadable }
        try checkKindAndSize(opened)

        // One byte more than allowed, to notice a file that grew after it was looked at.
        let limit = maximumFileSize + 1
        var contents = Data()
        contents.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while contents.count < limit {
            let wanted = min(buffer.count, limit - contents.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable
            }
            contents.append(contentsOf: buffer[..<count])
        }
        guard contents.count <= maximumFileSize else { throw .tooLarge }
        return (contents, Stamp(path: path, opened))
    }

    private static func checkKindAndSize(_ info: stat) throws(PictureProblem) {
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile }
        guard info.st_size <= Int64(maximumFileSize) else { throw .tooLarge }
    }

    // MARK: Decoding

    private static func makeThumbnail(from contents: Data, fileExtension: String) throws(PictureProblem) -> CGImage {
        if let source = CGImageSourceCreateWithData(contents as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 {
            try checkPixelCount(pixelSize(of: source, type: type as String, contents: contents))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw .notPicture
            }
            return thumbnail
        }
        if UTType(filenameExtension: fileExtension)?.conforms(to: .svg) == true {
            return try svgThumbnail(from: contents)
        }
        throw .notPicture
    }

    /// The picture's size in pixels, from its header. A PDF has none, so its first page's size in points
    /// is used, which is the size Espanso pastes it at.
    private static func pixelSize(of source: CGImageSource, type: String, contents: Data) throws(PictureProblem) -> CGSize {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            return CGSize(width: width, height: height)
        }
        if UTType(type)?.conforms(to: .pdf) == true,
           let provider = CGDataProvider(data: contents as CFData),
           let page = CGPDFDocument(provider)?.page(at: 1) {
            return page.getBoxRect(.mediaBox).size
        }
        throw .notPicture
    }

    private static func checkPixelCount(_ size: CGSize) throws(PictureProblem) {
        let width = abs(size.width), height = abs(size.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { throw .notPicture }
        guard width * height <= Double(maximumPixelCount) else { throw .tooManyPixels }
    }

    /// Draws an SVG into a bitmap no larger than a preview.
    private static func svgThumbnail(from contents: Data) throws(PictureProblem) -> CGImage {
        guard let image = NSImage(data: contents), image.isValid else { throw .notPicture }
        let size = image.size
        try checkPixelCount(size)
        let scale = min(1, Double(thumbnailPixelSize) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw .notPicture }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let thumbnail = bitmap.makeImage() else { throw .notPicture }
        return thumbnail
    }
}
