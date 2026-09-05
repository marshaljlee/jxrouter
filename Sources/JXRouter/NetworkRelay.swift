import Foundation
import Network

struct NetworkRelay {
    static func relayLoop(source: NWConnection, destination: NWConnection, on queue: DispatchQueue) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in
                    relayLoop(source: source, destination: destination, on: queue)
                })
            } else {
                source.cancel()
                destination.cancel()
            }
        }
    }
}
