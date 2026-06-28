# pi-listen

`pi-listen` is a local `pi-package` scaffold for streaming speech-to-text input into Pi Coding Agent.

This repo packages the initial architecture from the shared Gemini conversation into a shape that Pi can actually install:

- a committed `dist/` entry point exported through `package.json`
- a Pi extension that exposes `/listen`, `/listen-stop`, and `/listen-status`
- a Perl UNIX-socket bridge that can run in `--demo` mode, forward a custom transcript command, or launch the bundled speech-to-text command

## Commands

- `/listen` starts the bridge and bundled speech-to-text command
- `/listen --demo` runs a fake transcript stream for end-to-end UI testing
- `/listen-stop` stops the bridge and clears the overlay
- `/listen-status` shows the current runtime state

## Environment

- `PI_LISTEN_WHISPER_CMD`: optional shell command that emits transcript frames instead of the bundled backend
- `PI_LISTEN_MODEL`: optional model label forwarded to the bridge
- `PI_LISTEN_SHORTCUT`: optional Pi shortcut to register and show in startup help

## Bundled Speech-to-Text

`/listen` uses [bin/pi-listen-stt.mjs](/Users/nwaddell/git/pi-listen/bin/pi-listen-stt.mjs) when `PI_LISTEN_WHISPER_CMD` is not set.

- macOS: uses the operating system Speech and AVFoundation frameworks through the bundled Swift backend.
- Windows: uses the built-in .NET `System.Speech` recognizer through the bundled PowerShell backend.
- Linux: currently emits a clear error because there is no broadly available default OS speech-to-text CLI. Set `PI_LISTEN_WHISPER_CMD` to a local or cloud STT command on Linux.

On macOS, transcription requires both Microphone and Speech Recognition permission for the terminal or app that launches Pi. If `/listen` reports `Speech recognition permission was not granted.`, enable it in System Settings under Privacy & Security, then restart Pi.

`PI_LISTEN_WHISPER_CMD` should emit one transcript frame per line. Supported formats:

```text
streaming<TAB>partial transcript
final<TAB>final transcript
error<TAB>error message
```

Any non-empty line without a prefix is treated as a `final` transcript.

## Layout

```text
pi-listen/
├── bin/
│   ├── pi-listen-bridge.pl
│   ├── pi-listen-darwin.swift
│   ├── pi-listen-stt.mjs
│   └── pi-listen-windows.ps1
├── dist/
│   ├── index.d.ts
│   └── index.js
└── src/
    └── index.ts
```

## Install shape

The important packaging detail is the `pi.extensions` manifest entry in [package.json](/Users/nwaddell/git/pi-listen/package.json), with the runtime entry committed in [dist/index.js](/Users/nwaddell/git/pi-listen/dist/index.js).

## Testing

Run the Perl suite under `prove`:

```bash
npm run test:perl
```

Run coverage with an 80% floor:

```bash
npm run coverage:perl
```

That coverage command expects `Devel::Cover` to be installed locally. The test suite itself only requires core Perl plus `Test::More`.

## Verification

```bash
npm run check
```
