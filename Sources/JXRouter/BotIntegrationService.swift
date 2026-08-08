import Foundation

/// Placeholder service for future Discord/Telegram bot integration and voice transcription.
@MainActor
@Observable
final class BotIntegrationService {
    
    var isEnabled: Bool = false
    var botPlatform: BotPlatform = .telegram
    var botToken: String = ""
    private var isPolling = false
    private var lastUpdateId: Int = 0
    private var pollingTask: Task<Void, Never>?
    
    enum BotPlatform: String, Codable {
        case discord
        case telegram
    }
    
    init() {}
    
    /// Starts the listener for the configured bot platform.
    func startListener() {
        self.isEnabled = ConfigManager.shared.botIntegrationEnabled
        self.botToken = ConfigManager.shared.getApiKey(chainKey: ConfigManager.KeychainKey.telegramBotToken)
        guard isEnabled, !botToken.isEmpty, botPlatform == .telegram else { return }
        
        isPolling = true
        print("[BotIntegration] Starting \(botPlatform.rawValue) bot listener...")
        
        // Ensure FIFO exists for terminal injection
        createFIFO()
        
        pollingTask = Task {
            while isPolling && !Task.isCancelled {
                do {
                    try await pollTelegram()
                } catch {
                    print("[BotIntegration] Polling error: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 sec poll
            }
        }
    }
    
    func stopListener() {
        print("[BotIntegration] Stopping \(botPlatform.rawValue) bot listener...")
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    private func pollTelegram() async throws {
        let urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateId + 1)&timeout=10"
        guard let url = URL(string: urlStr) else { return }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Basic JSON parsing
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let results = json["result"] as? [[String: Any]] else {
            return
        }
        
        for result in results {
            if let updateId = result["update_id"] as? Int {
                self.lastUpdateId = max(self.lastUpdateId, updateId)
            }
            
            if let message = result["message"] as? [String: Any] {
                let chatId = (message["chat"] as? [String: Any])?["id"] as? Int
                
                // Handle text
                if let text = message["text"] as? String {
                    try await forwardToAgent(command: text)
                    if let cid = chatId { try await sendTelegramReply(chatId: cid, text: "✅ Command forwarded to agent.") }
                }
                // Handle voice note
                else if let voice = message["voice"] as? [String: Any], let fileId = voice["file_id"] as? String {
                    if let cid = chatId { try await sendTelegramReply(chatId: cid, text: "🎙️ Transcribing voice note...") }
                    let transcript = try await transcribeTelegramVoice(fileId: fileId)
                    try await forwardToAgent(command: transcript)
                    if let cid = chatId { try await sendTelegramReply(chatId: cid, text: "✅ Transcribed and forwarded: \"\(transcript)\"") }
                }
            }
        }
    }
    
    private func sendTelegramReply(chatId: Int, text: String) async throws {
        let urlStr = "https://api.telegram.org/bot\(botToken)/sendMessage"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["chat_id": chatId, "text": text] as [String : Any]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _ = try await URLSession.shared.data(for: req)
    }
    
    private func transcribeTelegramVoice(fileId: String) async throws -> String {
        // Get file path
        let fileUrlStr = "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(fileId)"
        guard let fileUrl = URL(string: fileUrlStr) else { return "" }
        let (fData, _) = try await URLSession.shared.data(from: fileUrl)
        
        guard let fJson = try JSONSerialization.jsonObject(with: fData) as? [String: Any],
              let fResult = fJson["result"] as? [String: Any],
              let filePath = fResult["file_path"] as? String else { return "" }
        
        let downloadUrlStr = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadUrl = URL(string: downloadUrlStr) else { return "" }
        let (audioData, _) = try await URLSession.shared.data(from: downloadUrl)
        
        return try await transcribeAudio(audioData: audioData)
    }
    
    /// Transcribes audio using NVIDIA NIM Whisper API
    func transcribeAudio(audioData: Data) async throws -> String {
        print("[BotIntegration] Transcribing audio via NVIDIA Whisper...")
        let apiKey = ConfigManager.shared.getApiKey(chainKey: ConfigManager.KeychainKey.nvidia)
        guard !apiKey.isEmpty else { return "[Error: Missing NVIDIA API Key for transcription]" }
        
        let url = URL(string: "https://integrate.api.nvidia.com/v1/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.ogg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/ogg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("nvidia/parakeet-rnnt-1.1b\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        req.httpBody = body
        
        let (respData, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return "[Transcription failed]"
    }
    
    private let fifoPath = NSString(string: "~/.jxproxy_bot_commands").expandingTildeInPath
    
    private func createFIFO() {
        if !FileManager.default.fileExists(atPath: fifoPath) {
            mkfifo(fifoPath, 0o600)
        }
    }
    
    /// Forward a command to a specific coding agent via named pipe (FIFO).
    func forwardToAgent(command: String) async throws {
        print("[BotIntegration] Forwarding command to agent FIFO: \(command)")
        DispatchQueue.global().async {
            // Write to FIFO without blocking forever if no reader exists
            let fd = open((self.fifoPath as NSString).fileSystemRepresentation, O_WRONLY | O_NONBLOCK)
            if fd != -1 {
                if let data = "\(command)\n".data(using: .utf8) {
                    _ = data.withUnsafeBytes { ptr in
                        write(fd, ptr.baseAddress, data.count)
                    }
                }
                close(fd)
            } else {
                print("[BotIntegration] Could not open FIFO for writing. Make sure a terminal is tailing it.")
            }
        }
    }
}
