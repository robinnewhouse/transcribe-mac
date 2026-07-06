import Foundation
import TranscribeCore

// transcribe-cli — headless companion to the Transcribe app.
// Same AssemblyAI pipeline (speaker labels included), no window.

let usage = """
usage: transcribe-cli <audio-file> [-o <output-file>] [--quiet]
       transcribe-cli sweep [--backfill DAYS] [--dry-run]

Transcribes an audio/video file with AssemblyAI and prints the
speaker-labeled transcript to stdout (or writes it to -o).

The `sweep` subcommand is the voice-memo exporter: it reads Apple Voice
Memos in-process, transcribes new recordings, and writes them to
~/.hermes/voice-memos/outbox for the Hermes capture cron. Run it as a
standalone launchd job so Full Disk Access attaches to this binary alone.

API key resolution order:
  1. $ASSEMBLYAI_API_KEY
  2. ~/.hermes/.env
  3. ~/.env

Exit codes: 0 success, 1 usage/key error, 2 transcription error,
3 Voice Memos container unreadable (needs Full Disk Access), 4 some failed.
"""

func stderrLine(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

// Subcommand dispatch: `transcribe-cli sweep …`
let topArgs = Array(CommandLine.arguments.dropFirst())
if topArgs.first == "sweep" {
    let code = await runSweep(Array(topArgs.dropFirst()))
    exit(code)
}

var inputPath: String?
var outputPath: String?
var quiet = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "-o", "--output":
        guard let value = argIterator.next() else {
            stderrLine("Missing value for \(arg)")
            exit(1)
        }
        outputPath = value
    case "-q", "--quiet":
        quiet = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        guard inputPath == nil else {
            stderrLine("Unexpected argument: \(arg)")
            exit(1)
        }
        inputPath = arg
    }
}

guard let inputPath else {
    stderrLine(usage)
    exit(1)
}
let file = URL(fileURLWithPath: inputPath)
guard FileManager.default.fileExists(atPath: file.path) else {
    stderrLine("No such file: \(file.path)")
    exit(1)
}

let hermesDotenv = (NSHomeDirectory() as NSString).appendingPathComponent(".hermes/.env")
guard let apiKey = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"]
    ?? loadKeyFromDotenv(at: hermesDotenv)
    ?? loadKeyFromDotenv() else {
    stderrLine("No API key. Set ASSEMBLYAI_API_KEY in the environment, ~/.hermes/.env, or ~/.env.")
    exit(1)
}

let client = AssemblyAI(apiKey: apiKey)
do {
    let uploadURL = try await client.upload(file: file) { frac in
        if !quiet {
            FileHandle.standardError.write("\rUploading… \(Int(frac * 100))%".data(using: .utf8)!)
        }
    }
    if !quiet { stderrLine("\rUploaded.          ") }
    let id = try await client.submit(audioURL: uploadURL)
    if !quiet { stderrLine("Transcribing (id \(id))…") }
    let transcript = try await client.poll(id: id)
    let text = formatTranscript(transcript)
    if let outputPath {
        try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        if !quiet { stderrLine("Saved \(outputPath)") }
    } else {
        print(text, terminator: "")
    }
} catch {
    stderrLine("Error: \(error.localizedDescription)")
    exit(2)
}
