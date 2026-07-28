import Foundation

enum CurlError: Error {
    case invalidResponse
    case processFailed(Int32)
}

final class CurlClient {
    static func request(url: URL, method: String, headers: [String: String], body: Data?, resolveIP: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let (response, stream) = try await self.stream(url: url, method: method, headers: headers, body: body, resolveIP: resolveIP)
        
        var fullData = Data()
        for await chunk in stream {
            fullData.append(chunk)
        }
        
        return (fullData, response)
    }
    
    static func stream(url: URL, method: String, headers: [String: String], body: Data?, resolveIP: String? = nil) async throws -> (HTTPURLResponse, AsyncStream<Data>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        
        var args = ["-i", "-s", "-N", "--max-time", "30", "--connect-timeout", "10", "-X", method]
        
        if let ip = resolveIP, let host = url.host {
            // Only use --resolve when the host is a named host, not a raw IP.
            // curl's --resolve expects <hostname>:<port>:<ip> — passing an IP
            // as the hostname causes a silent failure.
            let isIP = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
                || host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ":") })
            // Also verify that the resolved value is actually an IPv4 address.
            // When DirectDNSResolver fails (NXDOMAIN), it falls back to the hostname
            // string itself, which causes curl to fail with exit code 49 (bad argument).
            let isResolvedIP = ip.split(separator: ".").count == 4
                && ip.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })
            if !isIP, isResolvedIP {
                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                args.append("--resolve")
                args.append("\(host):\(port):\(ip)")
            }
        }
        
        for (key, value) in headers {
            args.append("-H")
            args.append("\(key): \(value)")
        }
        
        // Avoid temp files — pipe body in via stdin
        if let bodyData = body {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            args.append("--data-binary")
            args.append("@-")
            // Write body in background to avoid deadlock
            DispatchQueue.global().async {
                stdinPipe.fileHandleForWriting.write(bodyData)
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }
        
        args.append(url.absoluteString)
        process.arguments = args
        
        let outPipe = Pipe()
        process.standardOutput = outPipe
        
        try process.run()
        
        // FIX #5: Header read with time-bounded poll using select().
        // We need a way to read headers without blocking indefinitely when the
        // upstream doesn't respond. Using O_NONBLOCK on the pipe fd causes the
        // downstream readabilityHandler to see spurious EOF. Instead we use
        // select() to poll for readability with a timeout, then read normally.
        let fileHandle = outPipe.fileHandleForReading
        let fd = fileHandle.fileDescriptor
        
        var headerData = Data()
        let headerDeadline = DispatchTime.now() + 30 // Match curl --max-time
        
        while DispatchTime.now() < headerDeadline {
            // Use poll() to check if the pipe has data without blocking.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: Int16(0))
            let pollResult = poll(&pfd, nfds_t(1), 50) // 50ms timeout
            
            if pollResult > 0 {
                // fd is readable — read the data
                if let chunk = try fileHandle.read(upToCount: 65536) {
                    guard !chunk.isEmpty else { break } // EOF / pipe closed
                    headerData.append(chunk)
                    if let str = String(data: headerData, encoding: .utf8),
                       str.contains("\r\n\r\n") {
                        break
                    }
                    if headerData.count > 65536 {
                        break // safety valve: too much header data
                    }
                } else {
                    // read returned nil without error
                    break
                }
            } else if pollResult < 0 {
                // poll error
                break
            } else {
                // timeout — no data yet, yield to async runtime
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
        
        // Extract just the headers (before \r\n\r\n), put back any body data that leaked in
        let headerString = String(data: headerData, encoding: .utf8) ?? ""
        let headerComponents = headerString.components(separatedBy: "\r\n\r\n")
        let actualHeaderString = headerComponents.first ?? ""
        var preReadBody = Data()
        if headerComponents.count > 1 {
            let rest = headerComponents.dropFirst().joined(separator: "\r\n\r\n")
            preReadBody = rest.data(using: .utf8) ?? Data()
        }
        
        let lines = actualHeaderString.components(separatedBy: "\r\n")
        var statusCode = 200
        var responseHeaders: [String: String] = [:]
        
        // Check if we actually received an HTTP response.
        // When curl fails (DNS error, bad argument, connection refused), it produces
        // no HTTP output at all, and headerData/headerString is empty. In that case
        // we report 502 Bad Gateway so the ProviderRouter can fall through to the
        // next provider instead of treating the empty response as a "successful" 200.
        let receivedHTTPResponse = lines.first?.starts(with: "HTTP/") ?? false
        
        if receivedHTTPResponse, let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        } else if headerData.isEmpty {
            statusCode = 502 // Bad Gateway — upstream is unreachable
        }
        
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                responseHeaders[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: responseHeaders)!
        
        // FIX #7: Add onTermination handler to clean up curl when consumer disconnects.
        let stream = AsyncStream<Data> { continuation in
            // Yield any body data that was pre-read with headers
            if !preReadBody.isEmpty {
                continuation.yield(preReadBody)
            }
            
            continuation.onTermination = { @Sendable _ in
                // Consumer stopped iterating (client disconnect, timeout, etc.)
                // Kill the curl process to free system resources.
                fileHandle.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    process.waitUntilExit()
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        
        return (response, stream)
    }
}
