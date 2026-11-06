# AGENTS.md

Guidance for AI agents working in this repository.

## Language

- Talk to the user in Brazilian Portuguese. Everything else is in English: documentation, code, comments, identifiers, commit messages and pull requests. `README.pt-BR.md` and `README.es.md` are the Portuguese and Spanish copies of `README.md`; keep the three in sync.
- The interface is in English, with Brazilian Portuguese and Spanish translations. Visible text is written in English in code and works as the key; translations live in `App/Localizable.xcstrings`, `Keyboard/Localizable.xcstrings` and `App/InfoPlist.xcstrings` (permission prompts). Every new string goes into all three languages, in the catalog of the target that uses it. A literal in `Text`, `Label` or `Button` is already localizable; a `String` needs `String(localized:)`; names that are never translated use `Text(verbatim:)`.

## Interface

- Use as little text as possible: short phrases, and SF Symbols where they help. Steps in a sequence use numbers, not icons.
- The keyboard is never taller than Apple's. `standardHeight(for:)` in `KeyboardViewController` matches Apple's keyboard with its suggestion bar; the height comes from a constraint on the root view, just below required, activated only in `updateViewConstraints` after `viewWillAppear` (earlier, iOS draws it taller for a frame or two). The SwiftUI content never sets the height.
- The keys match Apple's in size, margins, corners and colors, light and dark (`KeyBackground`). Rows: punctuation (`. , ? ! '`) and delete, then space and return (`KeyRow` sets each key's width); in landscape on the iPhone they share one row. While recording, delete becomes an X that cancels.
- The microphone button's touch area is larger than its circle (`drawingScale`), so the recording pulse fits. The hint row has a fixed height and shrinks its text to fit one line.
- Destructive or heavy actions ask first, in alerts (always centered). Tapping any model opens an alert that says what it is good for: Download for one not on the device, Use for one already downloaded, only OK for the one in use, and only OK for the model that is loading and for every model while a download or the update check runs (rows look locked then, but stay tappable).
- A tap outside a text field closes the app's keyboard (`TapOutsideDismissesKeyboard`, which never takes taps from buttons). Do not attach tap gestures to the whole `Form`.
- Main screen order: status, Try it here, History, Options, Model, Setup, About. On first launch it scrolls to Setup once (`hasShownSetup`). The source code link in About shows only when `AppInfo.showsRepositoryLink` is on; it is off for now.

## Running commands

Run long commands (`xcodebuild`, device installs) in the background with output in a fixed-name log in `/tmp` (for example `/tmp/whisper-keyboard-build.log`). Read the whole log before saying something worked.

## Documentation

No fast-aging data in `.md` files (sizes, durations, counts, versions): say where the value is defined instead. When changing code, review the `.md` files that describe it. `README.md` is for people who install and use the app: plain language, no code details.

## Git and security

If the user has staged files, never touch the index (`git stash`, `reset`, `restore --staged`, `checkout`); edit on top. Commit and push only when the user asks.

The repository is public. Signing data (developer team, personal identifiers) lives only in `Config/Local.xcconfig`, which git ignores. Before a commit, search the files going into git for keys, tokens, e-mail addresses and developer teams.

## Overview

An iPhone keyboard that transcribes speech with Whisper, entirely on the device. The keyboard has a big microphone button (hold to talk, or tap to start and stop), punctuation keys, space, return and delete; the globe is iOS's own or, when iOS asks (`needsInputModeSwitchKey`), the keyboard's. Spaces around each transcription are added automatically (`TextSpacing`). MIT license (`LICENSE`, also shown in the app). The home screen name is "Whisper" (`project.yml`); the app is Whisper Keyboard.

- `App/`: the app (SwiftUI): microphone, model download and load, transcription, history, setup, options, About.
- `Keyboard/`: the keyboard extension (SwiftUI in a `UIInputViewController`).
- `Shared/`: in both targets: the channel between them (`VoiceChannel.swift`) and `TextSpacing.swift`.
- `Tests/`: unit tests (`WhisperKeyboardTests`).
- `project.yml`: the XcodeGen project; the `.xcodeproj` is generated and not versioned.
- `Config/`: `Project.xcconfig` (bundle prefix, App Group) and the `Local.xcconfig` example.
- `scripts/make-icon.swift`: draws the icon (`swift scripts/make-icon.swift <output.png>`); copy it to the `AppIcon` set, and a copy resized with `sips -Z` to the `Logo` set.

## Commands

Build for the simulator (the scheme's Run uses Release; use Debug to keep the test hooks):

```bash
xcodegen generate
xcodebuild -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard -configuration Debug -destination 'platform=iOS Simulator,name=<iPhone simulator>' -derivedDataPath build/DerivedData build
```

Install and open (the language arguments only change the app's language, not the simulator's):

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/WhisperKeyboard.app
xcrun simctl launch booted com.eberty.whisperkeyboard -AppleLanguages "(pt-BR)" -AppleLocale pt_BR
```

On an iPhone: fill in `Config/Local.xcconfig` from the example (`DEVELOPMENT_TEAM`, and `BUNDLE_ID_PREFIX` for another account), build with `-configuration Release -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates`, then `xcrun devicectl device install app --device <udid> <path to the .app>` (`xcrun devicectl list devices` lists the udid).

Unit tests run inside the app, which then skips the model and the microphone (`VoiceSession.isTesting`); they cover the pure logic, not the microphone, transcription or keyboard switching:

```bash
xcodebuild test -project WhisperKeyboard.xcodeproj -scheme WhisperKeyboard -configuration Debug -destination 'platform=iOS Simulator,name=<iPhone simulator>' -derivedDataPath build/DerivedData
```

To validate a change: run the tests, build, install on the simulator and run the end-to-end test.

### End-to-end test on the simulator

1. Install on top (`simctl install`), never uninstall: that deletes the model and turns off Full Access. On the simulator WhisperKit runs on the CPU, so it is much slower than on an iPhone. With two simulators booted, `booted` is ambiguous: use the device id.
2. In Settings, Apps, Whisper, Keyboards, turn on Whisper Keyboard and Allow Full Access (if automated taps do not flip them, ask the user).
3. In the app's text field, switch to Whisper Keyboard with the globe.
4. The simulator cannot receive speech. In debug builds, `Documents/inject.wav` in the app's container replaces the microphone's audio: make it with `say` (Luciana, Samantha, Mónica) and `ffmpeg` (16 kHz mono). `xcrun simctl get_app_container <device> com.eberty.whisperkeyboard data` gives the container; `groups` gives the one with `state.json`. Launching with `-benchmark` transcribes each `Documents/benchmark/*.wav` in automatic mode and in fixed Portuguese into `Documents/benchmark.txt`.
5. Test both gestures, the X, insertion with automatic spaces, delete held down, punctuation, space, return, switching keyboards mid-recording, history, vocabulary, model alerts, downloads (cancel, failure and resume) and the closed-app case. Take screenshots so the user can follow along.
6. Test the three languages and the iPad.

## Architecture

- **The keyboard neither records nor transcribes.** Extensions have no microphone and little memory, so the model and the microphone live in the app; the keyboard sends commands and receives text.
- **Channel** (`Shared/VoiceChannel.swift`): Darwin notifications only wake the other side and carry no data (any app can post or observe them, so it could tell when someone dictates, never what). Data lives in App Group files only the two targets can write: the keyboard's `VoiceCommand` (`command.json`) and the app's `VoiceState` (`state.json`). The app runs each command once and only within `commandLifetime`. When the app is closed it writes `off` (`willTerminateNotification`), so the keyboard turns gray at once. The keyboard needs Full Access; without a pong within `pongTimeout` it treats the app as closed, and its button opens the app with `whisperkeyboard://start`, as it does while the model loads. While recording it pings every `heartbeatInterval`; after `heartbeatTimeout` of silence the app discards the recording.
- **Opening from the keyboard** (`App/BackHintView.swift`): the keyboard writes a `wake` request, then opens the app, which shows how to swipe back (`handleWakeURL`), or to swipe up when there is no app to go back to (home screen search), and turns the mic on. Opening from the icon turns the mic on only when coming from the background (`cameFromBackground`); a link from elsewhere only opens it (`openedByLink`). No recording starts without a keyboard command.
- **Microphone** (`App/AudioRecorder.swift`): iOS does not let a background app start recording, so the app keeps `AVAudioEngine` running (the `audio` background mode, hence the mic indicator), with `mixWithOthers`. Audio is buffered only between start and stop, with a short pre-roll. A recording stopped by a call, another app, a route change the recorder cannot recover from or `maxRecordingSeconds` is transcribed up to that point; turning the mic off meanwhile keeps its text in History only. A new recording never starts with audio from before the previous one. The mic turns off from the app's button or after the idle time in the options (background time only), but stays on while a model downloads or loads, since it keeps the app alive.
- **Recording and the keyboard going away** (`Keyboard/KeyboardModel.swift`): while recording, the keyboard keeps the screen from locking (`keepScreenAwake`, restoring the host app's own setting after). If the keyboard goes away mid-recording (lock, another keyboard), it stops instead of cancelling (`disappear`): the text goes to History and is typed if the keyboard comes back in time. The app tags each result with the start command of its recording (`VoiceState.recordingID`), and the keyboard types a result only if it comes from its own recording, also when it never went away (`awayRecordingID`, a static, because iOS creates a new controller when the keyboard comes back), so text from another app is never typed. A recording the keyboard did not start is cancelled when it appears.
- **Status** (`VoiceSession.currentStatus`): recording and transcribing win over a model loading, so a model switch never blocks dictation; the keyboard starts from the last `state.json`, so its first frame does not flash "off".
- **Gestures**: releasing after `holdThreshold` stops (push to talk); releasing earlier keeps recording until the next tap. Delete repeats while held and switches to words after `repeatsBeforeWords`.
- **Models** (`App/ModelManager.swift`): the app ships without a model and downloads the default (`defaultID`, Balanced) from WhisperKit's public repository on first launch. Each level (Light, Balanced, Best) is a name pattern in `tiers`, because names change with new versions; the refresh button picks the newest name for each (`newest`, saved in `catalog`). A newer version of the model in use downloads right away on Wi-Fi (`VoiceSession.checkForUpdates`; on cellular or Low Data Mode it waits for the user); others show an update arrow.
  - Downloads: progress is the bytes on disk against the size in the name (`downloadedFraction`). A download counts only when every file the repository lists is on disk (`downloadModel`); WhisperKit's network monitor is turned off at launch, because it can stay stuck offline and then accept a partial model. A download that has not finished keeps its files, also across launches (`partial-model`), until a download of another model starts, so trying again resumes; cancelling deletes them. The list is locked while downloading or checking.
  - Loads: picking another model while one loads drops that load (`loadGeneration`); Core ML cannot stop it, so the new load starts when it ends, one at a time (`waitingLoad`). Tapping the model in use then keeps it (`keepCurrentModel`) and deletes the one dropped if it was waiting to load, so it does not replace the kept one on the next launch. If the model in use fails to load, its alert offers to try again (`retryInstalledModel`).
  - Files: `installed-model` is the model that last loaded, `pending-model` one downloaded but not loaded yet (kept and retried if its load fails), `previous-model` the replaced one, kept for `previousModelLifetime` so switching back needs no download, and `partial-model` a download that has not finished. On launch anything else is deleted; tokenizers are small and all stay. Everything is in Application Support, outside backups. Downloads and the update check are the only network uses.
- **Options** (`App/AppSettings.swift`): input language (automatic or fixed), idle time, keep history, and a vocabulary added to the prompt, limited to what fits in `maxPromptTokens` (`vocabularyFits`). The app is simple on purpose; do not add options unless the user asks.
- **Transcription** (`App/WhisperTranscriber.swift`): no GPU (iOS denies it in the background): mel on the CPU, encoder and decoder on the Neural Engine. In automatic mode the language is detected during the transcription, among `languages` only (`LanguageLimitedTokenizer`). A style sentence (`automaticPrompt` or `prompts`) plus whole vocabulary words fit in `maxPromptTokens`, kept well below WhisperKit's limit because the prompt shares each window's token budget. A fixed language translates sentences spoken in another one. Short audio and output with no letters are dropped, and so is a recording whose loudest 30 ms stays below `silenceLevel` (silence or room noise), on which Whisper invents short phrases.
- **Core ML cache**: the first load after an install prepares the model for the chip, which takes minutes. `clearStaleDeviceCache` deletes the cache when the app's bundle path or the iOS version changes; within one install, the copies that appear while a model loads are recorded for it (`CoreMLCache`) and deleted with it.
- **Minimal retention:** audio is never saved. History (`App/TranscriptHistory.swift`) keeps the last `limit` items, outside backups, unreadable while locked, behind Face ID (`LockedHistoryView`), and can be turned off (which deletes it). `state.json` keeps a result only for `resultLifetime`, and the shared files are unreadable while the device is locked. A copy from History is cleared from the clipboard after `lifetime` (`TemporaryCopy`, which saves the deadline), not with the clipboard's expiration, because an expired item still looks pasteable. `PrivacyCover` hides the screen from the app switcher.
