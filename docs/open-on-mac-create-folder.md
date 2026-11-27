# Open on Mac: folders from iPhone

Canopy Mobile's **Open on Mac → Folders** tab picks the folder a new live session starts in: No folder, Browse…, or a recent folder. Browse can also create a directory first. The phone side is `RemoteFolder.swift` and `OpenOnMacView.swift` (`FolderBrowserView`, `NewRemoteFolderSheet`).

## Browsing up

Browse… starts at the parent of the first recent folder (`browseRoot`; `/` when there are none), so the first screen is often something like `~/repos/Work`. The top row of every browser screen is its parent folder, up to `/`. Tapping it goes Back when the parent is the screen below (`previousPath`); otherwise the same screen switches to the parent in place. Pushing a new screen per step up made Back walk down again and let the stack grow without limit. When a folder cannot be listed (typically a parent after moving up), the error screen offers "Back to <last listed folder>"; otherwise the only way out would be leaving the browser.

Paths from the Mac are handled with string operations only (`RemoteFolder.parent(of:)`, `canonical(_:)`). `NSString.standardizingPath` consults the iPhone's file system (it drops `/private` when `/var` exists locally), so it must not touch Mac paths.

## No folder

Canopy's No folder is `~/Library/Application Support/Canopy/no-folder` on the Mac (`NoFolder.directory` in Canopy). The control API does not report it: `list_folders` returns recent folders only. The phone calls `browse_dir` with no `path`, which lists the Mac's home and echoes its path, and builds the No folder path from that (`RemoteFolder.noFolderPath(home:)`). The path is a copy of Canopy's constant; if Canopy moves it, the phone must change too.

The folder may not exist yet. Canopy 3.24.3+ creates it when a mirror `open` names it (`MirrorServer`, `NoFolder.prepare()`). An older Mac refuses with `cannot open`, which the phone shows as "its folder or transcript is gone". That message is wrong for this case, but every Mac in use is newer.

## Mac control verb: `mkdir`

The phone uses Canopy's existing `mkdir` verb, the same one a peer Mac's folder browser uses. It has shipped since Canopy 3.0.0, so no Mac update is needed.

**Request params**

| Field | Type | Meaning |
| --- | --- | --- |
| `parent` | string | Parent directory (absolute path), same meaning as `browse_dir`'s `path` |
| `name` | string | Single path segment; no `/`. Trimmed on both sides |

**Success result:** `path`, the absolute path of the created directory.

**Errors** (shown verbatim unless `RemoteFolder.mapFailed` rewrites them): `already exists`, `permission denied` (Canopy 3.6.2+; older builds say `cannot create folder`), `not a folder`, `path must be absolute`, and the name rules' own messages such as `That name is reserved.`

```json
{"type":"request","id":"…","verb":"mkdir","params":{"parent":"/Users/me/Projects","name":"new-app"}}
{"type":"response","id":"…","result":{"path":"/Users/me/Projects/new-app"}}
```

## Remote SSH panes

The folder is created on the Mac where Canopy's daemon runs. A session that later runs on an SSH host still picks its remote cwd inside Canopy on the Mac; this verb does not create folders on the SSH host.
