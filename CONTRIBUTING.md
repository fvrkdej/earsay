# Help make Earsay better

Earsay started as one person's fix for reading, and it gets better every time someone uses it on something new. You don't need to write code to help.

## Ways to help, no code needed
- **A word she says wrong.** Open an issue with the "She said it wrong" form: the text as you saw it, what she said, and what she should have said. Names, places, jargon, numbers, links and abbreviations are all welcome.
- **An app where the highlight gets lost** or reads the wrong part. Say which app, what you clicked, and add a screenshot if you can.
- **Something that broke.** The "Something went wrong" form asks for what matters.
- **An idea.** Open an issue and describe what you'd want it to do and why.

## Ways to help with code
1. Read `docs/DEVELOPING.md` first. It explains how the app works start to finish, every file, the test tools, and the rules (most were learned the hard way).
2. Build it: `./scripts/make-cert.sh` once, then `./scripts/build.sh` (see "Build it" in the README). You need an Apple Silicon Mac on macOS 14 or later and Xcode's command line tools.
3. For anything she says wrong, start with `Probe <file> --prep --text-only`. It prints exactly what she would say, so you can see the problem and prove the fix. Most pronunciation fixes are a rule in `Sources/ReadAloudCore/TextPrep.swift`.
4. Keep a change small and about one thing. Say in the pull request what was wrong, what you changed, and how you checked it.

## Good places to start
- Pronunciation rules in `TextPrep.swift` (the most common reports).
- Apps where the on-screen highlight doesn't follow her (`AXText.swift`, `Highlighter.swift`).
- Running on older Macs or older macOS versions.
- Other voices and languages.

## Be kind
Be patient and kind with each other. Everyone here is volunteering their time.
