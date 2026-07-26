import Foundation

final class DirectDNSResolver {
    static let shared = DirectDNSResolver()
    
    private var cache: [String: String] = [:]
    
    func resolve(_ hostname: String) async -> String? {
        if let cached = cache[hostname] { return cached }
        
        let url = URL(string: "https://cloudflare-dns.com/dns-query?name=\(hostname)&type=A")!
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = json["Answer"] as? [[String: Any]] else {
                return nil
            }
            
            for record in answer {
                if let type = record["type"] as? Int, type == 1, let data = record["data"] as? String {
                    cache[hostname] = data
                    return data
                }
            }
        } catch {
            print("[DirectDNSResolver] Failed to resolve \(hostname): \(error)")
        }
        return nil
    }
}
