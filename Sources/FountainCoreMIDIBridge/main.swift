import Foundation
import NIO
import NIOHTTP1
#if canImport(CoreMIDI)
import CoreMIDI
#endif
#if canImport(CoreBluetooth)
import CoreBluetooth
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
    // BLE Peripheral bridge
#if canImport(CoreBluetooth)
    private var ble: BLEPeripheralBridge? = nil
#endif
    // RTP session helpers
    private func rtpStatus() -> [String: Any] {
        var obj: [String: Any] = ["enabled": false]
        #if canImport(CoreMIDI)
        let session = MIDINetworkSession.default()
        obj["enabled"] = session.isEnabled
        obj["networkName"] = session.networkName
        obj["localName"] = session.localName
        obj["connectionPolicy"] = (session.connectionPolicy == .anyone) ? "anyone" : "none"
        // Endpoint refs omitted for portability
        #endif
        return obj
    }
    private func rtpEnable(_ enable: Bool) -> Bool {
        let session = MIDINetworkSession.default()
        session.isEnabled = enable
        if enable { session.connectionPolicy = .anyone }
        return session.isEnabled
    }
    private func rtpConnect(host: String, port: Int) -> Bool {
        let session = MIDINetworkSession.default()
        let conn = MIDINetworkConnection(host: MIDINetworkHost(name: host, address: host, port: port))
        return session.addConnection(conn)
    }
    init() {
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
            bytes.withUnsafeBytes { rawPtr in
                let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var p = MIDIPacketListInit(&packetList)
                p = MIDIPacketListAdd(&packetList, 1024, p, ts, bytes.count, ptr)
            }
            MIDISend(outPort, selectedDestination, &packetList)
            #if canImport(CoreBluetooth)
            ble?.send(bytes: bytes)
            #endif
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
            } else if req.method == .GET && req.uri == "/rtp/status" {
                #if canImport(CoreMIDI)
                if let data = try? JSONSerialization.data(withJSONObject: rtpStatus()), let s = String(data: data, encoding: .utf8) {
                    writeString(context: context, status: .ok, contentType: "application/json", body: s)
                } else {
                    writeString(context: context, status: .internalServerError, contentType: "text/plain", body: "error\n")
                }
                #else
                writeString(context: context, status: .ok, contentType: "application/json", body: "{\"enabled\":false}")
                #endif
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
            case "/ble/advertise":
                #if canImport(CoreBluetooth)
                let enable = (json["enable"] as? Bool) ?? true
                let name = (json["name"] as? String) ?? "Fountain MIDI"
                if enable {
                    if ble == nil { ble = BLEPeripheralBridge(name: name) }
                    ble?.start(name: name)
                    writeString(context: context, status: .ok, contentType: "application/json", body: "{\"ok\":true}")
                } else {
                    ble?.stop(); ble = nil
                    writeString(context: context, status: .ok, contentType: "application/json", body: "{\"ok\":true}")
                }
                #else
                writeString(context: context, status: .ok, contentType: "application/json", body: "{\"ok\":false}")
                #endif
                return
            case "/ble/status":
                #if canImport(CoreBluetooth)
                let s = ble?.status() ?? ["enabled": false]
                if let data = try? JSONSerialization.data(withJSONObject: s), let str = String(data: data, encoding: .utf8) {
                    writeString(context: context, status: .ok, contentType: "application/json", body: str)
                } else { writeString(context: context, status: .internalServerError, contentType: "text/plain", body: "error\n") }
                #else
                writeString(context: context, status: .ok, contentType: "application/json", body: "{\"enabled\":false}")
                #endif
                return
            case "/rtp/session":
                let enable = (json["enable"] as? Bool) ?? true
                #if canImport(CoreMIDI)
                let ok = rtpEnable(enable)
                #else
                let ok = false
                #endif
                writeString(context: context, status: ok ? .ok : .internalServerError, contentType: "application/json", body: ok ? "{\"ok\":true}" : "{\"ok\":false}")
                return
            case "/rtp/connect":
                let host = (json["host"] as? String) ?? ""
                let port = (json["port"] as? Int) ?? 5004
                #if canImport(CoreMIDI)
                let ok = !host.isEmpty ? rtpConnect(host: host, port: port) : false
                #else
                let ok = false
                #endif
                writeString(context: context, status: ok ? .ok : .badRequest, contentType: "application/json", body: ok ? "{\"ok\":true}" : "{\"ok\":false}")
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

#if canImport(CoreBluetooth)
// Minimal BLE MIDI 1.0 Peripheral
final class BLEPeripheralBridge: NSObject, CBPeripheralManagerDelegate {
    private var pm: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var service: CBMutableService?
    private var name: String = "Fountain MIDI"
    private var isAdvertisingFlag: Bool = false
    private var subscribed: [CBCentral] = []

    init(name: String) {
        super.init()
        self.name = name
        self.pm = CBPeripheralManager(delegate: self, queue: DispatchQueue(label: "ble.periph"))
    }
    func start(name: String) {
        self.name = name
        if pm.state == .poweredOn { setupAndAdvertise() }
    }
    func stop() {
        pm.stopAdvertising()
        isAdvertisingFlag = false
        if let s = service { pm.remove(s) }
        service = nil; characteristic = nil; subscribed.removeAll()
    }
    func status() -> [String: Any] { [
        "enabled": pm.state == .poweredOn,
        "advertising": isAdvertisingFlag,
        "name": name,
        "subscribed": subscribed.count
    ] }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { setupAndAdvertise() }
    }
    private func setupAndAdvertise() {
        // MIDI BLE UUIDs
        let svcUUID = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
        let chrUUID = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")
        let props: CBCharacteristicProperties = [.notify, .writeWithoutResponse]
        let perms: CBAttributePermissions = [.readable, .writeable]
        let chr = CBMutableCharacteristic(type: chrUUID, properties: props, value: nil, permissions: perms)
        let svc = CBMutableService(type: svcUUID, primary: true)
        svc.characteristics = [chr]
        self.characteristic = chr
        self.service = svc
        pm.add(svc)
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [svcUUID],
            CBAdvertisementDataLocalNameKey: name
        ])
        isAdvertisingFlag = true
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) { subscribed.append(central) }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) { subscribed.removeAll { $0.identifier == central.identifier } }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Accept writes; no echo/responses necessary for bridge
        for r in requests { pm.respond(to: r, withResult: .success) }
    }
    func send(bytes: [UInt8]) {
        guard let chr = characteristic else { return }
        let frames = blePacketize(bytes)
        for f in frames {
            let data = Data(f)
            _ = pm.updateValue(data, for: chr, onSubscribedCentrals: subscribed)
        }
    }
    // Naive BLE MIDI packetization: prefix 0x80 timestamp per frame; chunk by 20 bytes
    private func blePacketize(_ bytes: [UInt8]) -> [[UInt8]] {
        guard !bytes.isEmpty else { return [] }
        var out: [[UInt8]] = []
        var cursor = 0
        while cursor < bytes.count {
            let remain = bytes.count - cursor
            let take = min(19, remain) // 1 byte for header
            var frame: [UInt8] = [0x80] // timestamp high bit set
            frame.append(contentsOf: bytes[cursor..<(cursor + take)])
            out.append(frame)
            cursor += take
        }
        return out
    }
}
#endif
