# LiveSubs

Live English subtitles for Hebrew speech playing on a Mac: YouTube, Israeli TV sites, video
files, anything with sound. Subtitles float over everything, including full-screen video.

- Lives in the menu bar (speech-bubble icon). It opens by itself when the Mac starts.
- Subtitles are **off** until you turn them on: click the icon → **Turn Subtitles On**, or
  press **⌥⌘S** (Option-Command-S) anywhere. Press it again to turn them off.
- When on, subtitles appear while someone speaks and fade away in silence.
- Menu extras: Also Show Hebrew, Bigger/Smaller Text, Move Subtitles…, Setup….

Speech recognition and translation are done by [Soniox](https://soniox.com) (about $0.12 per hour
of sound, list price). Sound is only sent while subtitles are on **and** the Mac is playing
something; silence costs nothing.

Requires macOS 13 (Ventura) or newer, on Intel or Apple Silicon.

---

## One-time setup (about 10 minutes, do it together)

### 1. Soniox account and key (the friend's own)

1. Go to [console.soniox.com](https://console.soniox.com) and sign up.
2. Add a small balance (e.g. $10, which is many hours of video).
3. **Set a spending limit**: Organization → Limits → set a monthly usage limit (e.g. $10).
   Above it Soniox simply stops; nothing surprising on the bill.
4. Create an API key (API keys → Create) and keep the page open to copy it in step 3.

### 2. Install the app

1. Download `LiveSubs-x.y.z.zip` from the Releases page and double-click it to unzip.
2. Drag **LiveSubs** into the **Applications** folder.
3. Open it from Applications. macOS will refuse the first time ("can't be opened" / "Apple could
   not verify…"), because the app isn't from the App Store:
   - **macOS 15 Sequoia or newer:** click Done, open **System Settings → Privacy & Security**,
     scroll down to "LiveSubs was blocked…", click **Open Anyway**, then enter the Mac's password.
   - **macOS 13–14:** right-click (or Control-click) LiveSubs → **Open** → **Open**.

   This only happens once.

### 3. The setup window

The setup window opens automatically:

1. Paste the Soniox key and click **Save**. It's checked right away.
2. Click **Allow…** and switch on **LiveSubs** under *Screen & System Audio Recording* (called
   *Screen Recording* on older macOS). If macOS offers **Quit & Reopen**, click it. LiveSubs
   only listens to the sound; it never records or stores the screen.
3. Click **Done**. From now on LiveSubs opens by itself at login.

Test it: play a Hebrew YouTube video, press ⌥⌘S, and English subtitles appear at the bottom.

## If something goes wrong

The subtitle area shows one plain sentence when there's a problem:

| Message | What to do |
|---|---|
| "Your Soniox key isn't working" | Menu → Setup… → paste the key again (or create a new one). |
| "Your Soniox balance or monthly limit has run out" | Add balance / raise the limit at console.soniox.com, then turn subtitles on again. |
| "LiveSubs can't hear your Mac's sound" | Menu → Setup… → Allow…, and make sure LiveSubs is switched on in System Settings. |
| "No internet connection" | Nothing; subtitles come back by themselves once online. |

Subtitles in the wrong place? Menu → **Move Subtitles…**, drag, click Done.

---

## For the developer

```
SubsCore/            Foundation-only logic, tested on Linux: Soniox messages, subtitle
                     assembly (rolling two lines, fade, settled/pending), silence gate,
                     resampling, error → plain-sentence mapping
App/Sources/LiveSubs Mac app (AppKit + SwiftUI): ScreenCaptureKit sound capture, Soniox
                     WebSocket session, overlay panel, menu bar, ⌥⌘S hot key, setup window
spike/               Step 0: stream a Hebrew clip to Soniox and print the English (stdlib Python)
scripts/             bundle-app.sh (macOS: universal .app + zip), make-signing-cert.sh
.github/workflows/   build.yml: builds and signs on macOS; a v* tag publishes a Release
```

- **Core tests (Linux):** `cd SubsCore && swift test`
- **Compile check of the Mac app on Linux** (uses the Darwin SDK installed for xtool):
  `swift build -c release --swift-sdk x86_64-apple-macosx --build-system native`.
  This only checks that it compiles. lld's macOS linking is unsupported, so builds for the Mac
  always come from GitHub Actions (Apple's toolchain).
- **Accuracy check:** `export SONIOX_API_KEY=…; python3 -I spike/soniox_stream.py clip.wav --hebrew`
- **Signing:** run `scripts/make-signing-cert.sh` once. It creates a self-signed certificate
  (in `signing/`, git-ignored; back it up) and stores it as GitHub secrets. Every build then
  has the same signature, so macOS keeps the permission across updates. Without it, builds are
  ad-hoc signed and the permission must be granted again after each update.
- **Release:** `git tag v0.1.0 && git push --tags` → GitHub Release with the zip.
- The API key is never in the code or the repo: the friend pastes their own; it's stored in
  `~/Library/Application Support/LiveSubs/soniox-key` (mode 600).
