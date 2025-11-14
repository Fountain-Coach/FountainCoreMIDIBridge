import Foundation
import NIO
import NIOHTTP1

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let req):
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
                handleBody(context: context, buffer: b)
            } else {
                writeString(context: context, status: .notFound, contentType: "text/plain", body: "not found\n")
            }
            body = nil
        }
    }

    private func handleBody(context: ChannelHandlerContext, buffer: ByteBuffer) {
        let data = Data(buffer.readableBytesView)
        guard let reqStr = context.channel.parent else {
            // decode JSON and route
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // /midi1/send — log messages
                if let path = currentRequestPath(context: context), path == "/midi1/send" {
                    let msgs = (json["messages"] as? [[Int]]) ?? []
                    FileHandle.standardError.write(Data("[bridge] midi1 msgs=\(msgs.count)\n".utf8))
                    writeString(context: context, status: .ok, contentType: "application/json", body: "{\"ok\":true}")
                    return
                }
            }
            writeString(context: context, status: .notFound, contentType: "text/plain", body: "not found\n")
            return
        }
    }

    private func currentRequestPath(context: ChannelHandlerContext) -> String? {
        // NIO doesn’t retain the head by default; we keep it simple: not used for /health here
        return nil
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
