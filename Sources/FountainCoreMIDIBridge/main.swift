import Foundation
import NIO
import NIOHTTP1
#if canImport(CoreMIDI)
import CoreMIDI
#endif

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body: ByteBuffer?
    private var currentPath: String = "/"

#if canImport(CoreMIDI)
    // CoreMIDI state
    private var client: MIDIClientRef = 0
    private var outPort: MIDIPortRef = 0
    private var selectedDestination: MIDIEndpointRef = 0
    override init() {
        super.init()
        MIDIClientCreate("FountainCoreMIDIBridge" as CFString, nil, nil, &client)
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    }
    deinit {
        if outPort != 0 { MIDIPortDispose(outPort) }
        if client != 0 { MIDIClientDispose(client) }
    }
    private func listDestinations() -> [[String: Any]] {
        var arr: [[String: Any]] = []
        let n = MIDIGetNumberOfDestinations()
        for i in 0..<n {
            let ep = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &name)
            let s = (status == noErr) ? (name?.takeRetainedValue() as String? ?? "dest_\(i)") : "dest_\(i)"
            arr.append(["index": Int(i), "name": s])
        }
        return arr
    }
    private func selectDestination(matching needle: String) -> Bool {
        let n = MIDIGetNumberOfDestinations()
        for i in 0..<n {
            let ep = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &name) == noErr {
                let s = (name?.takeRetainedValue() as String?) ?? ""
                if s.localizedCaseInsensitiveContains(needle) {
                    selectedDestination = ep
                    return true
                }
            }
        }
        return false
    }
    private func sendMIDI1(messages: [[Int]]) {
        guard selectedDestination != 0 else { return }
        for msg in messages {
            var bytes = msg.compactMap { $0 >= 0 && $0 <= 255 ? UInt8($0) : nil }
            guard !bytes.isEmpty else { continue }
            var packetList = MIDIPacketList(numPackets: 1, packet: MIDIPacket())
            let ts: MIDITimeStamp = 0
            bytes.withUnsafeMutableBytes { rawPtr in
                let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var p = MIDIPacketListInit(&packetList)
                p = MIDIPacketListAdd(&packetList, 1024, p, ts, bytes.count, ptr)
            }
            MIDISend(outPort, selectedDestination, &packetList)
        }
    }
#endif

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let req):
            currentPath = req.uri
            if req.method == .GET && req.uri == "/health" {
                writeString(context: context, status: .ok, contentType: "text/plain", body: "ok\n")
            } else {
                body = context.channel.allocator.buffer(capacity: 0)
            }
        case .body(var buf):
            if body == nil { body = context.channel.allocator.buffer(capacity: buf.readableBytes) }
            body?.writeBuffer(&buf)
        case .end:
            if let b = body {
                handleBody(context: context, buffer: b, path: currentPath)
            } else {
                writeString(context: context, status: .notFound, contentType: "text/plain", body: "not found\n")
            }
            body = nil
        }
    }

    private func handleBody(context: ChannelHandlerContext, buffer: ByteBuffer, path: String) {
        let data = Data(buffer.readableBytesView)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch path {
            case "/midi1/send":
                let msgs = (json["messages"] as? [[Int]]) ?? []
                #if canImport(CoreMIDI)
                sendMIDI1(messages: msgs)
                #endif
                writeString(context: context, status: .ok, contentType: "application/json", body: "{\"ok\":true}")
                return
            case "/destinations":
                #if canImport(CoreMIDI)
                let arr = listDestinations()
                if let payload = try? JSONSerialization.data(withJSONObject: ["items": arr]) {
                    let s = String(data: payload, encoding: .utf8) ?? "{}"
                    writeString(context: context, status: .ok, contentType: "application/json", body: s)
                } else { writeString(context: context, status: .internalServerError, contentType: "text/plain", body: "error\n") }
                #else
                writeString(context: context, status: .ok, contentType: "application/json", body: "{\"items\":[]}")
                #endif
                return
            case "/select-destination":
                let needle = (json["name"] as? String) ?? ""
                #if canImport(CoreMIDI)
                let ok = selectDestination(matching: needle)
                #else
                let ok = false
                #endif
                writeString(context: context, status: ok ? .ok : .notFound, contentType: "application/json", body: ok ? "{\"ok\":true}" : "{\"ok\":false}")
                return
            default: break
            }
        }
        writeString(context: context, status: .notFound, contentType: "text/plain", body: "not found\n")
    }

    private func writeString(context: ChannelHandlerContext, status: HTTPResponseStatus, contentType: String, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        context.write(self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
        buf.writeString(body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

@main
enum BridgeMain {
    static func main() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer { try? group.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let port = Int(ProcessInfo.processInfo.environment["BRIDGE_PORT"] ?? "18090") ?? 18090
        let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        print("FountainCoreMIDIBridge listening on :\(port)")
        try channel.closeFuture.wait()
    }
}
