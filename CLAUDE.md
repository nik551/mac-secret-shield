# SecretShield (working name) — Project Brief for Claude Code

## What we're building
A native macOS menu bar app that protects secrets (API keys, tokens, `.env` values, passwords) on the
user's screen during work-call screen shares (Zoom, Meet, Teams, Slack huddles).

The app captures the screen, detects secrets, covers them with solid redaction blocks, and shows the
result in a "sanitized" mirror window. The user shares THAT window in Zoom instead of their real screen.
The user always sees their real screen; only viewers see redactions.

Positioning: one automatic safety net for the whole screen (terminal, editor, browser, Postman), with no
change to the user's terminal or workflow. Terminals get the deepest testing first.

The developer (Nikhil) is a Node/TypeScript backend engineer and new to Swift. Briefly explain
Swift/macOS concepts when introducing them.

## Non-negotiable rules
1. **Fail closed.** No frame is ever shown in the shared window until it has been checked. Any region that
   changed and hasn't been scanned yet goes out redacted. Detecting late is fine; forwarding an unchecked
   frame is a bug.
2. **Delay buffer.** Frames are held ~150–300 ms so detection finishes before a frame is released.
3. **Solid blocks, not blur.** Redactions are opaque rectangles, padded a few pixels. Blur can be reversed.
4. **100% on-device.** No networking, analytics, telemetry or crash reporting that could include screen
   content. Never log, persist or transmit frame contents or detected secret values.
5. **Exclude our own windows from capture** (avoid an infinite mirror). Usually exclude the Zoom/Meet
   window too.
6. **No LLM/AI detection.** Use predictable, testable pattern matching.

## Stack
- Swift 6, SwiftUI + AppKit (menu bar, windows), macOS 14+, Apple Silicon
- ScreenCaptureKit for capture (no private/undocumented APIs)
- Vision framework (`VNRecognizeTextRequest`) for on-device OCR
- Metal or Core Image for drawing redaction blocks on the GPU
- Distribution later: direct download (not Mac App Store), signed + notarized, Sparkle for updates
- Use one consistent Apple Development signing identity so Screen Recording permission doesn't reset
  on every build

## Architecture
```
CaptureService (ScreenCaptureKit, 30 fps, excludes own windows)
  → DelayBuffer (holds frames until checked)
  → FrameProcessor
       ├─ WindowMap (which app owns each region, front-to-back order)
       ├─ ChangeDetector (only scan regions that changed)
       ├─ OCR (Vision, tiled, parallel)
       └─ SecretDetector (scores matches)
  → Redactor (solid blocks on GPU)
  → MirrorWindow ("SecretShield – Share this window")
```
Keep these as separate types behind protocols so each stage can be tested alone.

## App awareness (WindowMap)
- Build a map of visible windows: owning app bundle ID, title, frame, display, front-to-back order.
  Refresh on window events, not every frame.
- Each OCR text box belongs to the topmost window containing it.
- Per-app profiles:
  - Terminals (Terminal, iTerm, Warp, Ghostty, VS Code terminal): strictest; raise sensitivity after
    `env`, `printenv`, `cat .env`, `docker inspect`, `kubectl get secret`
  - Editors (VS Code, Cursor, Xcode, JetBrains): title contains `.env`, `*.pem`, `credentials` → redact
    whole editor area; otherwise patterns
  - Browsers: tab title / URL rules for known key pages (AWS IAM, OpenAI keys)
  - Password managers (1Password, Keychain Access): always redact whole window
  - Everything else: default rules

## Detection logic (score ≥ 60 → redact; when unsure, redact)
| Layer | Check | Score |
|---|---|---|
| 1. Window context | Sensitive file names in titles, password manager apps | +100 (whole area) |
| 2. Known key formats | Service patterns below | +90 |
| 3. KEY=value context | Left side contains KEY, SECRET, TOKEN, PASSWORD, PASS, PWD, AUTH, CREDENTIAL, PRIVATE | +50 |
| 4. Randomness | ≥20 chars, no spaces, Shannon entropy > ~4.0 | +40 |
| 5. User fingerprints (opt-in, later) | Hash of on-screen text matches hash of user's own `.env` values | +100 |
| Allowlist | Placeholders, test keys, user-allowed strings | score = 0 |

Randomness alone never redacts; randomness next to a keyword does.

Service patterns (reuse/adapt rules from Gitleaks/TruffleHog; keep them in a data file, not hardcoded
logic): OpenAI `sk-`/`sk-proj-`, Anthropic `sk-ant-`, AWS `AKIA` + 16, Google `AIza` + 35, GCP service
account JSON, Azure `AccountKey=`, GitHub `ghp_`/`gho_`/`github_pat_`, GitLab `glpat-`, Slack `xoxb-`/
`xoxp-`, Stripe `sk_live_`/`rk_live_`, Razorpay `rzp_live_`, npm `npm_`, PyPI `pypi-`, Hugging Face
`hf_`, SendGrid `SG.`, Twilio `AC`/`SK` + 32 hex, Shopify `shpat_`, Telegram bot tokens, JWTs (`eyJ…`),
`-----BEGIN … PRIVATE KEY-----`, DB URLs with passwords (`postgres://user:pass@host`).

Also: `Authorization: Bearer …`, `x-api-key`, `Cookie: session=…`, `?token=`/`?api_key=` in URLs,
`https://user:pass@host`, curl `-u user:pass`, `.npmrc` `_authToken`, `.netrc`, `~/.aws/credentials`,
kubeconfig `client-key-data`, base64 values under `data:` in Kubernetes secrets, `export API_KEY=…`.

Ignore: already-masked values (`****`, `sk-…xxxx`), placeholders (`your-api-key-here`, `changeme`,
`example`), commit hashes/UUIDs/checksums in normal context.

OCR handling: normalise look-alikes (`0/O`, `1/l/I`, `5/S`) before prefix matching; redact partially
visible keys when the visible part matches a prefix; join terminal lines that wrap mid-string; pad blocks.

## Unblur controls (later)
Presenter-only click-to-reveal per region, auto re-redact after ~30 s or on content change, confirmation
for high-confidence live keys, "never redact this string" allowlist, hold-to-reveal-all hotkey, panic
hotkey that redacts the entire shared window. Keep a local reveal log (location + time, never content).

## v1 scope
Build: menu bar control; capture → sanitized mirror window; full detection in terminals (promised);
title-based whole-window redaction for `.env`/`*.pem`/credentials editors; always-redact password
managers; detection elsewhere labelled beta; solid blocks; fail-closed delay buffer; panic hotkey;
manual redaction areas.
Skip / later: AI detection, automatic share-mode detection, team dashboard, cloud accounts, Windows.

## Build order (riskiest first)
1. Capture main display → render in mirror window; share it in Zoom; measure FPS + latency.
2. OCR one frame, print text + boxes; check accuracy on terminal fonts.
3. Redact a fixed region; then pattern detection; then the delay buffer and fail-closed logic.
4. WindowMap + per-app profiles.

## Testing
- Keep a growing folder of test screenshots across terminals, themes, fonts and zoom levels with seeded
  FAKE secrets (never real ones).
- Record the viewer-side output of the mirror window and check every frame for the seeded secrets.
  Target: zero raw-frame exposure, including during fast scrolling, freshly printed tokens, window
  switching, resizing, multiple displays and capture interruptions.

## Safety rules (added after the OCR live tests, Nov 2026)
- **Core metric: no unverified pixel may ever reach the shared output.**
- Never display a frame with masks from a different content state. Masks are versioned by: window identity,
  text version, window bounds, display scale, scroll position, layout/font state, mask generation.
- If state changed and isn't verified: keep the last sanitized frame or cover the changed area. Never publish a
  raw frame.
- Never ignore a pixel change just because it's small. Only known cursor/hover changes may reuse existing masks.
- Never request AX bounds for a multi-line range; split into one range per visual row. Never use one bounding box
  across lines.
- Mask the full value including wrapped parts; keep `KEY=` visible; minimal padding; if value boundaries are
  uncertain, mask the whole line.
- Rendering (~30 fps preview) is separate from detection; reuse safe frames while waiting. Never raise fps by
  skipping verification.
- No networking/telemetry; no secret values or detected text in logs, crash reports or diagnostics; session
  fingerprints (remembered secrets) are cleared when mirroring stops.
- Debug frame saving: off by default, explicit opt-in only, synthetic test secrets only, restrictive file
  permissions (0700/0600), never in normal use.

## Direction: Accessibility (AX) text for terminals, OCR as fallback
OCR proved too slow and inexact for terminals (last live test: a Slack token leaked, heavy over-blocking, full
blackout on mouse hover, ~5.5 fps / ~290 ms). Terminal text should come from the macOS Accessibility API; OCR
stays as the fallback for terminals where AX is unreliable and for other apps.

Gates, each reviewed before the next starts:
1. **AX feasibility**: per terminal, which attributes work, text accuracy, per-row bounds, timings.
2. **Security**: zero leaks in receiver-side output across 20 stress runs.
3. **Usability**: no hover blackouts, key names visible, minimal blocking.
4. **Speed**: ~30 fps, <100 ms added delay, without relaxing any check.
