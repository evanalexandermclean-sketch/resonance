import Foundation
import Network
import Combine

/// UPnP/DLNA client with zero third-party dependencies.
/// 1. SSDP M-SEARCH over UDP to 239.255.255.250:1900
/// 2. Fetch device description XML -> find ContentDirectory controlURL
/// 3. SOAP Browse -> DIDL-Lite -> Track list (streamable by AVPlayer)
///
/// Works with Synology Media Server, QNAP, Plex (DLNA on), Jellyfin (DLNA plugin), MiniDLNA, etc.
@MainActor
final class DLNAService: ObservableObject {
    @Published private(set) var servers: [DLNAServer] = []
    @Published private(set) var isSearching = false
    @Published var lastError: String? = nil

    // Cache control URLs + browse results per session
    private var controlURLCache: [String: URL] = [:]

    // MARK: - Discovery

    func discover(timeoutSeconds: Int = 6) {
        guard !isSearching else { return }
        isSearching = true
        lastError = nil
        servers = []

        Task.detached { [weak self] in
            let found = await SSDPDiscovery.search(timeoutSeconds: timeoutSeconds)
            await MainActor.run {
                guard let self else { return }
                self.servers = found
                self.isSearching = false
                if found.isEmpty {
                    self.lastError = "No DLNA servers found. Check Wi-Fi (same LAN as NAS) and enable Media Server / DLNA on the NAS."
                } else {
                    // Resolve control URLs in background
                    for s in found { Task { await self.resolveControlURL(for: s) } }
                }
            }
        }
    }

    /// Manual entry fallback (e.g. multicast blocked on network): paste device description URL.
    /// Example: http://192.168.1.10:50001/desc.xml  (Synology) or :8200/... (MiniDLNA)
    func addManualServer(location: String, name: String? = nil) {
        guard let url = URL(string: location.trimmingCharacters(in: .whitespaces)) else {
            lastError = "Invalid URL"; return
        }
        let server = DLNAServer(
            id: "manual-\(url.absoluteString)",
            friendlyName: name ?? url.host ?? "Manual NAS",
            locationURL: url
        )
        if !servers.contains(server) { servers.append(server) }
        Task { await resolveControlURL(for: server) }
    }

    // MARK: - Browse

    /// Browse a ContentDirectory container. objectID "0" = root.
    func browse(server: DLNAServer, objectID: String = "0") async -> (containers: [DLNAContainer], tracks: [Track]) {
        guard let control = controlURLCache[server.id] ?? server.controlURL else {
            await resolveControlURL(for: server)
            guard let retry = controlURLCache[server.id] else { return ([], []) }
            return await browseControl(controlURL: retry, server: server, objectID: objectID)
        }
        return await browseControl(controlURL: control, server: server, objectID: objectID)
    }

    // MARK: - Private: device description + SOAP

    private func resolveControlURL(for server: DLNAServer) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: server.locationURL)
            let parser = DeviceDescriptionParser(data: data, baseURL: server.locationURL)
            if let control = parser.contentDirectoryControlURL {
                controlURLCache[server.id] = control
                // Update friendly name
                if let idx = servers.firstIndex(of: server), let name = parser.friendlyName {
                    servers[idx].friendlyName = name
                    servers[idx].controlURL = control
                }
            }
        } catch {
            lastError = "Could not read NAS description (\(server.friendlyName)): \(error.localizedDescription)"
        }
    }

    private func browseControl(controlURL: URL, server: DLNAServer, objectID: String) async -> (containers: [DLNAContainer], tracks: [Track]) {
        let soap = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(objectID)</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>0</StartingIndex>
              <RequestedCount>200</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.httpBody = soap.data(using: .utf8)
        req.setValue("urn:schemas-upnp-org:service:ContentDirectory:1#Browse", forHTTPHeaderField: "SOAPACTION")
        req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let didl = SOAPBrowseParser(data: data).extractDIDL()
            let parsed = DIDLParser.parse(didlXML: didl, serverName: server.friendlyName)
            return parsed
        } catch {
            lastError = "Browse failed: \(error.localizedDescription)"
            return ([], [])
        }
    }
}

// MARK: - SSDP (UDP multicast)
// Replies to M-SEARCH come back as unicast to the sending socket,
// so a single NWConnection is enough — no separate listener needed.
enum SSDPDiscovery {
    static func search(timeoutSeconds: Int = 6) async -> [DLNAServer] {
        await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "ssdp")
            var results: [String: DLNAServer] = [:]
            var finished = false
            func finish(_ v: [DLNAServer]) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: v)
            }

            let params = NWParameters.udp
            let connection = NWConnection(host: "239.255.255.250", port: 1900, using: params)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let msearch = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ns=01;\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:service:ContentDirectory:1\r\nUSER-AGENT: Resonance/1.0 DLNA\r\n\r\n"
                    guard let data = msearch.data(using: .utf8) else { return }
                    for i in 0..<3 {
                        queue.asyncAfter(deadline: .now() + .seconds(i)) {
                            connection.send(content: data, completion: .idempotent)
                        }
                    }
                    receiveLoop()
                } else if case .failed = state {
                    finish([])
                }
            }

            func receiveLoop() {
                connection.receiveMessage { data, _, _, _ in
                    if let data, let str = String(data: data, encoding: .utf8),
                       let server = parseResponse(str) {
                        results[server.id] = server
                    }
                    if !finished { receiveLoop() } // keep listening until timeout
                }
            }

            func parseResponse(_ str: String) -> DLNAServer? {
                var location: String?; var usn: String?; var serverHdr = ""
                for line in str.components(separatedBy: .newlines) {
                    let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if l.isEmpty { continue }
                    let lower = l.lowercased()
                    if lower.hasPrefix("location:") { location = l.dropFirst(9).trimmingCharacters(in: .whitespaces) }
                    else if lower.hasPrefix("usn:") { usn = l.dropFirst(4).trimmingCharacters(in: .whitespaces) }
                    else if lower.hasPrefix("server:") { serverHdr = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                }
                guard let loc = location?.trimmingCharacters(in: .whitespaces), let url = URL(string: loc) else { return nil }
                let id = (usn?.isEmpty == false ? usn! : loc)
                let name = serverHdr.isEmpty ? (url.host ?? "NAS") : serverHdr
                return DLNAServer(id: id, friendlyName: name, locationURL: url)
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                connection.cancel()
                let sorted = Array(results.values).sorted { $0.friendlyName < $1.friendlyName }
                finish(sorted)
            }
        }
    }
}

// MARK: - XML parsers (Foundation only)

/// Reads device description XML to find ContentDirectory controlURL + friendlyName.
final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    private(set) var friendlyName: String?
    private(set) var contentDirectoryControlURL: URL?
    private let baseURL: URL
    private var currentElement = ""
    private var currentText = ""
    private var inContentDirectory = false
    private var foundServiceType = false
    private var pendingControlURL: String?

    init(data: Data, baseURL: URL) {
        self.baseURL = baseURL
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        if let rel = pendingControlURL {
            contentDirectoryControlURL = URL(string: rel, relativeTo: baseURL)?.absoluteURL
        }
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = e; currentText = ""
        if e == "service" { foundServiceType = false; pendingControlURL = pendingControlURL } // reset per service handled in didEnd
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { currentText += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if e == "friendlyName", !t.isEmpty { friendlyName = t }
        if e == "serviceType", t.contains("ContentDirectory") { foundServiceType = true }
        if e == "controlURL", foundServiceType, !t.isEmpty {
            // Only first ContentDirectory controlURL counts
            if pendingControlURL == nil { pendingControlURL = t }
        }
        if e == "service" { foundServiceType = false }
    }
}

/// Extracts the DIDL-Lite payload from a SOAP Browse response.
final class SOAPBrowseParser: NSObject, XMLParserDelegate {
    private var insideResult = false
    private var buffer = ""
    private(set) var didlString = ""
    init(data: Data) {
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if e == "Result" { insideResult = true; buffer = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if insideResult { buffer += s } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if insideResult, let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        if e == "Result" { insideResult = false; didlString = buffer }
    }
    func extractDIDL() -> String { didlString }
}

/// Parses DIDL-Lite containers + audio items into app models.
enum DIDLParser {
    static func parse(didlXML: String, serverName: String) -> (containers: [DLNAContainer], tracks: [Track]) {
        guard let data = didlXML.data(using: .utf8) else { return ([], []) }
        let delegate = Handler(serverName: serverName)
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.parse()
        return (delegate.containers, delegate.tracks)
    }

    private final class Handler: NSObject, XMLParserDelegate {
        let serverName: String
        var containers: [DLNAContainer] = []
        var tracks: [Track] = []
        init(serverName: String) { self.serverName = serverName }

        // container state
        private var curContainerID: String?
        private var curContainerTitle = ""
        private var curChildCount = 0
        private var inContainer = false

        // item state
        private var inItem = false
        private var itemID = ""
        private var itemTitle = ""
        private var itemArtist = "Unknown Artist"
        private var itemAlbum = ""
        private var itemResURL: String?
        private var itemDuration: TimeInterval = 0
        private var itemArtwork: String?
        private var curElement = ""
        private var curText = ""
        private var pendingResDuration: TimeInterval = 0

        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
            let name = q ?? e
            curElement = name; curText = ""
            if name.hasSuffix("container") {
                inContainer = true
                curContainerID = a["id"]
                curChildCount = Int(a["childCount"] ?? "0") ?? 0
                curContainerTitle = ""
            }
            if name.hasSuffix("item") {
                inItem = true
                itemID = a["id"] ?? UUID().uuidString
                itemTitle = ""; itemArtist = "Unknown Artist"; itemAlbum = ""
                itemResURL = nil; itemDuration = 0; itemArtwork = nil
            }
            if name.hasSuffix("res"), inItem {
                pendingResDuration = Self.parseDLNADuration(a["duration"])
            }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { curText += s }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            let name = q ?? e
            let t = curText.trimmingCharacters(in: .whitespacesAndNewlines)
            if inContainer {
                if name.hasSuffix("title") { curContainerTitle += t }
                if name.hasSuffix("container") {
                    inContainer = false
                    if let id = curContainerID {
                        containers.append(DLNAContainer(id: id, title: curContainerTitle.isEmpty ? "Folder" : curContainerTitle, childCount: curChildCount))
                    }
                }
            }
            if inItem {
                if name.hasSuffix("title") && curElement.hasSuffix("title") { itemTitle = t }
                else if name.hasSuffix("artist") { itemArtist = t.isEmpty ? itemArtist : t }
                else if name.hasSuffix("album") { itemAlbum = t }
                else if name.hasSuffix("albumArtURI") { itemArtwork = t }
                else if name.hasSuffix("res") {
                    if itemResURL == nil, t.lowercased().hasPrefix("http") {
                        itemResURL = t
                        itemDuration = pendingResDuration
                    }
                }
                else if name.hasSuffix("item") {
                    inItem = false
                    if let res = itemResURL, let url = URL(string: res) {
                        tracks.append(Track(
                            id: "dlna-\(itemID)-\(res.hashValue)",
                            title: itemTitle.isEmpty ? url.lastPathComponent : itemTitle,
                            artist: itemArtist, album: itemAlbum.isEmpty ? serverName : itemAlbum,
                            duration: itemDuration,
                            artworkURL: itemArtwork.flatMap { URL(string: $0) },
                            streamURL: url, source: .dlna
                        ))
                    }
                }
            }
        }
        /// DLNA duration looks like "0:04:12.000" or "274.00"
        static func parseDLNADuration(_ s: String?) -> TimeInterval {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
            if !s.contains(":") { return TimeInterval(s) ?? 0 }
            let parts = s.split(separator: ":").map { $0.split(separator: ".")[0] }.compactMap { Int($0) }
            if parts.count == 3 { return TimeInterval(parts[0]*3600 + parts[1]*60 + parts[2]) }
            if parts.count == 2 { return TimeInterval(parts[0]*60 + parts[1]) }
            return 0
        }
    }
}
