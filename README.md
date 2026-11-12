# The Intelligent Cursor

The Intelligent Cursor is a personal, native macOS utility built around one interaction:

> **BUTTON → POINT → ASK**

It stays out of the Dock and has no permanent window. Press a configured gaming-mouse side button, keep using the normal macOS cursor, point at anything visible, ask by typing or voice, and receive a transient answer beside the target.

## What this first version proves

- Physical side-button activation with a menu-bar fallback.
- Semantic point targeting through the Accessibility tree: element text, role, URL, source app, and file identity where available.
- A subtle click-through recognition outline while the normal macOS cursor remains unchanged.
- Automatic element-sized ScreenCaptureKit and Vision fallback context; no manual screenshot region and no screenshot file.
- A compact, mockup-inspired floating model and response panel.
- Live GPT-5.6 Sol streaming, rendered as formatted text rather than raw Markdown.
- Selectable reasoning effort — Fast, Balanced, Max — remembered between uses.
- Conversations survive leaving the page, switching tabs, and changing applications; only a deliberate close ends one.
- The panel can be dragged by its header once it is placed.
- Recent conversations reopen from the menu bar. No history window.
- The current turn stays legible: what was just asked sits above the answer, with the follow-up field beneath. Asking again replaces it — deliberately not a transcript.
- Provider-ready Opus 5 · Max, Grok 4.6 · Heavy, and All 3 routes.
- Voice dictation through macOS Speech.

The visual image is one fallback context adapter, not the product abstraction. Rich browser DOM, video-moment, file, code, and coding-agent adapters can be added behind the same interaction.

## Build

Requirements: macOS 15.2 or later and the Apple Swift 6 command-line toolchain. The build script invokes `swiftc` directly so a full Xcode installation is not required.

Run once, so the app keeps a stable code signature:

```sh
./scripts/setup-signing.sh
```

Then build and launch:

```sh
./scripts/build-app.sh
open "outputs/The Intelligent Cursor.app"
```

### Why signing setup exists

An ad-hoc signature's designated requirement is a bare `cdhash`, which changes on
every build. macOS keys Accessibility, Input Monitoring, and Screen Recording to
that requirement, so each rebuild would silently revoke all three and the app
would go quiet with no visible error. `scripts/setup-signing.sh` creates a local
self-signed identity in its own keychain, giving a requirement of
`identifier "com.caeseyfraser.intelligent-cursor" and certificate root = …`
that survives rebuilds. It touches nothing outside `~/.intelligent-cursor/signing`
and its own keychain. To undo:

```sh
security delete-keychain ~/Library/Keychains/intelligent-cursor-dev.keychain-db
rm -rf ~/.intelligent-cursor/signing
```

### If the compiler appears to hang

Some Command Line Tools installs keep a stale pre-2024
`usr/include/swift/module.modulemap` beside the current `bridging.modulemap`.
Both declare `module SwiftBridging`, so every SDK `.swiftinterface` fails to
build. Because the CLT SDK ships SwiftUI, AppKit, and Foundation as textual
interfaces rather than prebuilt modules, the compiler retries these builds and
looks like it is stuck in type checking while reporting nothing. `build-app.sh`
detects the collision and neutralises the stale file with a VFS overlay for the
duration of the build; nothing on the system is modified. The permanent fix, if
you prefer it, is `sudo rm` on the stale `module.modulemap`.

### Watching what the cursor understood

The app has no window, so the log is the way to see its reasoning:

```sh
log stream --predicate 'subsystem == "com.caeseyfraser.intelligent-cursor"' --level debug
```

It reports permission state at launch, each trigger and resolved intent, the role
and confidence of the recognised target, and which context adapters contributed.
Captured content is untrusted and often private, so only shapes, roles, and counts
are logged — never context text, prompts, answers, URLs, or credentials.

### Development harnesses

Each builds part of the real app into a CLI, so a layer can be exercised on its
own. They are harnesses, not product surfaces.

```sh
./scripts/build-probe.sh        # context engine at a screen point
./scripts/build-ask-probe.sh    # provider routing over a synthetic context
```

`work/probe/context-probe [x y]` prints the resolved role, confidence, frame, and
every context item for a point. `work/probe/ask-probe <profile> "<question>"`
streams a real answer through `IntelligenceRouter`.

Note that a process without Accessibility permission can post synthetic events
that event taps observe but that applications never receive, so driving the panel
with scripted keystrokes does not work. Test the gesture with the real button.

On first use, allow Input Monitoring, Accessibility, Screen Recording, Microphone, and Speech Recognition when requested. The app menu contains permission status and System Settings links.

The first raw side button is usually CoreGraphics button `3`. Change it in the menu if your mouse reports a different number. If the vendor driver consumes the button, map that physical button to F18; the app also listens for F18 as a reliable fallback.

## The interaction

```text
tap to arm → move to aim → scroll to size → click to lock → drag to override
```

Tap the side button and the normal cursor stays completely free. Move it and the
thing you mean is outlined on screen. Scroll to change how much you mean, from a
single line out to the whole post that contains it. Click to lock it, and the
compact bar expands into the panel. If no element expresses what you mean, drag
instead and the region is captured directly — same button, no mode, and never
required.

Escape or the side button again cancels. Clicks and scrolling are only taken over
while AI mode is armed.

`HoldReleaseGesturePolicy` is still in the source and swappable in
`ApplicationCoordinator.init` if the original hold-and-release feels better.

## Configuration

The app searches upward from its `.app` bundle for `.env.local`, so the built app in `outputs/` can use the local credentials without bundling secrets inside the application.

```dotenv
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
XAI_API_KEY=...
```

Model IDs have sensible defaults and can be overridden with `OPENAI_MODEL`, `ANTHROPIC_MODEL`, and `XAI_MODEL`.
