import Foundation

struct WebDAVError: Error, LocalizedError {
    enum Reason {
        case invalidAddress
        case unauthorized
        case notFound
        case status(Int)
        case notWebDAV
    }

    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .invalidAddress: String(localized: "The address is not a valid URL.")
        case .unauthorized: String(localized: "Wrong username or password.")
        case .notFound: String(localized: "The folder could not be opened.")
        case .status(let code): String(localized: "The server answered with error \(code).")
        case .notWebDAV: String(localized: "The server did not answer as a WebDAV server.")
        }
    }
}

/// One entry of a WebDAV collection.
struct WebDAVEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?
}

/// Lists WebDAV collections and addresses their files for playback.
///
/// Authentication is HTTP Basic, sent up front: it is what NAS and cloud WebDAV servers
/// accept, and the same header can be handed to mpv, which plays the files itself.
struct WebDAVClient: Sendable {
    /// The server's base URL, without a trailing slash.
    let baseURL: String
    let username: String
    let password: String

    /// The login of a saved WebDAV server; nil if it is gone or of another kind.
    init?(serverID: UUID) {
        guard let (server, password) = ServerStore.login(for: serverID), server.kind == .webDAV else { return nil }
        self.init(baseURL: server.address, username: server.username, password: password)
    }

    init(baseURL: String, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// The `Authorization` header, or nil for anonymous access.
    var authorization: String? {
        guard !username.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// The real URL of the item at `path` (components below the base URL).
    func url(for path: [String], isDirectory: Bool = false) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        var text = ([baseURL] + encoded).joined(separator: "/")
        if isDirectory {
            text += "/"
        }
        return URL(string: text)
    }

    func contents(of path: [String]) async throws -> [WebDAVEntry] {
        guard let url = url(for: path, isDirectory: true) else { throw WebDAVError(reason: .invalidAddress) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop>
        <D:resourcetype/><D:getcontentlength/><D:getlastmodified/>
        </D:prop></D:propfind>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 207: break
        case 401, 403: throw WebDAVError(reason: .unauthorized)
        case 404: throw WebDAVError(reason: .notFound)
        case 200..<300: throw WebDAVError(reason: .notWebDAV)
        default: throw WebDAVError(reason: .status(status))
        }
        // The collection lists itself first; it is recognized by its path.
        let ownPath = Self.normalized(url.path(percentEncoded: false))
        return WebDAVListing.parse(data).filter { Self.normalized($0.path) != ownPath }.map(\.entry)
    }

    /// The whole of a small file. The range keeps a mistaken request from fetching more
    /// than `limit`; a server that ignores it is refused by the size of its answer.
    func data(of path: [String], limit: Int) async throws -> Data {
        guard let url = url(for: path) else { throw WebDAVError(reason: .invalidAddress) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-\(limit)", forHTTPHeaderField: "Range")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), data.count <= limit else {
            throw WebDAVError(reason: status == 401 || status == 403 ? .unauthorized : .status(status))
        }
        return data
    }

    /// Downloads the file at `path` to `destination`, reporting bytes written so far.
    func download(_ path: [String], to destination: URL, progress: @Sendable (Int64) -> Void) async throws {
        guard let url = url(for: path) else { throw WebDAVError(reason: .invalidAddress) }
        var request = URLRequest(url: url)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw WebDAVError(reason: status == 401 || status == 403 ? .unauthorized : .status(status))
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        // The sequence yields single bytes; they are gathered into megabyte writes.
        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try output.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(written)
            }
        }
        try output.write(contentsOf: buffer)
        progress(written + Int64(buffer.count))
    }

    private static func normalized(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Parses a PROPFIND multistatus response.
final class WebDAVListing: NSObject, XMLParserDelegate {
    struct Item {
        /// The decoded path of the resource on the server.
        let path: String
        let entry: WebDAVEntry
    }

    private var items: [Item] = []
    private var text = ""
    private var href = ""
    private var isDirectory = false
    private var size: Int?
    private var modified: Date?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parse(_ data: Data) -> [Item] {
        let listing = WebDAVListing()
        let parser = XMLParser(data: data)
        // Servers pick their own prefix for the DAV: namespace; local names are what matter.
        parser.shouldProcessNamespaces = true
        parser.delegate = listing
        parser.parse()
        return listing.items
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        text = ""
        switch name {
        case "response":
            href = ""
            isDirectory = false
            size = nil
            modified = nil
        case "collection":
            isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            href = value
        case "getcontentlength":
            size = Int(value)
        case "getlastmodified":
            modified = Self.dateFormatter.date(from: value)
        case "response":
            // The href is a path or a full URL, percent-encoded either way.
            let encodedPath = URL(string: href)?.path(percentEncoded: true) ?? href
            let path = encodedPath.removingPercentEncoding ?? encodedPath
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
            guard !name.isEmpty, !name.hasPrefix(".") else { return }
            items.append(Item(
                path: path,
                entry: WebDAVEntry(name: name, isDirectory: isDirectory, size: isDirectory ? nil : size, modified: modified)
            ))
        default:
            break
        }
    }
}
