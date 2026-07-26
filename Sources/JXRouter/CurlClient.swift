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
        
        var args = ["-i", "-s", "-N", "-X", method]
        
        if let ip = resolveIP, let host = url.host {
            let port = url.port ?? (url.scheme == "https" ? 443 : 80)
            args.append("--resolve")
            args.append("\(host):\(port):\(ip)")
        }
        
        for (key, value) in headers {
            args.append("-H")
            args.append("\(key): \(value)")
        }
        
        let tempFileURL: URL?
        if let bodyData = body {
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".json")
            try bodyData.write(to: tempFile)
            args.append("--data-binary")
            args.append("@\(tempFile.path)")
            tempFileURL = tempFile
        } else {
            tempFileURL = nil
        }
        
        args.append(url.absoluteString)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        
        // Read headers
        let fileHandle = pipe.fileHandleForReading
        var headerData = Data()
        var statusCode = 200
        var responseHeaders: [String: String] = [:]
        
        // Continue reading until we hit \r\n\r\n
        while let byteData = try fileHandle.read(upToCount: 1), !byteData.isEmpty {
            headerData.append(byteData)
            if headerData.count >= 4 && headerData.suffix(4) == Data("\r\n\r\n".utf8) {
                break
            }
        }
        
        let headerString = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerString.components(separatedBy: "\r\n")
        
        // Handle HTTP/2 or HTTP/1.1 response status line (can be multiple if 100 Continue)
        var actualHeaders = lines
        if let first = lines.first, first.starts(with: "HTTP/") {
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }
        
        for line in actualHeaders.dropFirst() {
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                responseHeaders[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: responseHeaders)!
        
        let stream = AsyncStream<Data> { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    process.waitUntilExit()
                    if let tempFile = tempFileURL {
                        try? FileManager.default.removeItem(at: tempFile)
                    }
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        
        return (response, stream)
    }
}
