import Foundation

/// AMEEM v3.0 — ephemeral state ledger and tool-output offloading
/// (Pillar A, Pillar B, G-05, C-06).
///
/// The reference kept only the LAST tool result: on step 4 of a 10-step task,
/// steps 1–3's outputs were gone and only their names survived, so the model
/// re-derived or invented them. That is a direct cause of "the task comes back
/// unfinished". Every observation is retained here — inline below the size
/// limit, otherwise offloaded to scratch with a preview, a byte count, and a
/// retrievable handle.
enum AMEEMLedger {

    /// One retained observation.
    struct Entry: Equatable {
        let index: Int
        let tool: String
        let summary: String
        let handle: String?
    }

    /// Keep small observations inline; offload large ones and return a handle.
    static func offload(_ text: String, tag: String, scratchDir: String = AMEEM.scratchDirectory) -> (preview: String, handle: String?) {
        if text.count <= AMEEM.observationInlineLimit { return (text, nil) }

        let fm = FileManager.default
        try? fm.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)
        let name = "\(tag)_\(Int(Date().timeIntervalSince1970 * 1000)).log"
        let path = (scratchDir as NSString).appendingPathComponent(name)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("[AMEEM] G-05: scratch write failed: \(error)")
            return (String(text.prefix(AMEEM.observationInlineLimit)) + " ... [TRUNCATED]", nil)
        }
        let head = String(text.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(text.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = "\(head)\n... [offloaded \(text.utf8.count) bytes] ...\n\(tail)"
        return (preview, path)
    }

    /// Collect every tool observation, in order, retaining all of them.
    static func entries(from messages: [[String: Any]], scratchDir: String = AMEEM.scratchDirectory) -> [Entry] {
        var result: [Entry] = []
        var counter = 0
        for msg in messages where (msg["role"] as? String) == "tool" {
            counter += 1
            let content = (msg["content"] as? String) ?? ""
            let (preview, handle) = offload(content, tag: "tool_output_\(counter)", scratchDir: scratchDir)
            let tool = (msg["name"] as? String) ?? (msg["tool_call_id"] as? String) ?? "tool"
            result.append(Entry(index: counter, tool: tool, summary: preview, handle: handle))
        }
        return result
    }

    /// Collapse history into a state ledger **without losing observations**.
    static func condenseToLedger(messages: [[String: Any]], scratchDir: String = AMEEM.scratchDirectory) -> [[String: Any]] {
        let systemPrompt = messages.first { ($0["role"] as? String) == "system" }
            .map { ($0["content"] as? String) ?? "" } ?? ""
        let userTurns = messages.filter { ($0["role"] as? String) == "user" }
            .map { ($0["content"] as? String) ?? "" }
        let goal = userTurns.first ?? "Execute the user's instructions."

        let observations = entries(from: messages, scratchDir: scratchDir)

        var lines: [String] = [systemPrompt, "", "--- EXECUTION STATE LEDGER ---",
                               "Root goal: \(goal)",
                               "Observations retained: \(observations.count)"]
        if observations.isEmpty {
            lines.append("No observations yet.")
        } else {
            for entry in observations {
                lines.append("\n[\(entry.index)] \(entry.tool):")
                lines.append(entry.summary)
                if let handle = entry.handle {
                    lines.append("(full output on disk: \(handle))")
                }
            }
        }
        lines.append("\nDirective: emit exactly ONE next tool call. "
            + "Do not restate completed work. Do not describe a result you have not received.")

        return [["role": "user", "content": lines.joined(separator: "\n")]]
    }

    /// G-07: condensation rewrites the first message's role. Several templates
    /// only attach tool definitions when `messages[0]` is a system turn, so the
    /// caller must re-render and confirm every offered tool name still reaches
    /// the prompt before accepting the condensed history.
    static func allToolNamesPresent(_ names: [String], inRenderedPrompt prompt: String) -> Bool {
        names.allSatisfy { prompt.contains($0) }
    }
}
