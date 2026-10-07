import Foundation

/// One cookie from a Safari `Cookies.binarycookies` file. Tests may inspect
/// `name` / `domain`. Do not log `value`.
struct SafariCookie: Equatable, Sendable {
    var domain: String
    var name: String
    var path: String
    var value: String
    var expiry: Date
}

enum SafariBinaryCookies {
    /// Classic `cook` layout: magic + big-endian pageCount + N big-endian
    /// page *sizes*. Pages are concatenated after the `8 + 4*N` header.
    /// Treating those ints as file offsets yields 0 cookies on Grok.app's file.
    static func parse(_ data: Data) -> [SafariCookie] {
        guard data.count >= 8, data.starts(with: Data("cook".utf8)) else { return [] }
        let pageCount = int32BE(data, 4)
        guard pageCount > 0, pageCount < 4096 else { return [] }
        let headerSize = 8 + pageCount * 4
        guard headerSize <= data.count else { return [] }
        var cookies: [SafariCookie] = []
        var pageStart = headerSize
        for index in 0..<pageCount {
            let sizePos = 8 + index * 4
            let pageSize = int32BE(data, sizePos)
            guard pageSize > 0, pageStart <= data.count - pageSize else { break }
            let page = data.subdata(in: pageStart..<(pageStart + pageSize))
            cookies.append(contentsOf: parsePage(page, start: 0))
            pageStart += pageSize
        }
        return cookies
    }

    /// Builds a synthetic Safari cookie file for tests. Not used at runtime.
    /// Header ints are page sizes so `parse` can walk the same layout Grok.app writes.
    static func encode(_ cookies: [SafariCookie]) -> Data {
        encode(pages: [cookies])
    }

    /// One page per array. Header ints are each page's byte size, not file offsets.
    static func encode(pages: [[SafariCookie]]) -> Data {
        let blobs = pages.map(encodePage)
        var file = Data("cook".utf8)
        file.append(contentsOf: uint32BE(UInt32(blobs.count)))
        for blob in blobs {
            file.append(contentsOf: uint32BE(UInt32(blob.count)))
        }
        for blob in blobs {
            file.append(blob)
        }
        return file
    }

    private static func encodePage(_ cookies: [SafariCookie]) -> Data {
        var blobs: [Data] = []
        for cookie in cookies {
            blobs.append(encodeCookie(cookie))
        }
        var page = Data()
        page.append(contentsOf: uint32BE(0x0000_0100))
        page.append(contentsOf: uint32LE(UInt32(blobs.count)))
        let headerBytes = 8 + blobs.count * 4 + 4
        var cursor = headerBytes
        for blob in blobs {
            page.append(contentsOf: uint32LE(UInt32(cursor)))
            cursor += blob.count
        }
        page.append(contentsOf: uint32LE(0))
        for blob in blobs {
            page.append(blob)
        }
        return page
    }

    private static func parsePage(_ data: Data, start: Int) -> [SafariCookie] {
        guard start + 8 <= data.count, int32BE(data, start) == 0x0000_0100 else { return [] }
        let count = int32LE(data, start + 4)
        guard count > 0, count < 4096 else { return [] }
        var cookies: [SafariCookie] = []
        for index in 0..<count {
            let offsetPos = start + 8 + index * 4
            guard offsetPos + 4 <= data.count else { break }
            let cookieStart = start + int32LE(data, offsetPos)
            if let cookie = parseCookie(data, start: cookieStart) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    private static func parseCookie(_ data: Data, start: Int) -> SafariCookie? {
        guard start + 56 <= data.count else { return nil }
        let size = int32LE(data, start)
        guard size >= 56, start + size <= data.count else { return nil }
        let record = data.subdata(in: start..<(start + size))
        let domainOffset = int32LE(record, 16)
        let nameOffset = int32LE(record, 20)
        let pathOffset = int32LE(record, 24)
        let valueOffset = int32LE(record, 28)
        let expiry = Date(timeIntervalSinceReferenceDate: doubleLE(record, 40))
        guard let domain = cString(record, at: domainOffset),
              let name = cString(record, at: nameOffset),
              let path = cString(record, at: pathOffset),
              let value = cString(record, at: valueOffset),
              !name.isEmpty
        else { return nil }
        return SafariCookie(domain: domain, name: name, path: path, value: value, expiry: expiry)
    }

    private static func encodeCookie(_ cookie: SafariCookie) -> Data {
        let domain = Array(cookie.domain.utf8) + [0]
        let name = Array(cookie.name.utf8) + [0]
        let path = Array(cookie.path.utf8) + [0]
        let value = Array(cookie.value.utf8) + [0]
        let header = 56
        let domainOffset = header
        let nameOffset = domainOffset + domain.count
        let pathOffset = nameOffset + name.count
        let valueOffset = pathOffset + path.count
        let size = valueOffset + value.count
        var blob = Data()
        blob.append(contentsOf: uint32LE(UInt32(size)))
        blob.append(contentsOf: uint32LE(0))
        blob.append(contentsOf: uint32LE(0))
        blob.append(contentsOf: uint32LE(0))
        blob.append(contentsOf: uint32LE(UInt32(domainOffset)))
        blob.append(contentsOf: uint32LE(UInt32(nameOffset)))
        blob.append(contentsOf: uint32LE(UInt32(pathOffset)))
        blob.append(contentsOf: uint32LE(UInt32(valueOffset)))
        blob.append(contentsOf: [UInt8](repeating: 0, count: 8))
        blob.append(contentsOf: doubleLE(cookie.expiry.timeIntervalSinceReferenceDate))
        blob.append(contentsOf: doubleLE(Date.now.timeIntervalSinceReferenceDate))
        blob.append(contentsOf: domain)
        blob.append(contentsOf: name)
        blob.append(contentsOf: path)
        blob.append(contentsOf: value)
        return blob
    }

    private static func cString(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 {
            end += 1
        }
        return String(data: data[offset..<end], encoding: .utf8)
    }

    private static func int32BE(_ data: Data, _ offset: Int) -> Int {
        Int(Int32(bitPattern: uint32BEValue(data, offset)))
    }

    private static func int32LE(_ data: Data, _ offset: Int) -> Int {
        Int(Int32(bitPattern: uint32LEValue(data, offset)))
    }

    private static func uint32BEValue(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func uint32LEValue(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func doubleLE(_ data: Data, _ offset: Int) -> Double {
        guard offset + 8 <= data.count else { return 0 }
        var bitPattern: UInt64 = 0
        for index in 0..<8 {
            bitPattern |= UInt64(data[offset + index]) << (index * 8)
        }
        return Double(bitPattern: bitPattern)
    }

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func doubleLE(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<8).map { UInt8((bits >> ($0 * 8)) & 0xFF) }
    }
}

/// Grok.app is a Safari Web App. Its grok.com session lives in that app's
/// WebKit cookie file — not `~/.grok/auth.json`, and not Grok Bot.
enum GrokAppSession {
    static let allowedHosts = ["grok.com", "x.ai"]

    static func cookieFiles(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let containers = userHome.appendingPathComponent("Library/Containers", isDirectory: true)
        var urls: [URL] = []
        let nestedRoot = containers
            .appendingPathComponent("com.apple.Safari.WebApp/Data/Library/Containers", isDirectory: true)
        urls.append(contentsOf: cookieFiles(inWebAppContainers: nestedRoot))
        urls.append(contentsOf: cookieFiles(inWebAppContainers: containers, dataPrefix: true))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func cookies(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = .now
    ) -> [SafariCookie] {
        cookieFiles(userHome: userHome).flatMap { url -> [SafariCookie] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return SafariBinaryCookies.parse(data)
        }
        .filter { cookie in
            isAllowedHost(cookie.domain) && isLive(cookie, now: now)
        }
    }

    static func hasSignedInCookies(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = .now
    ) -> Bool {
        !cookies(userHome: userHome, now: now).isEmpty
    }

    static func cookieHeader(
        from cookies: [SafariCookie]
    ) -> String? {
        let parts = cookies.compactMap { cookie -> String? in
            guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    static func isAllowedHost(_ domain: String) -> Bool {
        var host = domain.lowercased()
        if host.hasPrefix(".") {
            host.removeFirst()
        }
        return allowedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func isLive(_ cookie: SafariCookie, now: Date) -> Bool {
        let expiry = cookie.expiry.timeIntervalSinceReferenceDate
        if expiry <= 0 { return true }
        return cookie.expiry > now
    }

    private static func cookieFiles(inWebAppContainers root: URL, dataPrefix: Bool = false) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { child in
            let name = child.lastPathComponent
            guard name.hasPrefix("com.apple.Safari.WebApp.") else { return nil }
            let cookie: URL
            if dataPrefix {
                cookie = child.appendingPathComponent(
                    "Data/Library/WebKit/WebsiteData/Cookies/Cookies.binarycookies"
                )
            } else {
                cookie = child.appendingPathComponent(
                    "Library/WebKit/WebsiteData/Cookies/Cookies.binarycookies"
                )
            }
            return FileManager.default.fileExists(atPath: cookie.path) ? cookie : nil
        }
    }
}

enum GrokWebBillingClient {
    /// Safari on macOS 27.2. grok.com rejects the old Version/18 token with a
    /// challenge page, which the billing parser then drops.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Safari/605.1.15"

    static let creditsREST = URL(string: "https://grok.com/rest/grok/credits")!
    static let creditsGRPC = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    static let creditsProxy = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func fetchBilling(cookies: [SafariCookie]) async -> Data? {
        guard let cookieHeader = GrokAppSession.cookieHeader(from: cookies) else { return nil }
        let ssoBearer = cookies.first {
            $0.name.lowercased() == "sso" && $0.value.hasPrefix("eyJ")
        }?.value
        if let json = await getJSON(creditsREST, cookieHeader: cookieHeader),
           QuotaParsing.looksLikeBillingJSON(json) {
            return json
        }
        if let json = await getJSON(creditsProxy, cookieHeader: cookieHeader),
           QuotaParsing.looksLikeBillingJSON(json) {
            return json
        }
        if let json = await postConnectJSON(cookieHeader: cookieHeader),
           QuotaParsing.looksLikeBillingJSON(json) {
            return json
        }
        if let proto = await postGRPC(cookieHeader: cookieHeader, bearer: nil),
           let json = QuotaParsing.billingJSON(fromCreditsProtobuf: proto) {
            return json
        }
        if let ssoBearer,
           let proto = await postGRPC(cookieHeader: cookieHeader, bearer: ssoBearer),
           let json = QuotaParsing.billingJSON(fromCreditsProtobuf: proto) {
            return json
        }
        return nil
    }

    private static func getJSON(_ url: URL, cookieHeader: String) async -> Data? {
        var request = URLRequest(url: url)
        applyBrowserFields(&request, cookieHeader: cookieHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await send(request)
    }

    private static func postConnectJSON(cookieHeader: String) async -> Data? {
        var request = URLRequest(url: creditsGRPC)
        request.httpMethod = "POST"
        applyBrowserFields(&request, cookieHeader: cookieHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        return await send(request)
    }

    private static func postGRPC(cookieHeader: String, bearer: String?) async -> Data? {
        var request = URLRequest(url: creditsGRPC)
        request.httpMethod = "POST"
        applyBrowserFields(&request, cookieHeader: cookieHeader)
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        return await send(request)
    }

    private static func applyBrowserFields(_ request: inout URLRequest, cookieHeader: String) {
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
    }

    private static func send(_ request: URLRequest) async -> Data? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        if data.starts(with: Data("<!".utf8)) || data.starts(with: Data("<html".utf8)) {
            return nil
        }
        return data
    }
}
