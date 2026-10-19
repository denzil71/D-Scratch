# D-Scratch

A macOS scratch pad. Pages live in a left-hand sidebar; each page is a rich-text document that can hold images, video and audio, and any page can be locked with a password.

## Features

- **Pages sidebar** — add (⌘N), rename, reorder (drag), delete.
- **Rich text** — format bar (font, size, colour, alignment, lists), ⌘B / ⌘I / ⌘U, font panel (⌘T), colour panel (⇧⌘C), find (⌘F).
- **Media** — drag, paste or Insert Media (⇧⌘I) for images, video and audio. Images scale to the page width; video and audio play inline.
- **Locked pages** — one D-Scratch password (set or change it in Settings, ⌘,) locks and unlocks every locked page. Unlocking once opens them all; they lock again after the auto-lock timeout (minutes of inactivity, set in Settings), on ⌘L, or when the Mac sleeps, the screen locks or the user session switches.
- **Search** — the sidebar search field searches every page's title and text. Locked pages are searched only while unlocked. Click a result to jump to it.
- **Ask Claude** — the bar at the top of each page sends a question (optionally with the page's text as context) to Claude and appends the answer to the page. Add your API key and pick a model in Settings → Claude.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh          # builds build/D-Scratch.app
./build.sh --open   # builds and launches
```

Copy `build/D-Scratch.app` to `/Applications` to install.

## Storage

`~/Library/Application Support/D-Scratch/`

- `index.json` — page titles, order and lock flag.
- `vault.json` — a random 256-bit data key, wrapped (AES-256-GCM) by a key derived from the D-Scratch password with PBKDF2-HMAC-SHA256 (310,000 rounds, random 16-byte salt). Changing the password only re-wraps this key.
- `pages/<id>.page` — unlocked pages, flat RTFD.
- `pages/<id>.locked` — locked pages: RTFD sealed with AES-256-GCM under the data key.

The Claude API key is stored in the macOS Keychain. Settings (auto-lock minutes, model) are in the app's user defaults.

Pages locked by v0.1 with their own password keep working: unlock with the D-Scratch password, then enter the page's old password once to move it over.

## Security notes

- A forgotten password cannot be recovered.
- With "Use page" ticked, Ask Claude sends the page's text — including a locked page's, while unlocked — to the Claude API.
- Page **titles** are not encrypted; only content is.
- Inline video/audio from an unlocked page is written to a temp folder for playback. The folder is cleared on lock and on quit.
- When a page is first locked, the old plaintext file is deleted but not securely erased.
