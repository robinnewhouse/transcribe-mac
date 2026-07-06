import Foundation
import SQLite3
import TranscribeCore

// `transcribe-cli sweep` — the voice-memo exporter.
//
// Reads Apple Voice Memos' CloudRecordings.db *in-process* (via linked
// libsqlite3, no sqlite3 subprocess), transcribes new recordings with
// AssemblyAI, and drops transcript files in an outbox for the Hermes
// capture cron to pick up. It is meant to run as a standalone launchd job
// so that Full Disk Access attaches to this one binary — never to a shell,
// interpreter, or the Hermes gateway.
//
// Never modifies or deletes recordings. Dedupe is by ZUNIQUEID; the cutoff
// is seeded to "now" on first run so the historical backlog is not
// bulk-transcribed (use --backfill N to reach back N days).
//
// Env overrides (for testing): VM_CONTAINER, VM_STATE_DIR.
//
// Exit codes: 0 ok (incl. nothing new), 1 usage/key error,
// 3 container unreadable (Full Disk Access missing), 4 some failed.

// Core Data reference date (2001-01-01 UTC) → Unix epoch offset.
private let coreDataEpochOffset = 978_307_200

private func errln(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

private struct Recording {
    let uid: String
    let epoch: Int
    let title: String
    let path: String
    let duration: Int
}

func runSweep(_ args: [String]) async -> Int32 {
    var backfillDays = 0
    var dryRun = false
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--backfill":
            guard let v = it.next(), let n = Int(v) else {
                errln("Missing or invalid value for --backfill")
                return 1
            }
            backfillDays = n
        case "--dry-run":
            dryRun = true
        default:
            errln("Unknown sweep argument: \(a)")
            return 1
        }
    }

    let env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let container = env["VM_CONTAINER"]
        ?? "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    let stateDir = env["VM_STATE_DIR"] ?? "\(home)/.hermes/voice-memos"
    let dbPath = "\(container)/CloudRecordings.db"
    let cutoffFile = "\(stateDir)/cutoff"
    let processedPath = "\(stateDir)/processed.tsv"
    let outbox = "\(stateDir)/outbox"

    let archive = "\(stateDir)/archive"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outbox, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: processedPath) {
        fm.createFile(atPath: processedPath, contents: Data())
    }

    // Archive already-captured transcripts. The capture cron is terminal-free
    // (no move/delete tool), so it signals a successful Notion capture by
    // writing a "<transcript>.captured" marker via write_file. Moving the
    // captured pair out of the outbox stays here, in trusted compiled code —
    // the untrusted-content-reading agent never deletes anything.
    if let entries = try? fm.contentsOfDirectory(atPath: outbox) {
        for marker in entries where marker.hasSuffix(".captured") {
            let base = String(marker.dropLast(".captured".count))
            for name in [base, marker] where fm.fileExists(atPath: "\(outbox)/\(name)") {
                let dest = "\(archive)/\(name)"
                try? fm.removeItem(atPath: dest)
                try? fm.moveItem(atPath: "\(outbox)/\(name)", toPath: dest)
            }
        }
    }

    // Container readable? This is the Full Disk Access gate.
    if (try? fm.contentsOfDirectory(atPath: container)) == nil {
        errln("ERROR: cannot read the Voice Memos container:")
        errln("  \(container)")
        errln("This binary needs Full Disk Access (System Settings → Privacy & Security"
            + " → Full Disk Access → add transcribe-cli). Do NOT grant it to the Hermes gateway.")
        return 3
    }
    guard fm.fileExists(atPath: dbPath) else {
        errln("ERROR: no CloudRecordings.db in \(container)")
        return 3
    }

    // Query a copy so a mid-write DB never blocks or corrupts the read.
    let tmpDir = "\(NSTemporaryDirectory())vm-sweep-\(ProcessInfo.processInfo.processIdentifier)"
    try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmpDir) }
    let tmpDB = "\(tmpDir)/CloudRecordings.db"
    do {
        for path in [tmpDB, tmpDB + "-wal", tmpDB + "-shm"] where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        try fm.copyItem(atPath: dbPath, toPath: tmpDB)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
            try fm.copyItem(atPath: dbPath + suffix, toPath: tmpDB + suffix)
        }
    } catch {
        errln("ERROR: could not copy CloudRecordings.db: \(error.localizedDescription)")
        return 3
    }

    // First run: seed the cutoff (recordings older than it are never swept).
    if !fm.fileExists(atPath: cutoffFile) {
        let cutoff = Int(Date().timeIntervalSince1970) - backfillDays * 86_400
        try? "\(cutoff)\n".write(toFile: cutoffFile, atomically: true, encoding: .utf8)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        print("First run: cutoff seeded to \(df.string(from: Date(timeIntervalSince1970: TimeInterval(cutoff)))). "
            + "Older recordings will never be swept (use --backfill N to reach back).")
    }
    let cutoff = Int(((try? String(contentsOfFile: cutoffFile, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

    // Open the copy read-only and read everything at/after the cutoff.
    var db: OpaquePointer?
    guard sqlite3_open_v2(tmpDB, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        errln("ERROR: could not open CloudRecordings.db copy: \(String(cString: sqlite3_errmsg(db)))")
        sqlite3_close(db)
        return 3
    }
    defer { sqlite3_close(db) }

    let sql = """
    SELECT ZUNIQUEID, CAST(ZDATE + \(coreDataEpochOffset) AS INT), COALESCE(ZCUSTOMLABEL, ''), \
    ZPATH, CAST(COALESCE(ZDURATION, 0) AS INT) \
    FROM ZCLOUDRECORDING \
    WHERE ZPATH IS NOT NULL AND ZDATE IS NOT NULL AND ZDATE + \(coreDataEpochOffset) >= \(cutoff) \
    ORDER BY ZDATE
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        errln("ERROR: query failed: \(String(cString: sqlite3_errmsg(db)))")
        return 3
    }
    func columnText(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    var recordings: [Recording] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        recordings.append(Recording(
            uid: columnText(0),
            epoch: Int(sqlite3_column_int64(stmt, 1)),
            title: columnText(2),
            path: columnText(3),
            duration: Int(sqlite3_column_int64(stmt, 4))
        ))
    }
    sqlite3_finalize(stmt)

    // Dedupe against already-processed recording IDs (first TSV column).
    var processed = Set<String>()
    if let contents = try? String(contentsOfFile: processedPath, encoding: .utf8) {
        for line in contents.split(separator: "\n") {
            if let first = line.split(separator: "\t", maxSplits: 1).first {
                processed.insert(String(first))
            }
        }
    }

    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"

    let apiKey = env["ASSEMBLYAI_API_KEY"]
        ?? loadKeyFromDotenv(at: "\(home)/.hermes/.env")
        ?? loadKeyFromDotenv()

    var new = 0
    var failed = 0
    for r in recordings where !r.uid.isEmpty {
        if processed.contains(r.uid) { continue }
        let audio = r.path.hasPrefix("/") ? r.path : "\(container)/\(r.path)"
        let label = r.title.isEmpty ? "Untitled" : r.title
        let recorded = df.string(from: Date(timeIntervalSince1970: TimeInterval(r.epoch)))

        if !fm.fileExists(atPath: audio) {
            print("SKIP (audio file missing, likely not synced yet): \(label) [\(r.uid)]")
            continue
        }
        if dryRun {
            print("WOULD TRANSCRIBE: \(label) (\(recorded), \(r.duration)s) [\(r.uid)]")
            new += 1
            continue
        }
        guard let apiKey else {
            errln("No API key. Set ASSEMBLYAI_API_KEY in the environment, ~/.hermes/.env, or ~/.env.")
            return 1
        }

        print("Transcribing: \(label) (\(recorded), \(r.duration)s)…")
        do {
            let client = AssemblyAI(apiKey: apiKey)
            let uploadURL = try await client.upload(file: URL(fileURLWithPath: audio)) { _ in }
            let id = try await client.submit(audioURL: uploadURL)
            let transcript = try await client.poll(id: id)
            let body = formatTranscript(transcript)

            let safeUID = String(r.uid.map {
                ($0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))) ? $0 : "-"
            })
            let out = "\(outbox)/\(r.epoch)-\(safeUID).txt"
            let header = """
            # Voice memo: \(label)
            # Recorded: \(recorded)
            # Duration: \(r.duration)s
            # ID: \(r.uid)


            """
            try (header + body).write(toFile: out, atomically: true, encoding: .utf8)

            let record = "\(r.uid)\t\(r.epoch)\t\(label)\n"
            if let fh = FileHandle(forWritingAtPath: processedPath) {
                fh.seekToEndOfFile()
                fh.write(record.data(using: .utf8)!)
                fh.closeFile()
            }
            new += 1
        } catch {
            errln("FAILED to transcribe: \(label) [\(r.uid)] — will retry next run: \(error.localizedDescription)")
            failed += 1
        }
    }

    if dryRun {
        print("Dry run: \(new) memo(s) would be transcribed.")
    } else if new == 0 && failed == 0 {
        print("No new voice memos.")
    } else {
        print("Done: \(new) transcribed → \(outbox), \(failed) failed.")
    }
    return failed > 0 ? 4 : 0
}
