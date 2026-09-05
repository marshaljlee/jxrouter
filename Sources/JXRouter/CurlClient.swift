import Foundation

/// HTTP client that uses `/usr/bin/curl` for requests. Curl handles DNS
/// resolution (optionally to a pre-resolved IP), TLS, connection reuse,
/// and `--max-time` timeouts — all harder to get right with URLSession
/// in a proxy context.
struct CurlClient {

    /// Non-streaming request: returns (Data, HTTPURLResponse).
    static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data = Data(),
        resolveIP: String? = nil,
        maxTime: Int = 30
    ) async throws -> (Data, HTTPURLResponse) {
        let arguments = buildArgs(url: url, method: method, headers: headers, body: body, resolveIP: resolveIP, maxTime: maxTime, stream: false)
        let (stdout, _, _) = await runCurl(arguments: arguments)
        let statusCode = parseHTTPStatusCode(from: stdout)
        let separator = Data("\r\n\r\n".utf8)
        let data: Data
        if let range = stdout.range(of: separator) {
            data = stdout.subdata(in: range.upperBound..<stdout.endIndex)
        } else {
            data = stdout
        }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
            ?? HTTPURLResponse(url: url, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!  // fallback never nil for valid URL
        return (data, response)
    }

    /// Streaming request: returns (HTTPURLResponse headers, AsyncStream<Data> body chunks).
    static func stream(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data = Data(),
        resolveIP: String? = nil,
        maxTime: Int = 30
    ) async throws -> (HTTPURLResponse, AsyncStream<Data>) {
        let arguments = buildArgs(url: url, method: method, headers: headers, body: body, resolveIP: resolveIP, maxTime: maxTime, stream: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Read headers from the beginning of the output
        let headerData = pipe.fileHandleForReading.readData(ofLength: 4096)
        let statusCode = parseHTTPStatusCode(from: headerData)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
            ?? HTTPURLResponse(url: url, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!

        let stream = AsyncStream<Data> { continuation in
            // F6: the stream body runs on the Swift-concurrency cooperative
            // pool, where blocking FD reads starve every other async task.
            // Pump curl's output on a dedicated thread instead.
            Thread.detachNewThread {
                do {
                    let pump = CurlStreamPump(process: process, pipe: pipe, headerData: headerData, continuation: continuation)
                    pump.run()
                }
            }
        }
        return (response, stream)
    }

    // MARK: - Helpers

    private static func buildArgs(url: URL, method: String, headers: [String: String], body: Data, resolveIP: String?, maxTime: Int, stream: Bool) -> [String] {
        var args = [
            "-i",
            "-s", "-S",
            "--max-time", "\(maxTime)",
            "-X", method,
        ]
        // DNS resolve to a pre-resolved IP
        if let ip = resolveIP, let host = url.host, ip != host {
            args += ["--resolve", "\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80)):\(ip)"]
        }
        for (key, value) in headers {
            args += ["-H", "\(key): \(value)"]
        }
        if !body.isEmpty {
            args += ["-d", String(data: body, encoding: .utf8) ?? ""]
        }
        if stream {
            args += ["-N"] // No-buffer for streaming
        }
        args.append(url.absoluteString)
        return args
    }

    private static func runCurl(arguments: [String]) async -> (Data, Data, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (outData, errData, process.terminationStatus)
        } catch {
            return (Data(), Data(), 1)
        }
    }

    private static func parseHTTPStatusCode(from data: Data) -> Int {
        guard let str = String(data: data, encoding: .utf8),
              let firstLine = str.components(separatedBy: "\r\n").first,
              let parts = firstLine.split(separator: " ").dropFirst().first,
              let code = Int(parts) else {
            // No HTTP status line at all means curl produced no response
            // (DNS failure, connect refused, TLS error, timeout). That is a
            // gateway failure, NOT a 200 OK — report 502 so the provider
            // chain moves to the next fallback instead of serving an empty
            // "200" body as a real answer.
            return 502
        }
        return code
    }
}

/// F6: blocking stream pump that runs on its own thread. Reads curl's stdout
/// and yields chunks into the AsyncStream continuation.
private struct CurlStreamPump {
    let process: Process
    let pipe: Pipe
    let headerData: Data
    let continuation: AsyncStream<Data>.Continuation

    func run() {
        // Yield any data after the header separator
        let separator = Data("\r\n\r\n".utf8)
        if let range = headerData.range(of: separator) {
            let bodyStart = headerData.distance(from: headerData.startIndex, to: range.upperBound)
            if bodyStart < headerData.count {
                continuation.yield(headerData.subdata(in: bodyStart..<headerData.endIndex))
            }
        } else if !headerData.isEmpty {
            // Defensive fallback: if no HTTP header separator was present, do not drop data
            continuation.yield(headerData)
        }
        // Continue reading chunks
        while process.isRunning {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            continuation.yield(chunk)
        }
        // Read remaining data
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty { continuation.yield(remaining) }
        process.waitUntilExit()
        continuation.finish()
    }
}
