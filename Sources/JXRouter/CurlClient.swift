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
            if !isIP {
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
        
        // Read headers with a reasonable buffer (avoid byte-by-byte)
        let fileHandle = outPipe.fileHandleForReading
        var headerData = Data()
        let headerTimeout = DispatchTime.now() + 10
        while DispatchTime.now() < headerTimeout {
            // Try to read up to 64KB at once
            if let chunk = try fileHandle.read(upToCount: 65536) {
                headerData.append(chunk)
                if let str = String(data: headerData, encoding: .utf8),
                   str.contains("\r\n\r\n") {
                    break
                }
                if headerData.count > 65536 {
                    break // safety valve: too much header data
                }
            } else {
                break
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
        
        if let first = lines.first, first.starts(with: "HTTP/") {
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }
        
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                responseHeaders[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: responseHeaders)!
        
        let stream = AsyncStream<Data> { continuation in
            // Yield any body data that was pre-read with headers
            if !preReadBody.isEmpty {
                continuation.yield(preReadBody)
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
