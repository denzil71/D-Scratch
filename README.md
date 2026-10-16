# D-Scratch

A macOS scratch pad. Pages live in a left-hand sidebar; each page is a rich-text document that can hold images, video and audio, and any page can be locked with a password.

## Features

- **Pages sidebar** — add (⌘N), rename, reorder (drag), delete.
- **Rich text** — format bar (font, size, colour, alignment, lists), ⌘B / ⌘I / ⌘U, font panel (⌘T), colour panel (⇧⌘C), find (⌘F).
- **Media** — drag, paste or Insert Media (⇧⌘I) for images, video and audio. Images scale to the page width; video and audio play inline.
- **Locked pages** — a locked page's content is encrypted on disk and hidden until the password is entered. Lock Now hides it again; ⌘L locks every page. All pages re-lock when the Mac sleeps, the screen locks or the user session switches.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh          # builds build/D-Scratch.app
./build.sh --open   # builds and launches
```

Copy `build/D-Scratch.app` to `/Applications` to install.

## Storage

`~/Library/Application Support/D-Scratch/`

- `index.json` — page titles, order, lock flag and salt.
- `pages/<id>.page` — unlocked pages, flat RTFD.
- `pages/<id>.locked` — locked pages: RTFD sealed with AES-256-GCM, key from PBKDF2-HMAC-SHA256 (310,000 rounds, random 16-byte salt).

## Security notes

- A forgotten password cannot be recovered.
- Page **titles** are not encrypted; only content is.
- Inline video/audio from an unlocked page is written to a temp folder for playback. The folder is cleared on lock and on quit.
- When a page is first locked, the old plaintext file is deleted but not securely erased.
