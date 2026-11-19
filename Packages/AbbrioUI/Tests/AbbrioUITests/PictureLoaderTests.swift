import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AbbrioUI

/// A PNG of one colour, for tests that need a real picture.
func makePNG(width: Int, height: Int, red: CGFloat = 0.2) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: red, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

final class PictureLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PictureLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func failure(_ result: Result<CGImage, PictureProblem>) -> PictureProblem? {
        if case .failure(let problem) = result { return problem }
        return nil
    }

    func testAPNGGivesAThumbnailNoLargerThan256Pixels() async throws {
        let url = folder.appendingPathComponent("wide.png")
        try makePNG(width: 1200, height: 600).write(to: url)
        let thumbnail = try await PictureLoader.thumbnail(for: url).get()
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 256)
        XCTAssertEqual(thumbnail.height, 128)

        // A small picture is not enlarged.
        let small = folder.appendingPathComponent("small.png")
        try makePNG(width: 40, height: 30).write(to: small)
        let smallThumbnail = try await PictureLoader.thumbnail(for: small).get()
        XCTAssertLessThanOrEqual(max(smallThumbnail.width, smallThumbnail.height), 256)

        // The checked bytes are the file's.
        let checked = try await PictureLoader.check(url)
        XCTAssertEqual(checked.contents, try Data(contentsOf: url))
    }

    func testAChangedFileIsReadAgain() async throws {
        let url = folder.appendingPathComponent("changing.png")
        try makePNG(width: 300, height: 300).write(to: url)
        let first = try await PictureLoader.thumbnail(for: url).get()
        XCTAssertEqual(first.width, 256)
        try makePNG(width: 100, height: 50).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let second = try await PictureLoader.thumbnail(for: url).get()
        XCTAssertEqual(second.width, 100)
    }

    func testAPipeIsRefusedWithoutBlocking() async throws {
        let url = folder.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        // Nothing ever writes to the pipe, so opening it for reading would wait forever.
        let started = Date()
        let result = await PictureLoader.thumbnail(for: url)
        XCTAssertEqual(failure(result), .notRegularFile)
        do {
            _ = try await PictureLoader.check(url)
            XCTFail("A pipe was accepted")
        } catch {
            XCTAssertEqual(error, .notRegularFile)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAFolderAndADeviceAreRefused() async throws {
        let device = await PictureLoader.thumbnail(for: URL(fileURLWithPath: "/dev/zero"))
        XCTAssertEqual(failure(device), .notRegularFile)
        let directory = await PictureLoader.thumbnail(for: folder)
        XCTAssertEqual(failure(directory), .notRegularFile)
        let missing = await PictureLoader.thumbnail(for: folder.appendingPathComponent("nothing.png"))
        XCTAssertEqual(failure(missing), .missing)
    }

    func testAFileOverTheSizeCapIsRefused() async throws {
        let url = folder.appendingPathComponent("huge.png")
        var contents = try makePNG(width: 10, height: 10)
        contents.append(Data(count: PictureLoader.maximumFileSize + 1 - contents.count))
        try contents.write(to: url)
        let result = await PictureLoader.thumbnail(for: url)
        XCTAssertEqual(failure(result), .tooLarge)

        // A file at the cap is read.
        let atCap = folder.appendingPathComponent("at-cap.png")
        contents.removeLast()
        try contents.write(to: atCap)
        let accepted = await PictureLoader.thumbnail(for: atCap)
        XCTAssertNil(failure(accepted))
    }

    func testAFileThatIsNotAPictureIsRefused() async throws {
        let url = folder.appendingPathComponent("notes.png")
        try Data("These are notes, not a picture.\n".utf8).write(to: url)
        let result = await PictureLoader.thumbnail(for: url)
        XCTAssertEqual(failure(result), .notPicture)
        let empty = folder.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        let emptyResult = await PictureLoader.thumbnail(for: empty)
        XCTAssertEqual(failure(emptyResult), .notPicture)
    }

    func testAPictureWithTooManyPixelsIsRefusedFromItsHeader() async throws {
        // 6500 × 6500 is 42.25 million pixels; one grey compresses to a small file.
        let side = 6500
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertLessThan(data.length, PictureLoader.maximumFileSize)

        let url = folder.appendingPathComponent("large.png")
        try (data as Data).write(to: url)
        let result = await PictureLoader.thumbnail(for: url)
        XCTAssertEqual(failure(result), .tooManyPixels)
    }

    func testSVGAndPDFAreRead() async throws {
        let svg = folder.appendingPathComponent("shape.svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="red"/></svg>
        """.utf8).write(to: svg)
        let svgThumbnail = try await PictureLoader.thumbnail(for: svg).get()
        XCTAssertEqual(svgThumbnail.width, 256)
        XCTAssertEqual(svgThumbnail.height, 128)

        let pdf = folder.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 150)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        let pdfThumbnail = try await PictureLoader.thumbnail(for: pdf).get()
        XCTAssertLessThanOrEqual(max(pdfThumbnail.width, pdfThumbnail.height), 256)
    }
}
