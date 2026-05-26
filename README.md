# ZenithOS

Menu bar app for the ZenithOS local environment. Runs once at login, lives in the menu bar. Features are registered as plugins — add new ones to `AppDelegate.features`.

**Current features:**
- FaceTime Capture — records and transcribes FaceTime calls, writes to `hub/capture/transcripts/`

---

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ **or** Swift 5.9 toolchain (Xcode Command Line Tools)
- Microphone permission
- Screen Recording permission (for FaceTime audio via ScreenCaptureKit)
- Speech Recognition permission

---

## Build & Run

### Option A — Swift CLI (no full Xcode needed)

```bash
cd /Users/bananawalnut/hub/repos/workspace/ZenithOS
swift build -c release
.build/release/ZenithOS
```

The app will appear in your menu bar with a waveform icon. No dock icon.

### Option B — Xcode project (recommended for development)

```bash
# Install xcodegen once
brew install xcodegen

# Generate the .xcodeproj from project.yml
xcodegen generate

# Open in Xcode
open ZenithOS.xcodeproj
```

Then build and run with ⌘R. The scheme is pre-configured to launch the menu bar app.

### Option C — Launch at login (once you're happy with it)

```bash
# Build release binary
swift build -c release

# Copy to Applications
cp -r .build/release/ZenithOS /Applications/ZenithOS

# Add to Login Items
# System Settings → General → Login Items → (+) → /Applications/ZenithOS
```

---

## First Run — Permissions

On first launch macOS will prompt for three permissions:
1. **Microphone** — for capturing your voice
2. **Screen Recording** — for capturing FaceTime's audio via ScreenCaptureKit
3. **Speech Recognition** — for live transcription

All three must be granted. If you accidentally deny one:
> System Settings → Privacy & Security → [Microphone / Screen Recording / Speech Recognition] → enable ZenithOS

---

## FaceTime Capture — Usage

1. Start a FaceTime call
2. Click the menu bar waveform icon → **▶ Start Recording**
3. The status line updates to "Recording…"
4. End the call → click **■ Stop Recording**
5. The app transcribes and writes to:
   ```
   hub/capture/transcripts/facetime-YYYY-MM-DD-HHMM.md
   ```
6. During your next vault session, `/extract` will pick it up from the capture inbox

**Transcript format:**
```
**You** `00:03` Hey, did you get my message?
**Remote** `00:07` Yeah just now — let me pull it up.
```

---

## Architecture

```
ZenithOS/
├── Package.swift
├── Sources/ZenithOS/
│   ├── main.swift                        entry point, no dock icon
│   ├── AppDelegate.swift                 menu bar + feature registry
│   ├── Shared/
│   │   └── VaultConfig.swift             hub root + capture paths
│   └── Features/
│       └── FaceTimeCapture/
│           ├── FaceTimeCaptureFeature.swift    ZenithFeature impl, menu items
│           ├── FaceTimeCaptureManager.swift    ScreenCaptureKit + AVAudioEngine
│           ├── SpeechTranscriber.swift         SFSpeechRecognizer wrapper
│           └── TranscriptWriter.swift          vault markdown output
```

### Adding a new feature

1. Create `Sources/ZenithOS/Features/YourFeature/YourFeature.swift`
2. Conform to `ZenithFeature`
3. Add to `AppDelegate.features`:
   ```swift
   private lazy var features: [ZenithFeature] = [
       FaceTimeCaptureFeature(),
       YourFeature(),          // ← add here
   ]
   ```

---

## Vault integration

Transcripts land in `capture/transcripts/` with `status: unprocessed`. The `/extract` skill
treats this directory as a typed inbox — run it during your next session to pull insights,
decisions, and action items from call content into the note graph.

Frontmatter fields:
- `type: transcript`
- `participants.you` / `participants.remote` — speaker labels
- `status: unprocessed` → set to `processed` after `/extract`
