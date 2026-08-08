import Foundation

@MainActor
@Observable
final class SystemProxyManager {
    private let processQueue = DispatchQueue(label: "com.jxproxy.systemproxy", qos: .utility)

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
                // Disabled services come back as "*ServiceName" — networksetup
                // commands expect the name without the leading asterisk.
                let clean = name.hasPrefix("*") ? String(name.dropFirst()) : name
                return NetworkInterface(
                    id: clean,
                    name: clean,
                    displayName: clean
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
        if selectedInterface.isEmpty { discoverInterfaces() }
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

    /// Turn the proxy OFF on every network service, not just the selected one.
    /// A stale proxy on ANY interface routes that interface's traffic to a dead
    /// port and kills internet for every app on it — this is the #1 cause of
    /// "no internet after JXProxy quits". Used on termination, launch sweep,
    /// and stop.
    func disable() {
        discoverInterfaces()
        for iface in allInterfaceIds() {
            runNetworksetup(arguments: [
                "-setwebproxystate", iface, "off",
            ])
            runNetworksetup(arguments: [
                "-setsecurewebproxystate", iface, "off",
            ])
        }
        isEnabled = false
    }

    /// Whether the proxy is enabled on ANY network service.
    func queryState() {
        discoverInterfaces()
        var anyEnabled = false
        for iface in allInterfaceIds() {
            let web = getProxyState(arguments: ["-getwebproxy", iface])
            let secure = getProxyState(arguments: ["-getsecurewebproxy", iface])
            if web || secure { anyEnabled = true }
        }
        isEnabled = anyEnabled
    }

    /// All interface ids to operate on — every discovered service plus the
    /// selected one (in case discovery races a selection change).
    private func allInterfaceIds() -> [String] {
        var ids = availableInterfaces.map(\.id)
        if !selectedInterface.isEmpty, !ids.contains(selectedInterface) {
            ids.append(selectedInterface)
        }
        return ids
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
