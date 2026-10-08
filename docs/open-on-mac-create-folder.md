# Open on Mac: create folder from iPhone

Canopy Mobile's **Open on Mac → Folders → Browse** flow can ask the Mac to create a directory before starting a live session. The phone side is `RemoteFolder.swift` and `NewRemoteFolderSheet` in `OpenOnMacView.swift`.

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
