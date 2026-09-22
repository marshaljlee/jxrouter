import SwiftUI
import AppKit

/// Finds and downloads a missing multimodal projector from the Hugging Face Hub.
///
/// Self-contained because `SettingsView`'s layout helpers are file-private.
struct MMProjSearchSheet: View {
    let modelPath: String
    let architecture: String
    let quantization: String
    /// Receives the absolute path of the downloaded projector.
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [MMProjCandidate] = []
    @State private var isSearching = true
    @State private var errorText: String?
    @State private var activeCandidate: MMProjCandidate?
    @State private var progress: MMProjDownloadProgress?

    private var modelFile: String { (modelPath as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Color.dsAccent)
                Text("Find a Multimodal Projector")
                    .font(.system(size: DesignToken.subheadSize, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
            }

            Text("Searching Hugging Face for an mmproj matching \(modelFile)"
                 + (architecture.isEmpty ? "" : " (\(architecture))"))
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Querying huggingface.co…")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
            } else if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.orange)
                    Text("You can still browse for a file manually with Choose File…")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if candidates.isEmpty {
                Text("No projector found for this model.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
            } else {
                Text("\(candidates.count) candidate\(candidates.count == 1 ? "" : "s"), best match first.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(candidates) { c in
                            candidateRow(c)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Spacer()
        }
        .padding(DesignToken.spacing20)
        .frame(width: 520, height: 420)
        .task { await search() }
    }

    // MARK: - Rows

    private func candidateRow(_ c: MMProjCandidate) -> some View {
        let isActive = activeCandidate?.id == c.id
        return HStack(spacing: DesignToken.spacing8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.file)
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(c.repo) · \(c.sizeText)")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isActive, let p = progress, p.total > 0 {
                    ProgressView(value: p.percent, total: 100)
                    Text(String(format: "%.0f%% · %.1f MB/s",
                                p.percent, Double(p.speedBps) / 1_048_576))
                        .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            Spacer()
            if isActive {
                ProgressView().controlSize(.small)
            } else {
                Button("Download") { Task { await download(c) } }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.dsAccent : Color.dsBorder, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func search() async {
        isSearching = true
        errorText = nil
        let found = await MMProjProvisioner.shared.findMMProj(
            modelFile: modelFile, arch: architecture, quant: quantization)
        await MainActor.run {
            candidates = found
            isSearching = false
        }
    }

    private func download(_ c: MMProjCandidate) async {
        activeCandidate = c
        progress = nil
        // Store next to the model so the scanner picks it up automatically.
        let destDir = (modelPath as NSString).deletingLastPathComponent
        do {
            let final = try await MMProjProvisioner.shared.download(
                from: c.url, destDir: destDir, destName: c.file, expectedSHA: c.sha256
            ) { p in
                Task { @MainActor in self.progress = p }
            }
            await MainActor.run {
                onPick(final)
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                activeCandidate = nil
                progress = nil
            }
        }
    }
}
