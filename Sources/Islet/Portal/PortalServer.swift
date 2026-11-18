import Foundation
import IsletCore
import Network
import os
import UniformTypeIdentifiers

/// A paired iPhone. Only the hash of its token is kept; the token lives on the phone.
struct PortalDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var tokenHash: String
    var added: Date
}

/// Something the Mac has put in the portal for the phone to collect.
struct PortalOutboxItem: Sendable, Identifiable {
    let id: String
    let url: URL
    let name: String
    let size: Int64
    let added: Date
}

/// What arrived from a phone, handed to the main thread.
enum PortalDelivery: Sendable {
    /// A file, already written to a temporary location that the receiver now owns.
    case file(URL, name: String, from: String)
    case text(String, from: String)
}

/// The tiny HTTP server behind Portal. It serves the phone's web app, pairs phones with a
/// one-time code from the QR, and accepts files, text and links only with a paired
/// phone's token. All of its state lives on one serial queue; the main thread talks to
/// it through the locked properties and the callbacks.
final class PortalServer: @unchecked Sendable {
    /// The phone's page and its Home Screen icon, made on the main thread.
    struct Assets: Sendable {
        let page: Data
        let icon: Data
    }

    private let queue = DispatchQueue(label: "local.islet.portal")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: PortalConnection] = [:]
    private let assets: Assets
    private let onDelivery: @Sendable (PortalDelivery) -> Void
    private let onPaired: @Sendable (PortalDevice) -> Void
    private let onState: @Sendable (String?) -> Void
    /// A paired phone's upload under way: its name and how far along (nil: over).
    var onIncoming: (@Sendable (String, Double?) -> Void)?

    let devices = OSAllocatedUnfairLock<[PortalDevice]>(initialState: [])
    let pairing = OSAllocatedUnfairLock<PortalPairingCode?>(initialState: nil)
    let outbox = OSAllocatedUnfairLock<[PortalOutboxItem]>(initialState: [])
    /// When each paired phone last checked in, so the Mac knows one is listening.
    let lastSeen = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    /// The page's look, read by the phone (`/config`).
    let effect = OSAllocatedUnfairLock<String>(initialState: "vortex")

    /// A few phones at once is plenty; more is someone hammering the port.
    private static let maxConnections = 12

    init(assets: Assets, onDelivery: @escaping @Sendable (PortalDelivery) -> Void,
         onPaired: @escaping @Sendable (PortalDevice) -> Void, onState: @escaping @Sendable (String?) -> Void) {
        self.assets = assets
        self.onDelivery = onDelivery
        self.onPaired = onPaired
        self.onState = onState
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Portal.port)!)
                listener.service = NWListener.Service(name: Host.current().localizedName, type: "_islet-portal._tcp")
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.onState(nil)
                    case .failed(let error): self?.onState("Couldn't listen on port \(Portal.port): \(error.localizedDescription)")
                    default: break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                onState("Couldn't listen on port \(Portal.port): \(error.localizedDescription)")
            }
        }
    }

    /// Off really means off: the port closes and every open connection is dropped.
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.close() }
            connections.removeAll()
        }
    }

    // MARK: - Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else { return connection.cancel() }
        let handler = PortalConnection(connection: connection, queue: queue, server: self)
        let key = ObjectIdentifier(handler)
        connections[key] = handler
        handler.onClose = { [weak self] in self?.connections[key] = nil }
        handler.start()
    }

    /// The paired phone presenting `token`, if any.
    fileprivate func device(for token: String?) -> PortalDevice? {
        guard let token, !token.isEmpty else { return nil }
        let device = devices.withLock { list in list.first { PortalSecret.matches(token, hash: $0.tokenHash) } }
        if let device { lastSeen.withLock { $0[device.id] = Date() } }
        return device
    }

    fileprivate func route(_ head: PortalRequestHead, body: PortalBody, reply: PortalConnection) {
        let token = head.header("x-islet-token") ?? head.query["t"]
        switch (head.method, head.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            reply.send(200, "text/html; charset=utf-8", assets.page)
        case ("GET", "/icon.png"):
            reply.send(200, "image/png", assets.icon)
        case ("POST", "/pair"):
            pair(body: body.data, reply: reply)
        case ("GET", "/config"):
            guard device(for: token) != nil else { return reply.unauthorized() }
            let json = ["effect": effect.withLock { $0 }, "mac": Host.current().localizedName ?? "Mac"]
            reply.send(200, "application/json", (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        case ("POST", "/send"):
            guard let device = device(for: token) else { body.discard(); return reply.unauthorized() }
            receive(head, body: body, from: device, reply: reply)
        case ("GET", "/outbox"):
            guard device(for: token) != nil else { return reply.unauthorized() }
            let items = outbox.withLock { $0 }.map { ["id": $0.id, "name": $0.name, "size": $0.size] as [String: Any] }
            reply.send(200, "application/json", (try? JSONSerialization.data(withJSONObject: items)) ?? Data())
        case ("GET", let path) where path.hasPrefix("/outbox/"):
            guard device(for: token) != nil else { return reply.unauthorized() }
            let id = String(path.dropFirst("/outbox/".count))
            guard let item = outbox.withLock({ $0.first { $0.id == id } }) else { return reply.send(404, "text/plain", Data("Gone".utf8)) }
            reply.sendFile(item.url, name: item.name)
        case ("DELETE", let path) where path.hasPrefix("/outbox/"):
            guard device(for: token) != nil else { return reply.unauthorized() }
            let id = String(path.dropFirst("/outbox/".count))
            outbox.withLock { $0.removeAll { $0.id == id } }
            reply.send(204, "text/plain", Data())
        default:
            body.discard()
            reply.send(404, "text/plain", Data("Not found".utf8))
        }
    }

    private func pair(body: Data?, reply: PortalConnection) {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = json["code"] as? String else { return reply.send(400, "text/plain", Data("Bad request".utf8)) }
        let accepted = pairing.withLock { pending -> Bool in
            guard var current = pending else { return false }
            let ok = current.redeem(code)
            pending = current
            return ok
        }
        guard accepted else { return reply.send(403, "text/plain", Data("This code has expired. Scan the QR code again.".utf8)) }
        let rawName = (json["name"] as? String ?? "Phone").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = PortalSecret.make()
        let device = PortalDevice(id: UUID().uuidString, name: String((rawName.isEmpty ? "Phone" : rawName).prefix(40)),
                                  tokenHash: PortalSecret.hash(token), added: Date())
        devices.withLock { $0.append(device) }
        lastSeen.withLock { $0[device.id] = Date() }
        onPaired(device)
        let response = ["token": token, "name": device.name, "mac": Host.current().localizedName ?? "Mac"]
        reply.send(200, "application/json", (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
    }

    private func receive(_ head: PortalRequestHead, body: PortalBody, from device: PortalDevice, reply: PortalConnection) {
        let kind = head.header("x-islet-kind") ?? "file"
        if kind == "text" {
            guard let data = body.data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return reply.send(400, "text/plain", Data("Empty".utf8))
            }
            onDelivery(.text(text, from: device.name))
            return reply.send(200, "application/json", Data("{\"ok\":true}".utf8))
        }
        guard let file = body.file else { return reply.send(400, "text/plain", Data("Empty".utf8)) }
        let rawName = head.header("x-islet-name").flatMap { $0.removingPercentEncoding } ?? "Portal Item"
        onDelivery(.file(file, name: PortalFilename.sanitize(rawName), from: device.name))
        reply.send(200, "application/json", Data("{\"ok\":true}".utf8))
    }
}

/// A request body as it arrived: small text bodies in memory, uploads in a temporary file.
final class PortalBody: @unchecked Sendable {
    var data: Data?
    var file: URL?

    func discard() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}

/// One HTTP exchange on one connection: read the head, stream the body (to memory or a
/// temporary file), route it, reply, close.
/// Only touched on the server's serial queue.
final class PortalConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: PortalServer?
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var head: PortalRequestHead?
    private let body = PortalBody()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var closed = false
    private var idle: DispatchWorkItem?
    /// The paired phone sending a file, while it comes in.
    private var sender: String?
    private var reported = -1.0

    /// Upload progress for the edge portal, in steps of a few percent; nil when it's over.
    private func report(_ progress: Double?) {
        guard let sender else { return }
        if let progress {
            guard progress - reported >= 0.04 || reported < 0 else { return }
            reported = progress
        } else {
            self.sender = nil
        }
        server?.onIncoming?(sender, progress)
    }

    init(connection: NWConnection, queue: DispatchQueue, server: PortalServer) {
        self.connection = connection
        self.queue = queue
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        read()
    }

    func close() {
        guard !closed else { return }
        closed = true
        idle?.cancel()
        try? handle?.close()
        handle = nil
        if head?.method == "POST", body.file != nil, received < (head?.contentLength ?? 0) { body.discard() }
        report(nil)
        connection.cancel()
        onClose?()
    }

    /// A stalled sender is dropped after 30 seconds of silence.
    private func touch() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        idle = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func read() {
        touch()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if self.closed { return }
            if error != nil || complete { return self.close() }
            self.read()
        }
    }

    private func consume(_ data: Data) {
        guard let head else {
            buffer.append(data)
            switch PortalRequestHead.parse(buffer) {
            case .incomplete: return
            case .invalid: return send(400, "text/plain", Data("Bad request".utf8))
            case let .complete(parsed, headLength):
                let rest = buffer.dropFirst(headLength)
                buffer = Data()
                begin(parsed)
                if !closed, !rest.isEmpty { consume(Data(rest)) }
                return
            }
        }
        appendBody(data, for: head)
    }

    private func begin(_ parsed: PortalRequestHead) {
        head = parsed
        let isFile = parsed.method == "POST" && parsed.path == "/send" && parsed.header("x-islet-kind") ?? "file" == "file"
        let limit = isFile ? Portal.maxFileBytes : Int64(Portal.maxTextBytes)
        guard parsed.contentLength <= limit else { return send(413, "text/plain", Data("Too large".utf8)) }
        // Only a paired phone may make Islet write to disk.
        if isFile {
            guard let device = server?.device(for: parsed.header("x-islet-token") ?? parsed.query["t"]) else { return unauthorized() }
            sender = device.name
            report(0)
            let url = FileManager.default.temporaryDirectory.appending(path: "portal-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else { return send(500, "text/plain", Data("Disk".utf8)) }
            body.file = url
            self.handle = handle
        } else {
            body.data = Data()
        }
        if parsed.contentLength == 0 { finish() }
    }

    private func appendBody(_ data: Data, for head: PortalRequestHead) {
        let room = head.contentLength - received
        guard room > 0 else { return }
        let chunk = data.count > room ? data.prefix(Int(room)) : data
        received += Int64(chunk.count)
        if head.contentLength > 0 { report(Double(received) / Double(head.contentLength)) }
        if let handle {
            do { try handle.write(contentsOf: chunk) } catch { body.discard(); return send(500, "text/plain", Data("Disk".utf8)) }
        } else {
            body.data?.append(chunk)
        }
        if received >= head.contentLength { finish() }
    }

    private func finish() {
        guard let head else { return }
        try? handle?.close()
        handle = nil
        idle?.cancel()
        guard let server else { return close() }
        server.route(head, body: body, reply: self)
    }

    // MARK: Replies

    func unauthorized() {
        send(401, "text/plain", Data("Pair this phone again: Settings → Portal on your Mac.".utf8))
    }

    func send(_ status: Int, _ type: String, _ payload: Data) {
        guard !closed else { return }
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 413: "Payload Too Large", 500: "Server Error"][status] ?? "OK"
        var out = portalResponseHead(status: status, reason: reason, contentType: type, length: Int64(payload.count))
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    /// Streams a file to the phone as a download.
    func sendFile(_ url: URL, name: String) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else { return send(404, "text/plain", Data("Gone".utf8)) }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        // The real type, so the page can show photos as thumbnails before they're saved.
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let head = portalResponseHead(status: 200, reason: "OK", contentType: type, length: size,
                                      extra: ["Content-Disposition": "attachment; filename*=UTF-8''\(encoded)"])
        connection.send(content: head, completion: .contentProcessed { _ in })
        pump(handle)
    }

    private func pump(_ handle: FileHandle) {
        touch()
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { [weak self] _ in self?.close() })
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !self.closed else { try? handle.close(); self?.close(); return }
            self.pump(handle)
        })
    }
}
