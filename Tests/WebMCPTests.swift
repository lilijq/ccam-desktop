import Foundation
import Darwin

@main struct WebMCPTests {
    static func main() throws {
        if let status = WebMCP.handleHelperInvocation() { exit(status) }
        let bridge = try WebMCPBridge(executable: CommandLine.arguments[0])
        bridge.handler = { name, args, done in done(WebMCP.result(name + ":" + (args["value"] as? String ?? ""))) }
        var done = false
        var failure: Error?
        DispatchQueue.global().async {
            do {
                for index in 0..<20 {
                    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: bridge.descriptor)) as! [String: String]
                    let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
                    WebMCP.configure(fd); var addr = try WebMCP.address(config["socket"]!)
                    let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                    guard connected == 0 else { throw WebMCP.failure("connection failed") }
                    usleep(30_000) // Reader must wait after accept, before any bytes arrive.
                    try WebMCP.send(["token": config["token"]!, "name": "echo", "arguments": ["value": "\(index)"]], fd: fd)
                    let result = try WebMCP.receive(fd)
                    guard WebMCP.jsonText(result).contains("echo:\(index)") else { throw WebMCP.failure("lost delayed frame \(index)") }
                }
            } catch { failure = error }
            DispatchQueue.main.async { done = true }
        }
        let deadline = Date().addingTimeInterval(15)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard done, failure == nil else { throw failure ?? WebMCP.failure("test timeout") }
        bridge.stop()
        print("PASS: 20 delayed socket frames; no lost first request, no network services")
    }
}
