# D-Scratch

A macOS scratch pad. Pages live in a left-hand sidebar; each page is a rich-text document that can hold images, video and audio, and any page can be locked with a password.

## Features

- **Pages sidebar** — add (⌘N), rename, reorder (drag), delete.
- **Groups** — New Group (⇧⌘N or the folder button) adds a collapsible group. Drag pages into, out of and between groups, or right-click a page → Move to Group. ⌘N adds a page to the selected page's group. Right-click a group to add a page, rename it, lock every page in it at once, or delete the group (its pages move to the top level).
- **Rich text** — format bar (font, size, colour, alignment, lists), ⌘B / ⌘I / ⌘U, font panel (⌘T), colour panel (⇧⌘C), find (⌘F).
- **Code** — pasted code is detected and placed in a boxed, syntax-highlighted block. Type ``` and press Return to start a block, or select text and choose Format › Code Block (⌥⌘K). Return on an empty last line leaves the block; ↑/↓ or a click above or below a block at the very top or bottom of a page adds a text line there. Choose the colour scheme (Automatic, Light, Dark, Solarized Light, Dracula) in Settings › Code. Code in Claude's answers is boxed too.
- **Open With** — right-click a file in Finder → Open With → D-Scratch (or drop it on the Dock icon) to import it as a new page named after the file. Text, Markdown, RTF/RTFD, Word, HTML and OpenDocument files become rich text; source code becomes a code block; images, video and audio are embedded. D-Scratch is registered as an alternate app, so it never becomes the default for these files.
- **Media** — drag, paste or Insert Media (⇧⌘I) for images, video and audio. Images scale to the page width; video and audio play inline.
- **Locked pages** — one D-Scratch password (set or change it in Settings, ⌘,) locks and unlocks every locked page. Unlocking once opens them all; they lock again after the auto-lock timeout (minutes of inactivity, set in Settings), on ⌘L, or when the Mac sleeps, the screen locks or the user session switches.
- **Search** — the sidebar search field searches every page's title and text. Locked pages are searched only while unlocked. Click a result to jump to it.
- **Ask Claude** — the bar at the top of each page sends a question (optionally with the page's text as context) to Claude and appends the answer to the page. By default it uses the Claude account you're logged in to in [Claude Code](https://claude.com/claude-code) (e.g. a Pro plan; run `claude` once in Terminal to log in), so no API key is needed and usage counts toward that plan. Settings → Claude can switch to an API key instead. With your Claude account, tick **Use caveman** for shorter answers: it loads the [caveman](https://github.com/JuliusBrussee/caveman) plugin for that request (requires the plugin installed locally in Claude Code).

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh          # builds build/D-Scratch.app
./build.sh --open   # builds and launches
```

Copy `build/D-Scratch.app` to `/Applications` to install.

## Storage

`~/Library/Application Support/D-Scratch/`

- `index.json` — page titles, order, lock flag and group.
- `groups.json` — group names, order and expanded state.
- `vault.json` — a random 256-bit data key, wrapped (AES-256-GCM) by a key derived from the D-Scratch password with PBKDF2-HMAC-SHA256 (310,000 rounds, random 16-byte salt). Changing the password only re-wraps this key.
- `pages/<id>.page` — unlocked pages, flat RTFD.
- `pages/<id>.locked` — locked pages: RTFD sealed with AES-256-GCM under the data key.

The Claude API key is stored in the macOS Keychain. Settings (auto-lock minutes, model) are in the app's user defaults.

Pages locked by v0.1 with their own password keep working: unlock with the D-Scratch password, then enter the page's old password once to move it over.

## Security notes

- A forgotten password cannot be recovered.
- Using your Claude account runs the local `claude` CLI with no tools, no settings, plugins or MCP servers, and no saved session, from an empty temporary folder. This is for personal use on your own Mac.
- With "Use page" ticked, Ask Claude sends the page's text — including a locked page's, while unlocked — to the Claude API.
- Page **titles** are not encrypted; only content is.
- Inline video/audio from an unlocked page is written to a temp folder for playback. The folder is cleared on lock and on quit.
- When a page is first locked, the old plaintext file is deleted but not securely erased.
