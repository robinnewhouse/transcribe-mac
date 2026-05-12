# Transcribe

A tiny native macOS app: drop a recording in, get a text file with speaker turns out. Uses [AssemblyAI](https://www.assemblyai.com/) for transcription.

That's the whole feature set. No editing, no history, no batch queue. One window, one drop zone.

## Features

- Drop audio/video files onto the window or the Dock icon
- Drag recordings straight from the Voice Memos app
- Output `.txt` lands next to the source file (or in `~/Downloads/` for Voice Memos drags)
- Speaker-labeled transcripts (`Speaker A:` / `Speaker B:` blocks)
- Reads `ASSEMBLYAI_API_KEY` from `~/.env`, or paste it once in the in-app sheet

## Build

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```
./build.sh
```

Produces `Transcribe.app` in the project root. Drag it to `/Applications`.

On first launch macOS Gatekeeper will warn that the app is unsigned — right-click → Open → "Open anyway."

## API key

Get one at [assemblyai.com/dashboard/api-keys](https://www.assemblyai.com/dashboard/api-keys). Then either:

- Add `ASSEMBLYAI_API_KEY=your_key` to `~/.env`, or
- Click "Set API Key…" in the app and paste it.
