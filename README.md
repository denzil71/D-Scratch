# D-Scratch

A macOS scratch pad. Pages live in a left-hand sidebar and can be organised into groups and tagged. Each page is a rich-text document that can hold images, video, audio and syntax-highlighted code. Pages can be locked behind a single D-Scratch password, searched all at once, and you can ask Claude questions from the top of any page.

## Features

### Pages and groups
- **Pages** — ⌘N or **New Page** at the bottom of the sidebar adds a page where you are: inside the selected group, alongside the selected page (in its group, or at the top level), or at the top level if nothing is selected. It asks for a name. Right-click a page to rename, move, lock or delete it. Drag to reorder.
- **Groups and subgroups** — ⇧⌘N or **New Group** at the bottom of the sidebar adds a collapsible group — inside the selected group (or the selected page's group), so groups nest into a tree to any depth; right-click a group → **New Subgroup** does the same. Click a group's name to select it; the page area then shows its path, page count and **New Page in Group** / **New Subgroup** buttons. Drag pages into, out of and between groups, or right-click a page → **Move to Group**. Drag a group onto another group to nest it (or into the top-level pages to un-nest it), or right-click → **Move Group To**. Right-click a group to add a page or subgroup, rename it, tag it, lock or unlock every page in it and its subgroups at once, or delete it — **Delete Group (Keep Pages)** moves its pages and subgroups up one level; **Delete Group and Pages…** deletes it with everything inside after confirming (unlock first if any of those pages are locked).
- **Tags** — the bar at the top of each page shows its tags as coloured chips. **+** adds an existing tag or creates a new one (names are one word; spaces become hyphens); **×** removes one. Right-click a group → **Tags…** to tag the whole group: every page in it and its subgroups inherits those tags, shown with a folder icon (hover to see which group) on the page. Clicking a tag searches for it. Tag colour dots appear next to pages and groups in the sidebar. New tags get a random colour; rename, recolour or delete tags in **Settings › Tags**.
- **Search** — the sidebar search field searches every page's title and text, case- and accent-insensitively. Add `#tag` to filter by tag (prefix match, including tags inherited from a group; several `#tags` must all match) — on its own it lists every page with that tag, and with other words it searches only those pages. The tag chips under the search field toggle tag filters. Results are listed by page (shown with its full path, e.g. *Work › Clients › Page*); click one to open the page with the match highlighted. Locked pages are only searched while unlocked.

### Writing
- **Rich text** — format bar above the text (font, size, colour, alignment, lists), ⌘B / ⌘I / ⌘U, font panel (⌘T) and colour panel (⇧⌘C). Text follows light and dark mode.
- **Code blocks** — pasted code is detected and placed in a boxed, syntax-highlighted block. Type ``` and press Return to start a block, or select lines and choose **Format › Code Block** (⌥⌘K) to convert them (and back). Return on an empty last line leaves a block; ↑/↓ or a click above or below a block at the very top or bottom of a page adds a text line there. Highlighting covers comments, strings, numbers, keywords, types and function calls across common languages (Swift, Python, JavaScript/TypeScript, C-style, SQL, shell). Pick the colour scheme in **Settings › Code**.
- **Media** — drag, paste or **Page › Insert Media…** (⇧⌘I) for images, video and audio. Images scale to the page width; video and audio play inline.

### Open With
Right-click a file in Finder → **Open With → D-Scratch**, or drop it on the Dock icon, to import it as a new page named after the file:
- Text, Markdown, RTF/RTFD, Word, HTML and OpenDocument files become rich text (Markdown is rendered).
- Source code, scripts, JSON, XML and YAML become a code block, as does a plain-text file that looks like code.
- Images, video and audio are embedded.

D-Scratch registers as an *alternate* app for these types, so it never becomes the default for opening them.

### Locked pages
- One D-Scratch password locks and unlocks every locked page. Set or change it in **Settings › Security**; the first time you lock a page without one, D-Scratch asks you to create it.
- Lock a page with the toolbar **Lock Page** button or right-click → **Lock Page**; right-click a group → **Lock All Pages in Group** to lock its pages in one go.
- Entering the password unlocks every locked page. A page you lock while unlocked stays visible (open-lock icon) until everything locks again.
- Everything locks again after the auto-lock timeout (minutes of inactivity, set in Settings; 0 = never), with **Page › Lock All Pages** (⌘L) or the toolbar **Lock All** button, and when the Mac sleeps, the screen locks or the user session switches.
- While unlocked, right-click → **Remove Lock** decrypts a page permanently.
- A locked page can't be renamed or deleted until it's unlocked.

### Backup to iCloud
Turn on **Settings › Backup › Back up to iCloud Drive automatically** to save backups to **iCloud Drive › D-Scratch Backups**, every hour, day or week (only when something has changed), keeping the newest N. **Back Up Now**, **Show in Finder** and **Restore…** are in the same tab.

- Every backup is **encrypted on your Mac before it's saved** to iCloud Drive: a zip of all D-Scratch data, encrypted with X25519 + HKDF-SHA256 + AES-256-GCM to a backup key pair whose private key is protected by your D-Scratch password. Nothing readable — not even page titles — reaches iCloud.
- Backups run while your pages are locked; **restoring needs the D-Scratch password that was set when the backup was made** (so after changing your password, older backups still use the old one). This works on a new Mac too.
- A D-Scratch password is required (Settings › Security). If you set one before this feature existed, unlock once to finish setting up.
- Restoring replaces all pages, groups, tags and the password with the backup's. Your current data is kept first in a *D-Scratch before restore …* folder next to the data folder.
- Backups use your iCloud Drive folder rather than an app-specific iCloud container, which would need a paid Apple Developer ID.

### Ask Claude
The bar at the top of each page sends a question to Claude, streams the answer into a preview, then appends it to the page under a *Claude: your question* heading (Markdown in the answer becomes rich text; code becomes a code block). **Use page** sends the page's text as context; **Stop** cancels.

Two ways to connect, chosen in **Settings › Claude**:
- **Claude account (default)** — uses the account you're logged in to in [Claude Code](https://claude.com/claude-code), such as a Pro plan, so no API key is needed and usage counts toward that plan. Run `claude` once in Terminal to log in; Settings shows who you're logged in as. Models: *Default for your plan*, Opus, Sonnet or Haiku. Tick **Use caveman** for shorter answers — it loads the [caveman](https://github.com/JuliusBrussee/caveman) plugin for each request and requires that plugin to be installed locally in Claude Code.
- **API key** — calls the Claude API directly with your key (stored in the Keychain). Models: Claude Opus 5.5, Sonnet 5.5 or Haiku 4.5.

## Settings (⌘,)

| Tab | Options |
|---|---|
| Security | Set or change the D-Scratch password; auto-lock timeout in minutes of inactivity. |
| Tags | Rename tags, change their colours, see how many pages and groups use each, delete tags, add new ones. |
| Backup | Automatic encrypted backups to iCloud Drive: on/off, how often, how many to keep; Back Up Now, Show in Finder, Restore. |
| Code | Code colour scheme: Automatic (follows light/dark), Light, Dark, Solarized Light, Dracula — with a live preview. |
| Claude | Claude account or API key; model; Use caveman (Claude account only). |

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New page |
| ⇧⌘N | New group |
| ⇧⌘I | Insert image, video or audio |
| ⌘L | Lock all pages |
| ⌥⌘K | Code block on/off for the selected lines |
| ⌘B / ⌘I / ⌘U | Bold / italic / underline |
| ⌘T | Font panel |
| ⇧⌘C | Colour panel |
| ⌘, | Settings |

## Install

Download the latest `D-Scratch-<version>.dmg` from [Releases](https://github.com/denzil71/D-Scratch/releases), open it and drag **D-Scratch** onto **Applications**. Requires macOS 13 or later; runs on Apple Silicon and Intel Macs.

The app isn't signed with an Apple Developer ID, so macOS blocks it the first time. To open it once:
- Right-click **D-Scratch** in Applications → **Open** → **Open**, or
- try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

If macOS says the app "is damaged", remove the download quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/D-Scratch.app
```

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools). The Claude account option also needs [Claude Code](https://claude.com/claude-code) installed and logged in.

```sh
./build.sh          # builds a universal build/D-Scratch.app and registers it for Open With
./build.sh --open   # builds and launches
./build.sh --dmg    # also packages dist/D-Scratch-<version>.dmg (version from Resources/Info.plist)
```

Copy `build/D-Scratch.app` to `/Applications` to install your own build.

To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, run `./build.sh --dmg`, then attach the DMG to a new GitHub release (Releases → Draft a new release, or `gh release create v<version> dist/D-Scratch-<version>.dmg`).

For testing, set `DSCRATCH_DATA_DIR` to use a different data folder, e.g. `open --env DSCRATCH_DATA_DIR=/tmp/ds -a build/D-Scratch.app`.

## Storage

`~/Library/Application Support/D-Scratch/`

- `index.json` — page titles, order, group, tags and lock flag.
- `groups.json` — group names, order, parent group, expanded state and tags.
- `tags.json` — tag names and colours.
- `vault.json` — a random 256-bit data key, wrapped (AES-256-GCM) by a key derived from the D-Scratch password with PBKDF2-HMAC-SHA256 (310,000 rounds, random 16-byte salt). Changing the password only re-wraps this key. Also holds the backup public key and the backup private key sealed with the data key.
- `pages/<id>.page` — unlocked pages, flat RTFD. Code blocks are stored as Menlo paragraphs; their colours are recomputed when a page opens.
- `pages/<id>.locked` — locked pages: RTFD sealed with AES-256-GCM under the data key.

The Claude API key is stored in the macOS Keychain. Other settings (auto-lock minutes, code scheme, Claude connection, models, Use caveman, Use page) are in the app's user defaults.

Backups: `~/Library/Mobile Documents/com~apple~CloudDocs/D-Scratch Backups/D-Scratch Backup <date>.dscratch-backup` — a small header (salt, wrapped keys, ephemeral public key) followed by the AES-GCM-encrypted zip.

Pages locked by v0.1 with their own password keep working: unlock with the D-Scratch password, then enter the page's old password once to move it over.

## Security notes

- A forgotten password cannot be recovered.
- Page **titles** and **tags** are not encrypted; only content is.
- With **Use page** ticked, Ask Claude sends the page's text — including a locked page's, while unlocked — to Claude (through Claude Code or the API, whichever is selected).
- The Claude account option runs the local `claude` CLI with no tools, no settings, plugins (other than caveman, if ticked) or MCP servers, and no saved session, from an empty temporary folder. It's intended for personal use on your own Mac.
- Backups are encrypted before upload; a forgotten D-Scratch password means its backups can't be restored either.
- Inline video/audio from an unlocked page is written to a temp folder for playback. The folder is cleared on lock and on quit.
- When a page is first locked, the old plaintext file is deleted but not securely erased.
