# Ask about your screen

Hold **⌥⌘** in any app. The screen freezes under a soft glow and a ripple spreads from the
pointer. Circle or drag around something; a floating box opens beside it with a thumbnail. Type
a question, or press Return on an empty box for "What is this?". The answer streams in from
Tarn's own vision model on this Mac.

- **⌥⌘ again**: new capture, fresh conversation.
- **⇧⌥⌘**: add another capture to the open conversation (it goes with the next question).
- **Esc**: cancels the overlay, or closes the floating box.
- **Continue in chat**: moves the exchange, images included, into a normal Tarn chat.
- If nothing is circled within **30 seconds**, the overlay closes by itself. It waits up to 45
  seconds if a loop is still being drawn.

It's off by default: Settings → General → Screen → "Ask about your screen". There is also File →
Ask About Your Screen… for when Tarn is in front.

**Why off by default:** turning it on makes macOS ask for Screen Recording. Tarn's rule is that
a feature is on by default only if it needs nothing to be asked. Watching for ⌥⌘ needs no
permission (see Permissions), so Screen Recording is the only prompt left. It can't be avoided:
it is the minimum macOS allows for reading another app's pixels.

## Code

| Part | File |
|---|---|
| Chord state machine, keyboard poller, overlay failsafe, selection→crop geometry, conversation rules (pure, unit-tested) | `Tarn/Model/ScreenAsk.swift` |
| Global ⌥⌘ watcher (polling, no permission) | `Tarn/Services/ScreenAsk/ChordMonitor.swift` |
| Display capture (ScreenCaptureKit) and cropping | `Tarn/Services/ScreenAsk/ScreenCapture.swift` |
| Full-screen overlay (frozen frame, ripple, glow, loop) | `Tarn/Views/ScreenAsk/OverlayView.swift` |
| Floating panel and the permission card | `Tarn/Views/ScreenAsk/AskPanelView.swift` |
| Orchestration, streaming, Continue in chat, failsafe timer, Debug hooks | `Tarn/App/ScreenAskController.swift` |
| Tests | `TarnTests/ScreenAskTests.swift` |

## Decisions

### Telling a held ⌥⌘ from an ordinary ⌥⌘ shortcut

`ChordDetector` fires only when **exactly** ⌥⌘ (or ⇧⌥⌘) has been held for **350 ms with no
key press and no mouse press** in between. Then it stays quiet until both ⌥ and ⌘ are released,
so it fires once per hold.

- ⌥⌘Esc, ⌥⌘D, ⌥⌘V and friends: the key arrives within the hold time and cancels the chord.
  It stays cancelled until ⌥ and ⌘ are both up, even if you keep holding them.
- ⌥⌘-click or ⌥⌘-drag (Finder, Dock): the mouse press cancels it.
- ⌃ added at any point cancels it (⌃⌥⌘ is a different shortcut family).
- Letting go of ⌥ or ⌘ before 350 ms does nothing.
- Adding ⇧ late restarts the timer, so the final combination decides between fresh and append.

The risk left: someone who holds ⌥⌘ for more than 350 ms while hunting for a key will open the
overlay; Esc closes it. The hold is one constant (`ChordDetector.hold`).

### Watching the keyboard without a permission

`ChordMonitor` polls instead of listening to keyboard events, and `ChordPoller` turns the
samples into `ChordDetector` input. Each sample reads:

- the modifier keys held right now (`NSEvent.modifierFlags`);
- how long ago the newest key press, mouse press and modifier change happened
  (`CGEventSource.secondsSinceLastEventType`).

macOS gives both to any app without a prompt, and neither says which key was pressed.

- **Timing the hold.** The 350 ms are counted from when the modifiers actually changed, not
  from when a poll noticed, so the hold feels the same as with live events.
- **Cancelling.** Any key or mouse press after ⌥⌘ formed cancels the chord, including one that
  lands between two polls. When the chord arms, a press since the previous poll also cancels
  it, so a fast ⌥⌘Esc can't slip through even if the modifier timer were wrong.
- **Rate.** 10 Hz while no modifier is down (with timer tolerance, so macOS can coalesce
  wake-ups). 60 Hz only while ⌥ or ⌘ is down. Each poll is a handful of cheap reads.
- **App Nap.** While the setting is on, Tarn opts out of App Nap
  (`beginActivity(.userInitiatedAllowingIdleSystemSleep)`), so the timer isn't throttled when
  Tarn sits in the background with no window. Idle system sleep is still allowed.

Measured on this Mac (macOS 27), from a process with no keyboard or accessibility permission:

- Modifier state is readable: ⌘ held was seen through both `NSEvent.modifierFlags` and
  `CGEventSource.flagsState`.
- Key-down and mouse-down times are readable (they reset on the owner's real typing and clicks).
- Not seen in the samples: ⌥ and ⌘ held together, and the modifier-change timer moving. The
  poller doesn't depend on that timer: if it's stale or stuck, the press is assumed to be the
  previous poll, which is about 0.1 s off. Unit tests cover both cases.

### Permissions

| Permission | Why | Asked when |
|---|---|---|
| **Screen Recording** | ScreenCaptureKit, to take the one frozen frame. The minimum macOS allows for another app's pixels. | Turning the setting on, or the first ⌥⌘ if it isn't granted yet |

Nothing else: watching for ⌥⌘ needs no permission (see above), and Tarn never posts or changes
events or reads other apps' UI.

macOS has no callback for privacy changes, so while Screen Recording is missing Tarn checks every
two seconds and updates the card by itself. The card (in Settings, and in the floating box if
you hold ⌥⌘ without the permission) explains it in plain words. Its "Allow…" button opens the
right System Settings pane.

Known macOS behaviour, not verified here:

- After Screen Recording is switched on, macOS may ask to quit and reopen Tarn; the card says so.
- Debug builds are ad-hoc signed, so each rebuild can look like a new app to privacy settings.
  Re-grant after rebuilding, or test with a signed Release build.
- Secure input (password fields) may hide modifier state from other apps. If it does, ⌥⌘ simply
  won't fire while a password field has focus.

### Displays and Retina

- Only the display **under the pointer** is captured and covered. To circle something on
  another display, move the pointer there and hold ⌥⌘ again.
- The capture is taken at the display's native pixels (`SCContentFilter.pointPixelScale`).
- The crop uses the image's real pixels-per-point (image width ÷ display width in points), not
  an assumed 2×, and snaps outward to whole pixels. This works for 1×, 2× and scaled modes.
- The selection is the loop's bounding box plus 10 pt of context, clipped to the display.
  Strokes under 12 pt are treated as stray clicks.
- The floating box goes to the right of the selection, then the left, then below, then above,
  and is always kept inside the display's visible area (tested with a display left of and above
  the main one).
- Tarn's own floating box is left out of the capture, so ⇧⌥⌘ doesn't photograph it.

### Vision add-on loads only when needed

Nothing loads at launch or when the listener starts. The engine is restarted with the vision
add-on when a capture **starts**, so it loads while you draw and type. It's skipped if a normal
chat is answering, because restarting the engine would cut that answer off. The answer path
calls the same `ensureEngine(needVision:)` as image chats, so the rule is shared.

### What the model gets

The crop (downscaled to 1024 px like any pasted image), a short system prompt that says it's
looking at part of the user's screen and must not invent menus or numbers it can't read, and
the conversation so far. Thinking is off and answers are capped at 700 tokens. Follow-ups
without a new capture still see the earlier images, because the prompt keeps pixels for the two
most recent image messages, the same as normal chats.

With the setting on, Tarn keeps running after its window closes, so ⌥⌘ still works. Continue
in chat reopens the window.

## Testing

You can't grant privacy permissions from a script, so everything after the capture has Debug
hooks that run the real code with a fixture image instead of ScreenCaptureKit:

```sh
xcodegen generate
xcodebuild -scheme Tarn -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -scheme Tarn -derivedDataPath build/DerivedData test

# Fixture questions through the real model; writes <profile>/screen-ask-results.jsonl.
scripts/dev/screen_ask.sh <profile> <models-dir> -TarnOffline YES -TarnScreenAskBatch batch.json
# The real overlay with an image as the frozen screen, a selection, an answer, Continue in chat.
scripts/dev/screen_ask.sh <profile> <models-dir> -TarnOffline YES \
  -TarnScreenAskOverlayFixture shot.png -TarnScreenAskSelect "x,y,w,h" -TarnScreenAskContinue YES
# Overlay states rendered offscreen to PNGs (no model, no permissions).
scripts/dev/screen_ask.sh <profile> <models-dir> -TarnScreenAskRender <dir> -TarnScreenAskFixture shot.png
# The chord timer and the no-Screen-Recording path.
scripts/dev/screen_ask.sh <profile> <models-dir> -TarnScreenAskTrigger fresh -TarnScreenAskFeedChord YES
```

A batch item is `{"id", "image", "question", "select": [x, y, w, h], "scale", "followUp"}`.
`select` is in points (pixels ÷ `scale`, default 2). The script holds the heavy-model lock if
`LOCK=<dir>` is set, and only ever signals the processes it started.

### Manual checklist (needs a person and real permissions)

1. Settings → General → Screen: turn on "Ask about your screen". Expect exactly one macOS
   prompt, for Screen Recording, and no other. Allow it, and quit and reopen Tarn if macOS asks.
2. In another app (Safari, Finder), hold ⌥⌘ about half a second without pressing anything.
   Expect: the frozen screen, a ripple from the pointer, the hint at the top.
3. Press ⌥⌘Esc quickly (Force Quit window opens, no overlay). ⌥⌘-click a Dock icon (no overlay).
   Type ⌥⌘ followed by a letter in a text field (no overlay).
4. Circle a button. Expect: the region lifts, the box appears beside it with a thumbnail and the
   cursor in the text field, and Tarn's main window does **not** come forward.
5. Press Return on the empty box. Expect: "What is this?" and a streamed answer.
6. Hold ⇧⌥⌘, circle a second thing, and ask "what's the difference?". Expect two thumbnails, and
   the answer refers to both.
7. Hold ⌥⌘, circle something new. Expect a fresh box with one thumbnail.
8. Esc during the overlay (box stays as it was); Esc in the box (it closes).
9. Hold ⌥⌘ and then do nothing. Expect the overlay to close by itself after 30 seconds.
10. Continue in chat. Expect a new chat titled "Screen: …" with the images and answers. Repeat
    with Tarn's main window closed.
11. Close Tarn's window, use other apps for ten minutes, then hold ⌥⌘. Expect the overlay as
    quickly as in step 2 (App Nap must not slow the watcher).
12. With a second display: hold ⌥⌘ with the pointer on each display; check the crop matches
    what you circled, and the box stays on that display near the edges.
13. Switch Screen Recording off in System Settings and hold ⌥⌘. Expect the permission card,
    not a blank overlay.
14. Turn the setting off. Expect ⌥⌘ to do nothing, and Activity Monitor to show Tarn idle.

## Measured: is the 9B model good enough? (2026-11-25, Apple M5, 16 GB)

Qwen3.5 9B Q4_K_M with its F16 vision projector, through the real pipeline after the capture
step (crop → session → prompt → engine → stream), via `-TarnScreenAskBatch`. Three
llama-servers from other experiments were resident during the run. Generation ran at 7–11
tokens/s, against 21 tokens/s measured idle (docs/MODELS.md), so these latencies are probably
pessimistic.

**Fixtures:** the Mac's Screen Recording permission wasn't available to the test harness, so
the fixtures are 8 screens of real Apple apps (iPadOS 26.5 in a headless Simulator: Settings,
Calendar, Contacts, Safari, Maps, Photos, Reminders, Shortcuts) and 5 screenshots of Tarn's
own Mac UI. Each question uses a realistic circled region, not the whole screen. No
screenshots of real Mac apps other than Tarn: Mac UI is denser than iPad UI, so expect Mac
accuracy to be somewhat lower.

**Latency** (time from pressing Return; the engine was already loaded with vision, which took
7–16 s cold):

| | median | p90 | worst |
|---|---|---|---|
| First token | 2.5 s | 5.3 s | 10.3 s (first request; the crop was 953×1024) |
| Full answer (17–131 tokens) | 11.3 s | 15.4 s | 16.6 s |
| Follow-up without a new capture (2 runs, prompt cached) | 0.8–1.1 s first token | | 4.2 s full |

Large crops cost the most: first token was about 1–3 s for strips like a toolbar or table
row, and 5–10 s for regions near 1000×1000 px.

**Correctness, judged strictly** (17 questions + 2 follow-ups):

- **12 fully right.** Includes counting and naming 6 contacts, reading an email address, a
  birthday, a deposit amount and temperature ranges, and naming the right button for "how do I
  see the whole month", "change the background", "location just this once" and "finished
  reminders".
- **4 right answers with a false extra claim:**
  - Reminders: an invented "tap Completed again to clear them".
  - Run plan: says the session totals "~16 mins", but 4 × 5 min = 20.
  - Tarn toolbar: the brain icon guessed as "AI suggestions"; it's the think-first toggle.
  - Photos: calls the dimmed background "a preview pane".
- **1 wrong in substance.** Shortcuts: it pointed to Automation, then invented a "When this
  Shortcut Runs" section in the shortcut editor. Following it would fail.
- **Follow-ups: 2 of 2 right.**
- **Caveat:** one counted-right answer (Settings → Language & Region) adds a second step,
  "iPad Language", that I couldn't check in the Simulator. It may be an old label, which would
  make the strict count 11.

**Pattern:** reading what's in the circle (text, numbers, names, which button) is reliable.
Failures come when the answer needs knowledge of screens that aren't visible (multi-step
how-tos, icon meanings without labels), or when it adds commentary. Putting today's date in
the system prompt also led it to remark that dates on screen were "outdated" (seen in 2
overlay runs). Removing the date is worth trying, but wasn't measured.

### Re-measured on an idle machine (2026-11-25, evening)

Same 17 questions, same crops, nothing else running. The model is the same; only the load
differed.

| | under load (first run) | idle | idle, tightened prompt |
|---|---|---|---|
| First token, median / p90 / worst | 2.5 / 5.3 / 10.3 s | 1.0 / 2.5 / 4.7 s | 1.0 / – / 4.7 s |
| Full answer, median / worst | 11.3 / 16.6 s | 3.8 / 8.3 s | 2.6 / 6.5 s |
| Generation speed | ~9 tokens/s | 21.9 tokens/s | – |
| Follow-up, first token | 0.8–1.1 s | 0.4 s | – |
| Strict score (fully right / flaw / wrong) | 12 / 4 / 1 | 14 / 2 / 1 | 14 / 2 / 1 |

Answers vary between runs, because sampling isn't greedy.

The tightened prompt (now in `ScreenAskSession.systemPrompt`) tells the model to answer only
what was asked, with no extra percentages, tips or guesses, and drops the date. It scored the
same, but answers got shorter, and the invented asides stopped, such as "Storage Management
view", "~16 min" and "on your Mac" for an iPad. The one consistent miss is explaining unlabeled
toolbar icons (Tarn's own globe and brain buttons).

## The demo video

`video/make_screen_demo.sh` records one real take and builds two files:

- `video/out/tarn-screen-raw.mp4`: the take as recorded. Real time, uncut, no music.
- `video/out/tarn-screen-demo.mp4`: the same take in the style of `tarn-demo.mp4`. A slow camera
  and the end card, with the music. Nothing is sped up, and a "real time" tag says so.

**Scripted** (the "hand": the recording runs with nobody at the keyboard or mouse):

- The ⌥⌘ and ⇧⌥⌘ holds, fed to ChordMonitor's own poller in place of the real keyboard.
- The two loops: mouse-down, drag and mouse-up events sent to the overlay window, so the real
  DragGesture draws and selects. The hand aims by reading the screen with on-device text
  recognition.
- The typed questions, set into the box letter by letter.
- Bringing Preview forward before the second capture (`open -a Preview`).

**Live:**

- The ScreenCaptureKit capture of the real screen.
- The overlay, the crop and the panel.
- The 9B model's streamed answers.
- Continue in chat.

**Screen Recording:** a Debug build launched with `open` has its own privacy identity and no
grant (`CGPreflightScreenCaptureAccess` false). Launched as a child of a terminal that has
Screen Recording, it inherits that grant. The script uses the child launch. For normal use, Tarn
itself must be allowed under Privacy & Security → Screen & System Audio Recording.

### The delivered take (2026-11-25, 23:00, take 4)

| raw video | edited video | what happens |
|---|---|---|
| 0.9 s | – | Staged desktop: Disk Utility in front, the Kestrel guide in Preview behind |
| 3.1 s | 1.6 s | ⌥⌘ held (simulated); the screen freezes 1.1 s later (ripple, glow, hint) |
| 5.7 s | 4.2 s | Loop around Disk Utility's Macintosh HD usage figures |
| 7.6 s | 6.1 s | The panel opens beside it with the thumbnail |
| 8.2–10.2 s | 6.7–8.7 s | "How much free space do I have?" typed and sent |
| 13.9 / 15.2 s | 12.3 / 13.6 s | First word / full answer 1 |
| 17.7 s | 16.1 s | Preview brought forward |
| 18.9 s | 17.4 s | ⇧⌥⌘ held (simulated); the screen freezes again |
| 21.3 s | 19.8 s | Loop around the guide's "Before you install" box |
| 23.0 s | 21.5 s | The second thumbnail joins the panel |
| 23.6–25.7 s | 22.1–24.2 s | "Is that enough to install this?" typed and sent |
| 28.4 / 30.0 s | 26.8 / 28.5 s | First word / full answer 2 |
| 32.1 s | 30.5 s | Continue in chat: Tarn's chat window, both captures and answers |
| 36.9 s | 35.4 s | Tarn quits (the edit dissolves to the end card) |

The answers, word for word:

1. "You have **229.23 GB** of free space on Macintosh HD."
2. "Yes — you have 229.23 GB free, and the installation needs only 40 GB."

Both are right: Disk Utility showed Free 229.23 GB, and the guide needs 40 GB.

Takes that weren't used:

- **Take 1:** a staging bug. The second loop circled Disk Utility again, so answer 2 couldn't
  see the guide.
- **Take 2:** both answers right, but the chat window opened behind Preview.
- **Take 3:** stopped before recording, because the text reader misread "Free".

All three were fixed in the script, not by retrying until the model behaved.
