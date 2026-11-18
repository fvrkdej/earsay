# Earsay

A free Mac app that reads anything to you in a natural voice, entirely on your Mac. No account, no cloud, no subscription. The voice (Pocket TTS, "Azelma") runs on the Mac's own AI chip through [FluidAudio](https://github.com/FluidInference/FluidAudio).

It lives in the menu bar. One shortcut does almost everything: **Control + Option + R**.

## What it reads

- **Highlighted text, in any app.** Highlight, press the shortcut, she reads. Press it again to stop.
- **Anything on screen, without highlighting.** Press the shortcut with nothing highlighted and a crosshair appears. Click a paragraph and she reads from there to the end of that piece (a chat reply, an article, a document), including the part scrolled out of view. A soft highlight follows the paragraph, list line or table row she's reading, and the app scrolls along with her. Drag a box and she reads what's inside it.
- **Books and long files.** EPUB, PDF, Word, RTF, text and Markdown. She skips the cover and contents and starts where an audiobook would. Chapters come from the book's own contents page. She remembers where you stopped.
- **Apple Books.** With a book of your own open, press the shortcut: she finds your page in the file and reads from there, and Books turns its pages to follow her. With a bought (locked) book, she reads the page on screen and turns the pages for you.

## Controls

A small pill appears while she reads: page or chapter back, 10 seconds back, play/pause, 10 seconds forward, page or chapter forward, speed, the reader window, and stop. Click the chapter name for a list of chapters.

While she's reading (and only then), these keys are hers:

| Keys | What they do |
|---|---|
| Control + Option + Space | Pause or carry on |
| Control + Option + Left / Right | 10 seconds back or forward |
| Control + Option + Up / Down | Faster or slower |
| Control + Option + Shift + Left / Right | Previous or next page (Apple Books) |
| Control + Option + Shift + Up / Down | Previous or next chapter |

The keyboard's play/pause key, AirPods taps and the Now Playing panel in Control Center work too. The bars on the pill and in the menu bar move with her voice. Prefer something smaller? Turn on the small player in Settings.

From the menu bar:

- **Library**: every book and file you've opened, with its cover and how far you got. Click one to carry on.
- **Open a file**, or drop one on the menu bar icon.
- **Reader window**: the book's text with the paragraph she's reading highlighted; click any paragraph to jump there.
- **Sleep timer**: 15 minutes to an hour, or the end of the chapter, with a gentle fade.
- **Export as an audiobook**: turns a book into one audio file with chapters (an .m4b if ffmpeg is installed) for your phone. It's made in the background and waits whenever you're listening.
- **Settings**: 27 voices with a sample button, starting speed, your own shortcut, the highlight and scrolling, the small player, pausing when a call starts, open at login, and **pronunciations**: teach her any word (a name, a brand, an acronym) and hear it before and after, in any voice.

The first launch shows a short welcome: what it does, the two permissions, and a paragraph to try it on.

## Privacy

Everything happens on your Mac. Nothing you read is sent anywhere. The app keeps a small log of what it did (never the text it read) at `~/.local/share/read-aloud/app.log`. Bookmarks store only a file's path and a sentence number.

## Permissions

- **Accessibility**: to see highlighted text and the text of the app you click in.
- **Screen Recording**: only for reading off the screen when an app won't share its text, and for Apple Books.

## Install it

You need an Apple Silicon Mac (M1 or newer) on macOS 14 or later.

1. Download the latest zip from the [Releases page](https://github.com/fvrkdej/earsay/releases/latest) and double-click it.
2. Drag **Earsay** into your Applications folder and open it.
3. The first time, macOS says it can't check the app for malicious software. That's because it's a free app without a paid Apple developer account, not because anything's wrong. Open **System Settings > Privacy & Security**, scroll down, and press **Open Anyway**. You only do this once.
4. The welcome walks you through the two permissions.
5. The first time it reads, it downloads the voice once (about 500 MB, usually a minute or two). After that it works with no internet.

When a new version comes out, the menu shows "Update available".

## Build it

Needs macOS 14 or later, an Apple Silicon Mac and Xcode (or the Command Line Tools; Xcode 26 or later gives the icon its dark and tinted styles).

```bash
./scripts/make-cert.sh    # once: a free local signing certificate, so permissions survive rebuilds
./scripts/build.sh        # builds and installs ~/Applications/Earsay.app
open ~/Applications/Earsay.app
```

The first launch downloads the voice model (about 500 MB) into `~/.cache/fluidaudio/Models/pocket-tts`.

For an audiobook with chapters, install ffmpeg (`brew install ffmpeg`). Without it, exports are a single .m4a.

How it works, and how to change it: [docs/DEVELOPING.md](docs/DEVELOPING.md).

## Credits and licences

- **The voice:** [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) by [Kyutai](https://kyutai.org), licensed CC BY 4.0, in the Core ML version by [FluidInference](https://huggingface.co/FluidInference/pocket-tts-coreml). The app downloads the model on first launch; it isn't included here.
- **This app:** MIT licence (see LICENSE).
- **The engine:** [FluidAudio](https://github.com/FluidInference/FluidAudio), Apache 2.0.
- **The voices** come from Kyutai's [tts-voices](https://huggingface.co/kyutai/tts-voices), each under its own licence. Most allow any use with credit. **Cosette** and **Jean** come from non-commercial sets (Expresso and EARS), so don't use those two for anything you sell.
- Kyutai's terms forbid using the model to impersonate a real person or to pass off generated speech as a real recording.
