import Foundation

@MainActor
@Observable
final class SystemProxyManager {
    private let processQueue = DispatchQueue(label: "com.jxrouter.systemproxy", qos: .utility)

    var isEnabled = false
    var proxyPort: UInt16 = 5255
    var proxyAddress = "127.0.0.1"
    var availableInterfaces: [NetworkInterface] = []
    var selectedInterface: String = ""

    struct NetworkInterface: Identifiable, Hashable {
        let id: String
        let name: String
        let displayName: String
    }

    func discoverInterfaces() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallnetworkservices"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let lines = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "An asterisk (*) denotes that a network service is disabled." }

            availableInterfaces = lines.map { name in
                NetworkInterface(
                    id: name,
                    name: name,
                    displayName: name
                )
            }

            if selectedInterface.isEmpty, let first = availableInterfaces.first {
                selectedInterface = first.id
            }
        } catch {
            print("Failed to discover network interfaces: \(error)")
        }
    }

    func enable() {
        guard !selectedInterface.isEmpty else { return }
        runNetworksetup(arguments: [
            "-setwebproxy", selectedInterface, proxyAddress, "\(proxyPort)",
        ])
        runNetworksetup(arguments: [
            "-setwebproxystate", selectedInterface, "on",
        ])
        runNetworksetup(arguments: [
            "-setsecurewebproxy", selectedInterface, proxyAddress, "\(proxyPort)",
        ])
        runNetworksetup(arguments: [
            "-setsecurewebproxystate", selectedInterface, "on",
        ])
        isEnabled = true
    }

    func disable() {
        guard !selectedInterface.isEmpty else { return }
        runNetworksetup(arguments: [
            "-setwebproxystate", selectedInterface, "off",
        ])
        runNetworksetup(arguments: [
            "-setsecurewebproxystate", selectedInterface, "off",
        ])
        isEnabled = false
    }

    func queryState() {
        guard !selectedInterface.isEmpty else { return }
        let web = getProxyState(arguments: ["-getwebproxy", selectedInterface])
        let secure = getProxyState(arguments: ["-getsecurewebproxy", selectedInterface])
        isEnabled = web || secure
    }

    private func runNetworksetup(arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("networksetup command failed: \(error)")
        }
    }

    private func getProxyState(arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("Enabled: Yes")
        } catch {
            return false
        }
    }
}
