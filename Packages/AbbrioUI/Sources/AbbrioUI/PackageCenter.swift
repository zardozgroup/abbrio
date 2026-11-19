import CryptoKit
public import ConfigStore
public import Foundation
public import Observation
public import SnippetModel

/// How the app reaches the Hub. Tests replace it so nothing goes over the network.
public nonisolated struct HubService: Sendable {
    /// Downloads a file. Throws when the server does not answer with the file.
    public var fetch: @Sendable (URL) async throws -> Data
    /// Where the catalog is kept between launches. Nil keeps nothing.
    public var cacheFolder: URL?
    public var now: @Sendable () -> Date

    public init(
        fetch: @escaping @Sendable (URL) async throws -> Data, cacheFolder: URL?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.cacheFolder = cacheFolder
        self.now = now
    }

    public static let indexURL = URL(string: "https://github.com/espanso/hub/releases/latest/download/package_index.json")!
    /// The most a download may hold. Package archives and the index are far smaller.
    static let downloadLimit = 32 * 1024 * 1024
    /// How long a cached catalog is used before the app asks for a new one.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    public static var live: HubService {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let folder = caches?.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Abbrio", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        return HubService(fetch: download, cacheFolder: folder)
    }

    /// The hosts the app downloads from: the Hub's releases and the files GitHub serves them from.
    static let allowedHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "raw.githubusercontent.com",
    ]

    /// True when the app may fetch from an address: https, on one of the allowed hosts.
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased()
        else { return false }
        return allowedHosts.contains(host)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func download(_ url: URL) async throws -> Data {
        guard isAllowed(url) else { throw HubError.message("Abbrio fetches only from GitHub over https.") }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw HubError.message("The server gave no answer.") }
        if (300..<400).contains(http.statusCode) {
            throw HubError.message("The download was sent on to an address Abbrio doesn't fetch from.")
        }
        guard http.statusCode == 200 else {
            throw HubError.message("The server answered with status \(http.statusCode).")
        }
        guard isAllowed(http.url) else { throw HubError.message("Abbrio fetches only from GitHub over https.") }
        return try await collect(bytes, declaredLength: http.expectedContentLength, limit: downloadLimit)
    }

    /// Gathers a download, stopping as soon as it passes the limit. A declared length over the limit stops it
    /// before anything is read; a server that declares none, or too little, is stopped while sending.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes, declaredLength: Int64, limit: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard declaredLength <= Int64(limit) else { throw HubError.message("The download is too large.") }
        var data = Data()
        if declaredLength > 0 { data.reserveCapacity(Int(declaredLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw HubError.message("The download is too large.") }
            data.append(byte)
        }
        return data
    }
}

/// Follows a redirect only to an address the app may fetch from.
private nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(HubService.isAllowed(request.url) ? request : nil)
    }
}

nonisolated enum HubError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// What the detail sheet knows about a package's archive.
public nonisolated enum PackagePreview: Equatable, Sendable {
    case loading
    case loaded(PackageContents)
    case failed(String)
}

/// The Hub catalog and the state of package commands, for the Packages window.
@Observable
public final class PackageCenter {
    @ObservationIgnored let service: HubService

    public internal(set) var index = HubIndex.empty
    public internal(set) var featured = Set(FeaturedPackages.shipped)
    /// When the catalog on screen was fetched. Nil when there is none.
    public internal(set) var catalogDate: Date?
    public internal(set) var isRefreshing = false
    /// Why the last refresh failed.
    public internal(set) var catalogError: String?
    /// What is being done to a package right now, by name: "Installing…".
    public internal(set) var activity: [String: String] = [:]
    /// What Espanso printed when a command for a package failed, by name.
    public var failures: [String: String] = [:]
    /// Archive contents by `HubPackage.id`.
    public internal(set) var previews: [String: PackagePreview] = [:]

    init(service: HubService) {
        self.service = service
    }

    private var indexFile: URL? { service.cacheFolder?.appendingPathComponent("package_index.json") }
    private var featuredFile: URL? { service.cacheFolder?.appendingPathComponent("featured.json") }

    /// Shows the cached catalog, when there is one and nothing is on screen yet.
    func loadCache() {
        guard catalogDate == nil, let indexFile, let data = try? Data(contentsOf: indexFile),
              let cached = try? HubIndex(data: data)
        else { return }
        index = cached
        catalogDate = (try? indexFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let featuredFile, let data = try? Data(contentsOf: featuredFile),
           let names = try? JSONDecoder().decode([String].self, from: data), !names.isEmpty {
            featured = Set(names)
        }
    }

    var needsRefresh: Bool {
        guard let catalogDate else { return true }
        return service.now().timeIntervalSince(catalogDate) > HubService.maximumAge
    }

    /// Fetches the catalog and the featured list. A failure keeps what is on screen.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let data = try await service.fetch(HubService.indexURL)
            let fetched = try HubIndex(data: data)
            index = fetched
            catalogDate = service.now()
            catalogError = nil
            store(data, at: indexFile)
        } catch is DecodingError {
            catalogError = "The Hub's catalog has a form this version of Abbrio does not read."
            return
        } catch {
            catalogError = "The catalog could not be fetched: \(error.localizedDescription)"
            return
        }
        // The featured list is a nicety. When it can't be fetched or has changed shape, the last one stays.
        if let data = try? await service.fetch(FeaturedPackages.source),
           let names = FeaturedPackages.names(inSource: String(decoding: data, as: UTF8.self)) {
            featured = Set(names)
            if let encoded = try? JSONEncoder().encode(names) { store(encoded, at: featuredFile) }
        }
    }

    private func store(_ data: Data, at url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // The file's date is when the catalog was fetched, by the same clock that later judges its age.
        try? FileManager.default.setAttributes([.modificationDate: service.now()], ofItemAtPath: url.path)
    }

    /// Downloads a package's archive and checks it against the published checksum.
    func verifiedArchive(of package: HubPackage) async throws -> Data {
        guard let archive = URL(string: package.archiveURL), let checksum = URL(string: package.archiveChecksumURL) else {
            throw HubError.message("The catalog gives no download address for this package.")
        }
        // The addresses come from the catalog, so they are checked here whatever does the downloading.
        guard HubService.isAllowed(archive), HubService.isAllowed(checksum) else {
            throw HubError.message("The catalog points this package at an address Abbrio doesn't fetch from.")
        }
        async let archiveData = service.fetch(archive)
        async let checksumData = service.fetch(checksum)
        let (data, sum) = try await (archiveData, checksumData)
        let expected = String(decoding: sum, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        let actual = SHA256.hash(data: data).map { byte in
            (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }.joined()
        guard expected == actual else { throw HubError.message("The download does not match its checksum.") }
        return data
    }
}
