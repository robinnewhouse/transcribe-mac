import SwiftUI
import TranscribeCore
import UniformTypeIdentifiers

let docsURL = URL(string: "https://www.assemblyai.com/dashboard/api-keys")!

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let didOpenURLs = Notification.Name("TranscribeDidOpenURLs")
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: Self.didOpenURLs, object: urls)
    }
}

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Transcribe") {
            ContentView()
                .frame(minWidth: 480, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}

enum Status: Equatable {
    case idle
    case uploading(Double)
    case transcribing
    case done(URL)
    case error(String)

    var text: String {
        switch self {
        case .idle: return "Drop a recording here"
        case .uploading(let f): return "Uploading… \(Int(f * 100))%"
        case .transcribing: return "Transcribing…"
        case .done(let url): return "Saved \(url.lastPathComponent)"
        case .error(let msg): return msg
        }
    }
}

struct ContentView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @State private var status: Status = .idle
    @State private var showingKey = false
    @State private var isTargeted = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                Text(status.text)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL, .audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie],
                    isTargeted: $isTargeted, perform: handleDrop)
            .onTapGesture(perform: pickFile)

            HStack {
                Button("Set API Key…") { showingKey = true }
                Button {
                    NSWorkspace.shared.open(docsURL)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Get an AssemblyAI API key")
                Spacer()
                if case .done(let url) = status {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showingKey) { APIKeySheet(apiKey: $apiKey) }
        .onAppear {
            if apiKey.isEmpty, let fromEnv = loadKeyFromDotenv() {
                apiKey = fromEnv
            }
            if apiKey.isEmpty { showingKey = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.didOpenURLs)) { note in
            if let urls = note.object as? [URL], let first = urls.first {
                transcribe(url: first)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        let candidates = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.mpeg4Audio.identifier,
            UTType.mp3.identifier,
            UTType.wav.identifier,
            UTType.aiff.identifier,
            UTType.movie.identifier,
        ]
        guard let typeID = candidates.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return false
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
            guard let url else { return }
            // loadFileRepresentation deletes the temp file when this closure
            // returns, so copy it somewhere we control first.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                return
            }
            DispatchQueue.main.async { transcribe(url: dest) }
        }
        return true
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK, let url = panel.url {
            transcribe(url: url)
        }
    }

    private func transcribe(url: URL) {
        guard !apiKey.isEmpty else {
            status = .error("Set your API key first.")
            showingKey = true
            return
        }
        resetTask?.cancel()
        let client = AssemblyAI(apiKey: apiKey)
        status = .uploading(0)
        Task {
            do {
                let uploadURL = try await client.upload(file: url) { frac in
                    status = .uploading(frac)
                }
                await MainActor.run { status = .transcribing }
                let id = try await client.submit(audioURL: uploadURL)
                let transcript = try await client.poll(id: id)
                let out = outputURL(for: url)
                try formatTranscript(transcript).write(to: out, atomically: true, encoding: .utf8)
                await MainActor.run {
                    status = .done(out)
                    NSWorkspace.shared.open(out)
                    scheduleReset()
                }
            } catch {
                await MainActor.run {
                    status = .error(error.localizedDescription)
                    scheduleReset(after: 8)
                }
            }
        }
    }

    private func scheduleReset(after seconds: UInt64 = 5) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { status = .idle }
            }
        }
    }
}

struct APIKeySheet: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AssemblyAI API Key").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(docsURL)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Open assemblyai.com to get a key")
            }
            Text("Get one at assemblyai.com/dashboard/api-keys")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Paste key", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    apiKey = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { draft = apiKey }
    }
}
