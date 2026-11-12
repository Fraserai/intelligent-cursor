# Architecture

The application is one native background process. It has no permanent content window and deliberately avoids a dashboard.

```text
mouse side button / F18
          ↓
  interaction state machine
          ↓
  normal-cursor semantic tracker
    └─ click-through recognition outline
          ↓
  ContextAcquisitionEngine
    ├─ Accessibility element/tree
    ├─ URL / file / selected text
    ├─ source app metadata
    └─ automatic visual crop + OCR fallback
          ↓
      ContextBundle
          ↓
   IntelligenceRouter
    ├─ GPT-5.6 Sol · Max
    ├─ Opus 5 · Max
    ├─ Grok 4.6 · Heavy
    └─ All 3
          ↓
  anchored transient response
```

## Stable seam: context acquisition

`PointedTarget` records the semantic element under the normal cursor without assuming that it was a screenshot. `ContextBundle` contains typed `ContextItem` values with provenance and confidence. `ContextAdapter` implementations can contribute richer information without changing the gesture or response UI.

The Accessibility adapter is the first semantic resolver. It walks the element ancestry and bounded subtree to recover coherent text, roles, URLs, selected text, and file identity. The generic visual adapter automatically crops the recognised element—or a small area around the point when no element frame exists—and is the v1 fallback. Future browser DOM, YouTube moment, code, terminal, Codex, and Claude Code adapters rank ahead of the visual fallback when suitable.

### Declining rather than guessing

Candidate scoring accumulates positive evidence — text, URLs, informative roles —
and subtracts penalties for structural containers. A non-positive best score means
nothing semantic was found and the only candidates were the application, a window,
a scroll area, or the menu bar. The resolver returns `nil` in that case instead of
reporting a target, so the visual adapter takes over and the model is never handed
confident nonsense about the wrong element.

### What the visual fallback costs

Measured across a day of real use: capture is 51–85ms, recognition is 164–750ms.
The screenshot is cheap and the text recognition is the expensive half by an order
of magnitude, which is the opposite of what it looks like from the outside.

So the image is captured broadly and the recognition is gated. Above roughly 500
characters of accessibility text, reading the same pixels back returned a subset or
a near-duplicate of what was already known; below it, recognition regularly found
several times more. The pixels still reach the model either way, so charts,
photographs, and video frames are unaffected — only the redundant second reading of
text is skipped.

The gate is set from the recorded distribution rather than from intuition, and the
`visual cost` diagnostic keeps reporting both halves so it can be re-derived when
real use disagrees.

### Chromium and Electron

Chromium-based applications do not build a web-content accessibility tree until a
client asks for one. Until then every hit test inside Chrome, VS Code, Slack, or an
Electron coding agent resolves to window chrome rather than the thing on screen —
pointing at a post can return an unrelated bookmark from the toolbar.

After a resolution comes back structural, the resolver sets `AXManualAccessibility`
and `AXEnhancedUserInterface` on that process once. Chromium reports an error for
both even when it honours them, so the result codes are not trusted. The tree takes
roughly a second to populate, so the sample after the request is the one that
succeeds; the hold gesture usually covers that. Applications that resolve correctly
are never asked.

This is deliberately a general accessibility mechanism rather than per-site
handling. Browser DOM, video-moment, and coding-agent adapters remain the richer
path and rank ahead of the generic resolver when added.

## Expressing intent

The cursor is tiny and intent is not. The exact element under the pointer tip is a
good guess, never the whole answer, so aiming is its own phase rather than
something the release decides:

```text
tap to arm → move to aim → scroll to size → click to lock → drag to override
```

`TargetSelection` is what makes this hold together. It is what the user meant —
a semantic element at an ancestry level, or a drawn region — produced by the
gesture layer and consumed by the context engine. The engine never learns about
mice, and it no longer re-derives intent from wherever the pointer happened to be.

Granularity is an offset from the element the resolver scores best, so level 0 is
exactly the automatic behaviour and scrolling walks outward through ancestors the
resolver already computes. A level the user chose is always honoured, including
one the scoring heuristic would have declined: explicit intent outranks the
heuristic.

The region is a fallback, never a requirement. Drawing is the same button as
locking, separated only by whether the pointer moved, so there is no mode to enter
and no way to end up in a screenshot tool by accident.

The panel is the controller and the screen is the canvas. While aiming, the panel
is a compact bar pinned out of the way and nothing is described in words that the
outline can show directly. It expands into the full panel only once a target is
locked. The trigger source takes over clicks and the wheel only while the active
policy asks for it, so an idle Mac behaves exactly as it always did.

## Interaction lifecycle

The physical activation gesture is a replaceable policy boundary, not a permanent
product invariant. `TapToArmGesturePolicy` is the working policy.
`HoldReleaseGesturePolicy`—side-button down begins inspection and side-button up
commits—is kept intact and swappable so real use can decide which one wins.
Replacing the policy changes neither semantic targeting, context acquisition,
provider routing, nor the panel.

Only one session exists at a time:

```text
idle → armed/recognising → acquiring → prompting → invoking → responding
  ↑          └──────── Escape / side-button toggle ───────────┘
```

Every asynchronous result carries the session identifier. Results from dismissed or superseded sessions are dropped, and cancellation clears image, prompt, transcript, and network references from memory.

## Conversation lifetime

The cursor is how intelligence is started from something in the world. The
conversation is not trapped inside that thing afterwards.

`ContextBundle` is already a detached snapshot — text, metadata, and image bytes,
with no live accessibility references — so it survives navigation on its own. What
ended conversations early was the click-away dismissal, which treated every click
outside the panel as intent to close. That now applies only before a question has
been asked: until then the panel is a transient proposal worth flicking away;
afterwards it is a conversation, and only a deliberate close ends it.

Completed turns are written to Application Support, which is not synced and so
cannot stall the way a synced project folder can. Each conversation is a small
JSON file of metadata and turns, with its image as a sibling PNG, so listing
recent titles never decodes megabytes of encoded pixels. Only what the model
actually receives is kept — the flattened untrusted context and the image —
because that is the boundary that still matters once the original element is gone.

Reopening restores into the prompting phase with a fresh session identifier, so
follow-ups, dismissal, and persistence run the same path as a conversation
started from the cursor rather than a parallel one.

Conversation management is a menu of recent titles and nothing else. There is no
window, no sidebar, and no history surface, and the oldest conversations are
pruned rather than accumulated.

## What the answer has to be

The user is looking at the thing they pointed at. Describing it back to them is the
one answer guaranteed to be useless, and it is the answer a general-purpose
assistant prompt produces by default — the first version of this system prompt
asked the model to "answer the user's explicit question" and to "be direct", which
against a real day of use produced a median answer of 334 characters that mostly
restated the screen.

Two properties of this product drive the prompt instead. The answer must supply
what the screen cannot: what the thing actually is, what is notable, what it
implies. And the question is usually a fragment or a reaction — "thoughts?",
"this is wild", "wtf" — which has to be read as an invitation rather than parsed
literally. Depth is matched to the question, so a factual lookup stays short while
an open reaction earns something worth reading.

## Trust boundary

Pixels, OCR, Accessibility text, DOM content, files, and transcripts are untrusted context. Provider requests delimit them from system instructions. Agent handoffs will remain explicit routes; captured content must never silently turn into an action.

## Provider profiles

The four labels are stable product choices, while each provider translates the profile into its native request:

- GPT-5.6 Sol → `gpt-5.6-sol`, Responses API, `reasoning.effort`.
- Opus 5 → `claude-opus-5`, Messages API, `output_config.effort`.
- Grok 4.6 → `grok-4.6`, Responses API, `reasoning.effort`.
- All 3 → concurrent fan-out with partial-success preservation.

Reasoning effort is chosen separately from the model, because at the cursor the
trade-off is a daily one rather than a property of a profile. Fast, Balanced, and
Max translate into each provider's own vocabulary in `ReasoningEffort`.

Measured on `gpt-5.6-sol` for a short question, the number that matters is time to
first token, since the panel streams:

| Effort | First token | Total |
| --- | --- | --- |
| Fast | 2.3s | 6.5s |
| Balanced | 2.4s | 8.7s |
| Max | 10.6s | 15.0s |

Balanced is the default. It starts streaming as quickly as Fast while thinking
considerably harder; Max spends over ten seconds before a single character
appears, which is the wrong shape for an interaction meant to feel immediate.

## Permissions

- Input Monitoring: global mouse/F18 listen event tap.
- Accessibility: acquire semantic UI-element context and, when trusted, suppress the activation event.
- Screen Recording: in-memory ScreenCaptureKit image capture.
- Microphone: audio input while dictating.
- Speech Recognition: converting speech to the prompt text.

The app is intentionally unsandboxed for this personal outside-the-Mac-App-Store build. A privileged helper is not required.
