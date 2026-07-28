import Foundation
import Network

/// Shared TCP relay loop — eliminates duplication between ProxyServer and MITMHandler.
enum NetworkRelay {

    /// Continuously relay data from `source` to `destination`.
    /// Cancels both connections on error, empty data, or completion.
    static func relayLoop(
        source: NWConnection,
        destination: NWConnection,
        on queue: DispatchQueue
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data, !data.isEmpty, error == nil else {
                source.cancel()
                destination.cancel()
                return
            }
            destination.send(content: data, completion: .contentProcessed({ _ in
                NetworkRelay.relayLoop(source: source, destination: destination, on: queue)
            }))
        }
    }
}
