# Open on Mac: create folder from iPhone

Canopy Mobile's **Open on Mac → Folders → Browse** flow can ask the Mac to create a directory before starting a live session. The phone side is implemented in `RemoteFolder.swift` and `NewRemoteFolderSheet` in `OpenOnMacView.swift`.

## Mac control API (Canopy, not yet in all releases)

Add a handler alongside `browse_dir` / `list_folders` on the phone control connection (same NDJSON `request` / `response` framing as existing verbs).

### `create_folder`

**Request params**

| Field | Type | Meaning |
| --- | --- | --- |
| `path` | string | Parent directory (absolute path), same meaning as `browse_dir`'s `path` |
| `name` | string | Single path segment; no `/`. Phone trims whitespace before send |

**Success result**

| Field | Type | Meaning |
| --- | --- | --- |
| `path` | string | Absolute path of the created directory |

**Behavior**

- Create `path/name` with `FileManager` (or equivalent). Do not follow symlinks out of the parent in a surprising way; reject if parent does not exist or is not a directory.
- If the directory already exists, respond with `error` (e.g. `"already exists"`).
- Invalid names (empty after trim, `.`, `..`, contains `/`) → `error` (e.g. `"invalid name"`).
- Permission failure → `error` (e.g. `"permission denied"`).

**Example**

```json
{"type":"request","id":"…","verb":"create_folder","params":{"path":"/Users/me/Projects","name":"new-app"}}
{"type":"response","id":"…","result":{"path":"/Users/me/Projects/new-app"}}
```

Unknown verb on older Canopy builds: phone maps `"unknown verb"` style errors to **Update Canopy on that Mac**.

## Remote SSH panes

Creating a folder uses the **local Mac's** filesystem where Canopy's daemon runs. If the user later opens a session that runs on a **remote** SSH host, that is unchanged — remote cwd is still chosen inside Canopy on the Mac. This API does not SSH-mkdir on the remote; extend Canopy separately if that is needed.
