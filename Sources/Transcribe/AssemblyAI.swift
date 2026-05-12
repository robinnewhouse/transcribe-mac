import Foundation

enum AAIError: LocalizedError {
    case http(Int, String)
    case decode
    case transcript(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if code == 401 { return "Invalid API key." }
            return "HTTP \(code): \(body)"
        case .decode: return "Could not decode response."
        case .transcript(let msg): return "Transcription failed: \(msg)"
        }
    }
}

struct AssemblyAI {
    let apiKey: String
    private let base = URL(string: "https://api.assemblyai.com")!

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return r
    }

    func upload(file: URL, progress: @escaping (Double) -> Void) async throws -> String {
        var r = request("/v2/upload", method: "POST")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgress(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (data, resp) = try await session.upload(for: r, fromFile: file)
        guard let http = resp as? HTTPURLResponse else { throw AAIError.decode }
        guard (200..<300).contains(http.statusCode) else {
            throw AAIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct UploadResp: Decodable { let upload_url: String }
        guard let parsed = try? JSONDecoder().decode(UploadResp.self, from: data) else {
            throw AAIError.decode
        }
        return parsed.upload_url
    }

    func submit(audioURL: String) async throws -> String {
        var r = request("/v2/transcript", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": ["universal-3-pro", "universal-2"],
            "speaker_labels": true,
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw AAIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct SubmitResp: Decodable { let id: String }
        guard let parsed = try? JSONDecoder().decode(SubmitResp.self, from: data) else {
            throw AAIError.decode
        }
        return parsed.id
    }

    struct Utterance: Decodable {
        let speaker: String
        let text: String
    }
    struct Transcript: Decodable {
        let status: String
        let text: String?
        let error: String?
        let utterances: [Utterance]?
    }

    func poll(id: String) async throws -> Transcript {
        let r = request("/v2/transcript/\(id)", method: "GET")
        while true {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                throw AAIError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let t = try JSONDecoder().decode(Transcript.self, from: data)
            switch t.status {
            case "completed": return t
            case "error": throw AAIError.transcript(t.error ?? "unknown")
            default: try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let frac = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { self.progress(frac) }
    }
}

func formatTranscript(_ t: AssemblyAI.Transcript) -> String {
    if let utterances = t.utterances, !utterances.isEmpty {
        return utterances.map { "Speaker \($0.speaker):\n\($0.text)" }
                         .joined(separator: "\n\n") + "\n"
    }
    return (t.text ?? "") + "\n"
}

func loadKeyFromDotenv() -> String? {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".env")
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard key == "ASSEMBLYAI_API_KEY" else { continue }
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    return nil
}

func outputURL(for source: URL) -> URL {
    let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let sourceDir = source.deletingLastPathComponent().resolvingSymlinksInPath().path
    let dir: URL
    if sourceDir.hasPrefix(tmp) {
        dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? source.deletingLastPathComponent()
    } else {
        dir = source.deletingLastPathComponent()
    }
    // Strip the "UUID-" prefix we add when copying drag-promise files.
    var base = source.deletingPathExtension().lastPathComponent
    if let dash = base.firstIndex(of: "-"),
       UUID(uuidString: String(base[..<dash])) != nil {
        base = String(base[base.index(after: dash)...])
    }
    var candidate = dir.appendingPathComponent("\(base).txt")
    var n = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base) (\(n)).txt")
        n += 1
    }
    return candidate
}
