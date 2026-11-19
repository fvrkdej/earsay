# Developing Earsay

For anyone (person or agent) changing this app. Read "How we work" and "Rules" before touching anything; most of what's below was learned the hard way.

## How it works, start to finish

```
 trigger                 get the words                     tidy them            speak
 ─────────               ─────────────                     ─────────            ─────
 Ctrl+Opt+R  ─────────▶  Selection (highlighted text)  ─┐
 crosshair click ─────▶  AXText (the app's own text)   ─┤
   └ app gives nothing ▶ ScreenText + OCR (pixels)     ─┼─▶  TextPrep  ─────▶  Speaker
 open a file ─────────▶  BookText (epub/pdf/docx/...)  ─┤    (sentences,       (voice, audio
 Apple Books ─────────▶  BookMatcher / BookReader      ─┘     pauses,           queue, controls)
                                                              cleaning)               │
                                                                                      ▼
                                                              Pill, Reader window, Now Playing,
                                                              Bookmarks, BooksSync (follow in Books)
```

1. **Get the words.** Five ways in, listed above. Each one ends as plain text with paragraphs separated by a blank line and list items or table rows on their own lines.
2. **Tidy them (TextPrep).** Splits into sentences, makes every line end like a sentence, fixes what the voice says wrong (numbers, money, dates, abbreviations, capitals), turns punctuation into pauses, and cuts long sentences at natural points (the voice handles about 40 words at a time).
3. **Speak (Speaker).** Streams each sentence through the voice and queues the audio. It stays about 30 seconds ahead of what you hear, so even a whole book never piles up in memory. Pauses: 0.3 s after a paragraph, 0.2 s after a line (a list item or table row).

## The files

`Sources/ReadAloud/` is the app. `Sources/ReadAloudCore/` is the text work, shared with the test tools.

| File | What it does |
|---|---|
| `main.swift` | The app: menu, shortcut, the five ways in, files and bookmarks, chapters, sleep timer, idle unload, debug commands |
| `Speaker.swift` | The voice and the audio queue: speak, append, pause, 10 s jumps, speed, chapters, AirPods switching, keeping the Mac awake |
| `Pill.swift` | The floating control pill (SwiftUI) |
| `Reader.swift` | The reader window: the book's own paragraphs, the current one highlighted, click to jump |
| `Extras.swift` | Media keys and AirPods (`MediaControls`), open at login (`LoginItem`), drop a file on the menu bar icon (`DropView`), the daily update check (`Updates`), is the microphone in use (`Microphone`) |
| `Prefs.swift` | Settings (`Prefs`, UserDefaults), the Settings window (including Pronunciations), the Welcome window, `SimpleWindow` |
| `Highlighter.swift` | The on-screen highlight over what she's reading in the clicked app |
| `Library.swift` | The library window, covers and titles read from the file (`Covers`) |
| `Exporter.swift` | Export as an audiobook (AAC; chapters via ffmpeg into .m4b) |
| `Selection.swift` | Gets highlighted text: Accessibility first, Cmd+C as a fallback |
| `AXText.swift` | Reads the app's own text at a click point (see below) |
| `ScreenText.swift` | Screen capture of a window or area (ScreenCaptureKit) |
| `RegionPicker.swift` | The crosshair overlay: click or drag |
| `BookReader.swift` | Bought books in Apple Books: read the page off the screen, turn the page when about 5 s of audio is left, carry an unfinished sentence over |
| `BooksControl.swift` | Presses next/previous in Books without bringing it forward; `BooksSync` keeps Books on her page when reading your own file |
| `Bookmarks.swift` | Where you stopped in each file (path and sentence number only) |
| `HotKey.swift`, `Log.swift` | Global shortcuts; the log |
| `ReadAloudCore/TextPrep.swift` | All the text tidying. Most voice bugs are fixed here |
| `ReadAloudCore/BookText.swift` | Opens EPUB (zip or folder), PDF (reflowed), Word/RTF, text, Markdown; marks chapters |
| `ReadAloudCore/TOCParser.swift` | Reads an EPUB's own contents page for chapter names |
| `ReadAloudCore/OCR.swift` | Reads text from a screen picture (Vision) and puts lines back into paragraphs and columns |
| `ReadAloudCore/BookMatcher.swift` | Finds which of your Books files is on screen, and where |

### Reading the app's own text (AXText)

Every Mac app keeps a labelled description of its contents for screen readers like VoiceOver ("paragraph", "button", "list item", "message box"), including parts scrolled out of view. On a click:

1. Ask the app for the element at that point. Chromium and Electron apps (Chrome, VS Code, Antigravity, Slack) only build this once asked, so we ask as the crosshair opens (`wake`). That can make them show a "screen reader detected" prompt; answering No is fine.
2. Find the piece to read: the nearest chat message or article (`AXDocumentArticle`), else the page's main area, else the whole page.
3. Walk it in order. A paragraph is an element made only of words (text, bold, links, a list number). Buttons, text boxes, images, time stamps, navigation and banners are skipped. Tables are read one row per line; the Mac also lists every table by column, and that copy is ignored.
4. Start at the paragraph that was clicked, read to the end of the piece.
5. Nothing usable (fewer than 3 words)? Fall back to the screen picture and OCR.

Native text views (Notes, TextEdit, Mail) give their whole text in one value; we start at the clicked paragraph.

`AXText.read` also returns each paragraph's elements, one per line (list items and table rows are lines). The **Highlighter** uses them: on every new sentence, `main.swift` works out the paragraph and the line inside it (count the `endsLine` sentences before it in that paragraph) and calls `follow`. Positions are re-checked 5 times a second, so the highlight follows scrolling. If the line is out of view and "scroll along" is on, the element gets the `AXScrollToVisible` action. The highlight shows only while that app is in front, clipped to its window. Paragraphs and lines with no letters or numbers are dropped on both sides, so the numbers line up with TextPrep.

### Other pieces

- **Moving bars**: a tap on the audio mixer measures her loudness about 40 times a second (`Speaker.onLevel`). The pill's `LevelBars` and the menu bar icon (`setIcon`, redrawn only when the step changes) use it.
- **Voices**: all 27 voices come with the model (`constants_bin/*.safetensors`). `Speaker.setVoice` switches; the next sentence uses it.
- **Idle**: after 15 idle minutes the voice is let go (about 387 MB down to 58 MB) by replacing the `PocketTtsManager`; FluidAudio's own `cleanup()` frees nothing.
- **Export** runs its own voice copy at low priority and waits while `speaker.inProgress`. Markdown needs 3 or more `# ` headings for them to count as chapters (fewer: the top heading is a title).
- **Icon**: `Resources/AppIcon.icon` is an Icon Composer icon, compiled by `actool` in `build.sh` into `Assets.car`, so it follows the Mac's icon style (Default, Dark, Clear and Tinted, light and dark). Draw layer images into a fixed-pixel bitmap (`scripts/make-glyph.swift`): drawing via NSImage on a Retina screen doubles them. Check the looks with Icon Composer's `ictool --export-image --rendition Default|Dark|ClearLight|ClearDark|TintedLight|TintedDark`, not with Finder, which caches old icons.

## Build, install, test

```bash
./scripts/build.sh                       # build (at low priority) and install to ~/Applications
osascript -e 'quit app id "io.autimized.readaloud"'; open ~/Applications/Earsay.app
tail -f ~/.local/share/read-aloud/app.log
```

Test tools (build with `swift build -c release --product <name>`):

| Tool | Use |
|---|---|
| `Probe <file> --prep --text-only` | Prints exactly the sentences she'd speak. The first thing to run for any "she said it wrong" report |
| `Probe <file> --prep out.wav` | Makes the audio, to listen to or transcribe |
| `OCRProbe <image> [--boxes]` | Runs a screenshot through the screen reader. Turns a user's screenshot into the exact text she got |
| `swift tools/send.swift read <file>` / `stop` | Ask the running app to read a file, or stop |

Debug commands the running app answers (system-wide notifications from this Mac only; they write local files and send nothing anywhere). **They are off by default** because they save screen text and screenshots: switch them on with `defaults write io.autimized.readaloud debugCommands -bool true` and restart the app (the log then says `debug commands on`). Only `readfile` and `stop` are always on; the `read-aloud` skill uses them. The `test` command takes `silent on|off` (a test read makes no sound), `sleep <seconds>` or `sleep chapter`, `hear <voice>|<text>` (the pronunciation preview) and `update <owner/repo>` (the update check against any repository). Post them with a two-line Swift script calling `DistributedNotificationCenter.default().postNotificationName(..., object: ..., deliverImmediately: true)`:

| Notification | Object | Result |
|---|---|---|
| `io.autimized.readaloud.axdump` | bundle id, e.g. `com.google.Chrome` | That app's accessibility tree in `~/.local/share/read-aloud/axdump.txt` |
| `io.autimized.readaloud.axtest` | `bundleID|exact sentence` | Pretends to click that sentence; what she'd read goes to `axtest.txt` |
| `io.autimized.readaloud.unload` | anything | Lets the voice go now (normally after 15 idle minutes) |
| `io.autimized.readaloud.hltest` | `bundleID|exact sentence|paragraph|line` | Shows the on-screen highlight there, without reading |
| `io.autimized.readaloud.hlend` | anything | Removes it |
| `io.autimized.readaloud.shot` | anything | Screenshot of the main screen, including the app's own windows, to `shot.png` |
| `io.autimized.readaloud.render` | `library`, `settings`, `welcome0/1/2`, `pill`, `mini` | Draws that window off screen to `render-<name>.png` (nothing appears on screen) |
| `io.autimized.readaloud.export` | a file path | Exports it as an audiobook without opening Finder |

`axdump.txt`, `axtest.txt` and `shot.png` contain whatever was on screen. They stay on the Mac; delete them when done.

To check what she actually says, transcribe the audio from `Probe ... out.wav` with a speech-to-text service and compare with the text.

## Pronunciations, calls, updates, releases (18 Nov)

- **Pronunciations.** Settings keeps `pronunciations` as `[[word, say it as]]`; `Prefs.apply` copies it into `TextPrep.sayAs`, which `TextPrep.clean` applies first: whole words or phrases, any capitals ("Dejiland" is left alone). It covers everything she reads, exports included. Before and After in Settings speak the word in the "Hear in" voice; Before puts `TextPrep.asWritten` (U+E000) in front so the rule skips it. A preview in another voice switches back to your voice when it ends (`restoreVoiceIfNeeded`). Test without the app: `Probe file --prep --text-only --say "SQL=sequel"`.
- **Pause for calls.** Every second during a read, `Microphone.inUse()` asks CoreAudio whether the default input is running in any app. Only the change from off to on pauses her, so an app that keeps the microphone open all the time doesn't stop every read. She doesn't carry on by herself after the call. Setting: `pauseForCalls` (on by default).
- **Updates.** `Updates.repo` ("owner/name") is empty until the GitHub repository exists: **set it at launch.** At launch and every 24 hours the app asks `api.github.com/repos/<repo>/releases/latest`; a newer `tag_name` (v1.2 style) shows "Update available: version x" at the top of the menu, opening the release page. A fork changes that one line.
- **Releases.** Bump `CFBundleShortVersionString` in `Resources/Info.plist`, run `scripts/release.sh` (makes `dist/Earsay-<version>.zip`, gitignored), and attach it to a GitHub release tagged `v<version>`. Always sign with the same "Read Aloud Dev" certificate from Deji's Mac: macOS ties permissions to it, so people keep theirs across updates. No paid Apple account (Deji, 18 Nov), so the first open needs System Settings > Privacy & Security > Open Anyway; the README says so.
- **Code blocks are read as they are** (Deji, 18 Nov): the 10-second jump skips them.

## Rules

- **Never restart the app while someone is listening.** Check the last lines of `app.log` first; install only when it ends in `read finished`, `controls off` or `stop`.
- **Build at low priority** (`build.sh` uses `nice -n 19`). Never run two heavy builds at once.
- **The log never contains the text being read.** Sizes and counts only.
- **Bookmarks store only a path and a sentence number.** Files handed over by other programs are not remembered.
- **Quit the app only with `osascript ... quit app id`.** No `pkill`.
- **A screenshot from the user is the bug report.** Reproduce it with `OCRProbe` or `axtest`, look at `Probe --prep --text-only`, fix, and show the before and after text.
- **Don't disturb the person at the Mac while testing.** Draw windows off screen (`render`) instead of opening them; flash a highlight for a second, then remove it. Never use `osascript ... activate` on another app: macOS asks the user to give that app control of the Mac.
- **Keep this file current** when something new is learned.

## How we work (Deji and Claude, November 2026)

- Deji judges by feel and listens on real material: Claude replies, books, web pages. He reports with a screenshot and a short line ("she spells this out", "she rushes the list", "it skips part of the table").
- Each report was reproduced from the screenshot first, then traced to the step that caused it. Most "voice" problems weren't the voice: they were the screen reader misreading letters, lines being glued together, or a TextPrep rule firing where it shouldn't.
- Where it's a matter of taste, Claude makes 2 or 3 audio samples and Deji picks (cadence: A, B, C; he chose C).
- Claude builds, installs only when nothing is playing, and says plainly what was checked (the text, the audio transcript) and what wasn't (how it sounds to him).
- Replies short and in plain English.

## Lessons (what went wrong, and why)

| Symptom | Real cause | Fix |
|---|---|---|
| Back button needed several presses | It restarted the current sentence first | 10 s jumps that land on the nearest sentence start |
| Control keys stayed claimed after a stop | A paragraph pause was queued by an old read | Every queued piece checks it belongs to the current read |
| First screen read took 50 s | Vision sets itself up on first use | Warm-up on a tiny image at launch |
| Gutenberg text read as one block | Windows line endings (CRLF) | Normalised |
| EPUB "I T" instead of "It" | Drop cap in its own HTML element | Joined in the HTML step |
| A book opened in 4 s with the app frozen | Text prep on the main thread | Off the main thread, chapters in parallel (about 1 s) |
| EPUBs from Books opened with 0 sentences, or were greyed out | Books keeps EPUBs as folders | Folder support and a picker filter |
| Cloud-only PDFs hung | iCloud download through file coordination stalls | Read the file to trigger download, 60 s limit |
| "Chapter 3 of 24" while in chapter 1 | Chapters taken from the EPUB's internal files | Chapters from the book's own contents page |
| Headings spelled out ("E-S-C-A-P-E-D") | All-capital words treated as abbreviations | Runs of capital words read as words; dictionary check with word endings |
| Books turned the page long before she finished it | Turned as soon as the page was queued | Turn when about 5 s of audio is left |
| A contents page read as one run-on sentence | Page carry-over glued short lines together | Only real prose (8+ words, no full stop) carries over |
| "AI" read as "Al" | Screen reader: capital I and small l look the same | "Al" becomes "AI" unless a name follows |
| A bullet list read in one breath | OCR joined the items; short lines grouped into one piece | Items keep their own lines; a pause after each line |
| "What you hand in" read as a question | Any line starting with a question word got a "?" | After what/how/who..., the next word must be a verb like is/do/can |
| Read stopped at the bottom of the screen and read "Bypass permissions" | Reading pixels sees only what's visible, buttons included | Read the app's own text (AXText) |
| Numbers glued to the previous sentence on a web page | A container with loose words was treated as one paragraph | Only elements made purely of words are paragraphs |
| Rest of a web page skipped | Chrome gives off-screen elements no size; a size filter dropped them | Skip repeated paragraphs instead |
| First table row skipped | A "skip the header row" rule; the header lived elsewhere | Read every row, header included |
| Short table rows run together | Lines of 3 words or fewer were merged into the next | Only one-word lines merge |
| Icon's waveform ran off the edges | The layer image was drawn on a Retina screen, so 2048 px, not 1024 | Draw into a fixed 1024 px bitmap; check with `ictool` |
| Test screenshots never showed the highlight | Screen capture leaves out the app's own windows (on purpose, for OCR) | `includeOurs: true` for debug shots |
| A test highlight didn't appear | Antigravity reported no front window; the chat also auto-scrolls while another session posts | Search every window; test on a still part of the page |
| Library and welcome renders had no text | Dark mode text is white; the off-screen image had no background | Render on the window background colour |
| "read" said as reed where it should be red, or the other way | Same spelling for both; the voice guesses | `sayRead` picks from the words around it (have/was read = red, to/can read = reed). A transcript can't check this: it writes both as "read". Listen |
| Brackets read with no pause, rushed | Brackets were dropped and the aside joined the sentence | `bracketPauses`: mid-sentence brackets become a "…" pause (0.08 s gap, about 0.4 s heard); asides in the first 5 words use commas, since a full pause there made her stumble ("a a robot") |
| The pill stopped appearing (18 Nov) | AppKit believed the pill was visible and opaque while macOS had it off screen, so `show` never ordered it front again | `show` also checks `occlusionState`; a fade that finishes after a new read has started keeps the pill instead of hiding it |
| Welcome hidden under the crosshair's dim | The crosshair brings the app forward, which raised its own windows | Tuck titled windows away while picking; first use shows the welcome first, then the crosshair |
| A "control this Mac" prompt appeared | `osascript tell application ... to activate` from the shell | Never script other apps' focus |

## Open items

- Checked by Claude (17 Nov): highlight position on a list line (screenshot), pill, small player, settings, library, welcome (off-screen renders), export with 3 chapters (ffprobe), idle unload memory.
- Untested: the highlight and scrolling during a real read, Books following along with Books in the background, chapter jumps in Books, the reader window's look, clicking to read in Safari, Notes and Mail, media keys and AirPods, the sleep timer, the voice reloading after an idle unload, the exported audio by ear, drag and drop onto the icon, changing the shortcut.
- Form pages: labels like "0 / 50,000" are read as text (left as is on purpose for now).
- Open-source prep done (18 Nov): FluidAudio comes from GitHub pinned to commit 16780f04 (has the Apple M5 fixes #1137 and #1160; on Deji's Mac a SwiftPM mirror, in the ignored `.swiftpm/configuration/mirrors.json`, builds from the local copy at `~/.local/share/read-aloud/src/FluidAudio` instead, because the 290 MB GitHub download stalled; remove it with `swift package config unset-mirror --original https://github.com/FluidInference/FluidAudio.git`). Debug commands off unless switched on. Credits and licences in the README (Pocket TTS is CC BY 4.0 with credit to Kyutai; FluidAudio Apache 2.0; voices Cosette and Jean are non-commercial). The log folder is made on first run; the icon falls back to the plain .icns without Xcode 26.
- MIT licence added 18 Nov (Deji). At launch: set `Updates.repo`, bump the version to 1.0, make the release zip. Checked by Claude 18 Nov with silent test reads: the voice reloading after an idle unload (first sound about 3 s after the request), the sleep timer (fade from 8 s before, stop on time), sleep at chapter end, a preview in another voice switching back, the update check (found 0.18.3 on a stand-in repo; a missing repo fails quietly), an exported 3-chapter .m4b (chapter marks land on the spoken headings, Deepgram transcript has every word), the microphone check (reads off; her own playback never trips it). Untested: pause for calls on a real call. Still open: whether to keep the bundle id `io.autimized.readaloud`. Each builder makes their own "Read Aloud Dev" certificate with `make-cert.sh`, so that name can stay.

## The name (18 Nov 2026)

The app is called **Earsay** (Deji's pick, 18 Nov): ear + say, a play on "hearsay". Plain "Read Aloud" belongs to Microsoft Edge and a big Chrome extension, and "Hearsay" is crowded (a text-to-speech iPhone app, a known company). Only the visible name changed: the bundle id stays `io.autimized.readaloud`, the signing certificate stays "Read Aloud Dev", the Swift targets stay `ReadAloud`/`ReadAloudCore`, and `~/.local/share/read-aloud/` keeps the log and source, so settings, bookmarks and permissions carry over. The app now lives at `~/Applications/Earsay.app` and exports to `~/Music/Earsay/`. The repo folder `~/My Workspace/read-aloud-app` keeps its name for now.

## The GitHub repo (18 Nov 2026)

`github.com/fvrkdej/earsay`, **private until launch day**, when it goes public together with the LinkedIn post (Deji's call). It starts from one clean commit, so Deji's personal email and the build history stay off GitHub. Work on `main`, which tracks `origin/main`. This repo's git config commits as `Deji Ademosu <114817270+fvrkdej@users.noreply.github.com>` (GitHub's private address). The full build history before that stays local only, on the branch `private-history`. Never push that branch, because every commit on it carries his personal email.
