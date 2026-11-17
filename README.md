# everything-mcp bundle

**English** | [简体中文](docs/README.zh-CN.md)

> MCP server that lets AI agents search local Windows files directly: Windows 10+, no installation, reuses the index of an existing Everything when available and falls back to an invisible bundled instance when not. Built on top of [everything-mcp](https://github.com/elis132/everything-mcp).

[![platform](https://img.shields.io/badge/platform-Windows%2010%2B-0078D6)](#)
[![python](https://img.shields.io/badge/python-3.10%2B-3776AB)](#)
[![mcp](https://img.shields.io/badge/MCP-stdio-8A2BE2)](#)
[![license](https://img.shields.io/badge/license-MIT-green)](./docs/LICENSE)
[![version](https://img.shields.io/badge/version-1.0.0-blue)](./docs/CHANGELOG.md)

`everything-mcp bundle` wraps the file-indexing power of [Everything](https://www.voidtools.com/) in standard MCP tools, so any MCP-capable client (Claude Code, Cursor, Codex, DSH, ...) can search local files by name, type, modification time and size without opening the Everything window.

Five tools are provided:

| Tool | Purpose |
|---|---|
| `everything_search` | Search by filename wildcard / regular expression |
| `everything_search_by_type` | Search by file category (images, videos, documents, code, ...) |
| `everything_find_recent` | Find recently modified files |
| `everything_file_details` | Report metadata for one file or directory |
| `everything_count_stats` | Count matching files and their total size |

## Features

- **Reuses your existing index** — if Everything is already installed, its `Everything.db` is used as-is, started hidden on demand and closed after 600 seconds idle or when the MCP server exits. No second database is ever built for the agent.
- **Nothing stays resident** — no Everything GUI or tray item is installed (apart from the indexing service used by mode B); Everything is only started when a tool runs and goes away afterwards.
- **Leaves your setup untouched** — only processes started by this bundle are stopped. An Everything you started yourself is never closed, and its index and service stay exactly as they were.
- **A choice at install time** — when a local Everything is found, a dialog lets you reuse that installation, browse to a specific `everything.exe`, or use the bundled copy.
- **Bundled fallback** — when no local Everything exists, the bundle uses its own invisible copy (instance name `everything-mcp`, separate index; the first build takes a few minutes).
- **Python is not bundled** — setup detects an existing interpreter (>= 3.10) and only downloads the official build when none is found (python.org first, mirrors as fallback, SHA-256 verified).
- **One UAC prompt** — mode B asks for administrator rights once to install the Everything service; indexing NTFS volumes needs no further elevation.
- **Offline-friendly** — `bin\es.exe` and `runtime\everything\everything.exe` are unmodified official binaries shipped with the bundle.
- **Host configs generated for you** — `hosts\` receives ready-to-paste snippets for Claude Code, Cursor, Gemini CLI, Codex and DSH.

## Changes relative to upstream everything-mcp

This release is based on upstream [elis132/everything-mcp](https://github.com/elis132/everything-mcp) **1.0.9** (MIT).
Upstream provides a minimal implementation that queries Everything through `es.exe` and exposes the results as MCP tools. This release keeps that query core and adds portable distribution, process lifecycle management, failure recovery, and install/uninstall tooling. Module by module:

| Module | Upstream 1.0.9 | Added / enhanced in this release |
|---|---|---|
| Tool surface | Basic file search | Five structured tools (see the table above): type filtering, recent files, file details, count/size statistics; per-call result cap (`EVERYTHING_MAX_RESULTS_CAP`) and human-readable output |
| Process lifecycle | Expects Everything to be running; does not start or stop it | New `supervisor.py`: probe the IPC window → start hidden on demand → poll until ready (60 s by default) → close only the instances it started on idle/shutdown; cross-process owner + heartbeat files; self-started instances left behind by a crash are cleaned up on the next start |
| Index reuse | Uses the currently running Everything instance | Reuses the existing local `Everything.db` as-is: no copy, no rebuild, no prewarm. Portable installs are discovered by a depth-limited scan of fixed drives (`EVERYTHING_NO_DRIVE_SCAN=1` disables it). A storage writability preflight prevents Everything's "cannot save settings" dialog |
| Run modes | Single "connect to a running instance" behaviour | `EVERYTHING_USER_EXE` / `EVERYTHING_AUTOSTART` / `EVERYTHING_INSTANCE` / `EVERYTHING_DISABLE_USER_INSTALL` combine into mode A (connect only), B (reuse + bundled fallback, default) and C (strict connect only) |
| Installation | Manual configuration | `scripts\setup.ps1`: detect/download Python (3.13.17 by default, python.org + mirrors, SHA-256), create the venv, install pinned dependencies, detect a local Everything, optional WinForms dialog to reuse it or point at an exe, one UAC service install in mode B, generate five host snippets, write `host-config.json` |
| Reliability | Calls `es.exe` directly | `-timeout` injected into every call (server timeout + slack) so a lost IPC reply cannot hang forever; single-flight + cross-process locks; subprocess I/O on daemon threads; instance liveness checked before every tool call and recovered automatically |
| Configuration | A few environment variables | All 11 environment variables supported (table below); `host-config.json` records the installation facts for upgrades and uninstall |
| Diagnostics | None | `python -m everything_mcp.supervisor --status / --prewarm / --stop`; server logs go to stderr |
| Packaging | Source only | Official `es.exe`, bundled Everything fallback (instance `everything-mcp`, separate index), official `ES-*.zip` and `get-pip.py` offline assets, per-file SHA-256 in `manifest.json` |
| Uninstall | None | `scripts\uninstall.ps1`: removes only what this installation created (venv / Python / index / service / config snippets); your Everything, its index and any service you installed stay untouched |

### Modified upstream files

- `mcp\everything_mcp\server.py` — tool definitions extended to five; startup/shutdown lifecycle hooks; instance liveness check before every tool call; additional logging and error messages.
- `mcp\everything_mcp\backend.py` — hardened `es.exe` query path (argument and `-timeout` injection, single-flight/cross-process locks, daemon-thread I/O, cleanup of hung processes, result truncation and formatting).
- `mcp\everything_mcp\config.py` — new `EVERYTHING_USER_EXE`, `EVERYTHING_DISABLE_USER_INSTALL`, `EVERYTHING_AUTOSTART`, `EVERYTHING_MCP_INSTANCE` and related settings; defaults and detection order.
- `mcp\everything_mcp\__init__.py`, `__main__.py` — package entry points and version.
- `supervisor.py`, `scripts\setup.ps1`, `scripts\uninstall.ps1`, `scripts\run-mcp.cmd`, `hosts\`, `manifest.json` — new in this project (no upstream counterpart).

### Compatibility notes

- Tool names and arguments are those in the "Five tools" table above; when migrating from upstream, regenerate the host config (`hosts\` or `dsh-snippet.yml`).
- Everything query syntax (wildcards, regular expressions, `ext:`, `path:`, `size:`, `dm:`, etc.) is still executed by `es.exe` unchanged.
- Behavioural difference: upstream expects the host to keep Everything running and never closes it. This release starts Everything hidden by default and closes only the instances it started, after 600 seconds idle or when the MCP server exits. Set `EVERYTHING_AUTOSTART=0`, or choose mode A/C during setup, to get the "connect only, never start" behaviour.
- Licensing is unchanged: this release and upstream are both MIT. The upstream copyright notice is kept in `docs/LICENSE-everything-mcp.txt`; modifications and additions are released under the same MIT terms. Third-party components are listed in `docs/THIRD-PARTY-NOTICES.md`.

## Quick start

Run the commands below from the bundle root directory.

```powershell
git clone https://github.com/<your-account>/everything-mcp-bundle.git
cd everything-mcp-bundle
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

The installer asks for a run mode (default **B**) and then:

1. detects or downloads Python;
2. creates `runtime\venv` and installs the pinned dependencies (`mcp==2.3.0`, `pydantic==2.14.1`);
3. in mode B, looks for a local Everything: if one is found, a dialog asks how to reuse it (existing index, **no prewarm**); only when none is found does it use the bundled copy, request one UAC prompt to install the indexing service, and prewarm the bundled index (a few minutes the first time);
4. writes host config snippets to `hosts\`.

Merge the matching snippet into your host configuration and restart the host. You can also skip the snippets and let the host run:

```
command: C:\Windows\System32\cmd.exe
args:    ["/c", "<bundle>\scripts\run-mcp.cmd"]
```

> The host must be restarted after every bundle update (or MCP configuration change) so that it launches the new server process.
> The first search after startup waits for Everything to load the existing index (about 5–15 seconds for 139 MB); every search after that takes milliseconds.

## Run modes

| Mode | Behaviour | Good for |
|---|---|---|
| `A` | Connects only to an already running Everything; never starts an instance | Machines that keep Everything running |
| `B` (default) | Prefers the local Everything (started hidden when needed, closed on idle/exit); falls back to the bundled copy when neither is available | Most setups, works out of the box |
| `C` | Connects only; fails with an error instead of falling back | Locked-down or security-sensitive machines |

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode A
```

## How it works

```
MCP host (Claude / Cursor / Codex / DSH ...)
        │  stdio JSON-RPC
        ▼
   scripts\run-mcp.cmd  →  runtime\venv\python.exe -m everything_mcp
        │
        ├─ es.exe ──IPC──▶ a running Everything (default or named instance)
        │
        └─ supervisor.py, in order, when no instance is running
             1. reuse the local everything.exe (hidden start, -startup)
             2. no local installation → start the bundled runtime\everything\everything.exe
                (instance name everything-mcp, separate index)
             3. poll IPC until ready (60 s timeout by default)
             4. on idle timeout or MCP server exit, close the instances "it started" with es -exit
```

- When a local installation is reused, its existing `Everything.db` is used as-is — no copy, no rebuild.
- Portable Everything installs (not in the registry or the usual directories) are found with a depth-limited fixed-drive scan; `EVERYTHING_NO_DRIVE_SCAN=1` disables it.
- Before starting a local Everything, its storage must be writable (portable = the exe directory, installed = `%APPDATA%\Everything`); if it is not, the bundle skips it instead of triggering the "cannot save settings" dialog.
- The bundled copy uses instance name `everything-mcp` and keeps its portable settings and index under `runtime\everything\`.
- Cross-process heartbeat + owner files: self-started instances left behind by a crashed MCP server are handled on the next start under the "only clean up processes we started" rule.
- Every path can be overridden with environment variables (table below).

## Bundle layout

```
everything-mcp-bundle\
├─ README.md                       English overview and quick start
├─ docs\                           documentation and licenses
│  ├─ README.zh-CN.md              Chinese overview and quick start
│  ├─ CHANGELOG.md                 release history
│  ├─ LICENSE                      project license
│  ├─ LICENSE-everything-mcp.txt    upstream license
│  └─ THIRD-PARTY-NOTICES.md        third-party notices
├─ scripts\                        installation and launch scripts
│  ├─ setup.ps1                    installer
│  ├─ uninstall.ps1                uninstaller
│  └─ run-mcp.cmd                  generic launcher
├─ bin\es.exe                      voidtools ES CLI (official binary)
├─ runtime\everything\             invisible bundled Everything fallback
│  ├─ everything.exe               Everything 1.4.1.1026 (MIT)
│  ├─ Everything.ini               portable settings (instance everything-mcp)
│  └─ License-Everything.txt
├─ mcp\everything_mcp\             MCP server source (including supervisor.py)
├─ hosts\                          host config snippets generated at install time
├─ src\es-cli.c                    ES source (from the official zip, for auditing)
├─ vendor\ES-1.1.0.27.zip           official ES archive
└─ manifest.json                   component list with SHA-256 hashes
```

## Setup parameters

```powershell
-Mode A|B|C               run mode (interactive prompt when omitted; default B)
-UserEverythingExe <path> reuse this everything.exe (skips the selection dialog)
-UseBundledEverything     use the bundled copy without asking
-NoEverythingDialog       no selection dialog; use console prompts instead
-PythonExe <path>         use this interpreter; skip detection/download
-PythonVersion 3.13.17    version to download when no interpreter is found
-InstallForm portable|installer   portable = official zip extracted into runtime\python (default)
-NoPrewarm                skip index prewarming when falling back to the bundled copy
-DryRun                   print the plan only; do not change anything
-Force                    recreate the venv
```

Download and verification order:

- Python: `python.org` → Huawei Cloud mirror → TUNA mirror; SHA-256 comes from the official `windows-<version>.json`.
- pip dependencies: PyPI → TUNA → Aliyun.

## Host configuration

`hosts\` receives these snippets after installation:

| File | Host |
|---|---|
| `claude-desktop.json` | Claude Desktop / Claude Code |
| `cursor.json` | Cursor |
| `gemini-cli.json` | Gemini CLI |
| `codex.toml` | Codex |
| `dsh-snippet.yml` | DSH (append to the profile's `cordis.patch.yml`) |

Example (JSON, reusing a local Everything):

```json
{
  "mcpServers": {
    "everything": {
      "command": "C:\\path\\to\\everything-mcp-bundle\\runtime\\venv\\Scripts\\python.exe",
      "args": ["-m", "everything_mcp"],
      "env": {
        "PYTHONPATH": "C:\\path\\to\\everything-mcp-bundle\\mcp",
        "EVERYTHING_ES_PATH": "C:\\path\\to\\everything-mcp-bundle\\bin\\es.exe",
        "EVERYTHING_USER_EXE": "D:\\path\\to\\user\\Everything\\everything.exe",
        "EVERYTHING_AUTOSTART": "1",
        "EVERYTHING_IDLE_TIMEOUT": "600"
      }
    }
  }
}
```

When falling back to the bundled copy, replace `EVERYTHING_USER_EXE` with:

```json
"EVERYTHING_EXE": "C:\\path\\to\\everything-mcp-bundle\\runtime\\everything\\everything.exe",
"EVERYTHING_MCP_INSTANCE": "everything-mcp",
"EVERYTHING_DISABLE_USER_INSTALL": "1"
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `EVERYTHING_ES_PATH` | bundled `bin\es.exe` | Path to es.exe |
| `EVERYTHING_USER_EXE` | empty | Reuse this `everything.exe` (takes priority over auto-detection) |
| `EVERYTHING_DISABLE_USER_INSTALL` | empty | `1` = never reuse a local Everything, use the bundled copy only |
| `EVERYTHING_NO_DRIVE_SCAN` | empty | `1` = skip the portable-install drive scan (only check env vars / config / registry / common directories) |
| `EVERYTHING_EXE` | bundled `runtime\everything\everything.exe` | Path to the bundled copy |
| `EVERYTHING_MCP_INSTANCE` | `everything-mcp` | Instance name of the bundled copy |
| `EVERYTHING_AUTOSTART` | `1` | `0` = connect only to a running Everything (modes A/C) |
| `EVERYTHING_IDLE_TIMEOUT` | `600` | Seconds of idleness before closing an instance this bundle started; `0` = never close on idle |
| `EVERYTHING_START_TIMEOUT` | `60` | Seconds to wait for IPC readiness |
| `EVERYTHING_INSTANCE` | empty | Connect only to this named instance; no instance will be started |
| `EVERYTHING_MAX_RESULTS_CAP` | `1000` | Maximum number of results per search |

## Verification and troubleshooting

```powershell
# current state: detected local install / running instances / whether this process started them
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --status

# connect or start and wait until the index is usable (builds the index for the bundled fallback)
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --prewarm --timeout 900

# stop the instances this process started
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --stop

# test IPC directly (do not pass -instance when reusing a local installation)
bin\es.exe -get-everything-version
```

| Symptom | What to do |
|---|---|
| Tools unavailable right after a bundle update or MCP config change | Restart the host so it relaunches the MCP server (the old process still runs the old code) |
| `busy` / a single call times out after 30 seconds | Everything may lose one IPC reply while it is starting and still loading its index; wait a few seconds and retry — the server recovers automatically. If it persists, restart the host |
| `Error 8: Everything IPC window not found` | No Everything is running and none could be started. Check that `EVERYTHING_AUTOSTART` is set and `EVERYTHING_USER_EXE` points to an existing file |
| Zero results / the first call is very slow | There is no reusable index and the bundled copy is still building its own; confirm with `--status`, or rerun `scripts\setup.ps1 -Mode B` with prewarming |
| Reuse one specific installation | Pass `-UserEverythingExe <path>` during setup, or set `EVERYTHING_USER_EXE` |
| Do not reuse the local Everything | Choose "use the bundled copy" during setup, pass `-UseBundledEverything`, or set `EVERYTHING_DISABLE_USER_INSTALL=1` |
| A "cannot save settings" dialog appears | The local Everything's storage is not writable (portable = the exe directory, installed = `%APPDATA%\Everything`); this bundle skips such an installation and uses the bundled copy instead of showing that dialog itself |
| UAC was cancelled | The service was not installed; rerun `scripts\setup.ps1 -Mode B`, or switch to `-Mode A` and connect to an existing Everything |
| Antivirus false positive | `es.exe` / `everything.exe` are unmodified official binaries; verify them against the SHA-256 hashes in `manifest.json` |

The server logs to stderr (as required by the MCP stdio transport).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

By default it removes: processes of the bundled copy, the Everything service installed by this setup (only when the service binary points into the bundle; an existing service of yours is left alone), the bundled index, `runtime\venv` / `site-packages`, downloaded Python, the generated config snippets and `host-config.json`.

Always kept: your own Everything program, its index, and any Everything service you installed or configured yourself — the uninstaller neither stops them nor deletes their data.

Keep options: `-KeepVenv`, `-KeepPython`, `-KeepIndex`; `-RemoveBundle` also deletes `es.exe`, `everything.exe` and the MCP source.

## Development notes

- MCP source lives in `mcp\everything_mcp\`: `server.py` (tool definitions), `config.py` (connection detection), `supervisor.py` (lifecycle).
- Lifecycle order: explicit instance → already running instance → local installation (hidden `-startup`) → bundled copy; only instances started here are stopped or cleaned up.
- `scripts\setup.ps1` / `scripts\uninstall.ps1` support Windows PowerShell 5.1 and PowerShell 7.
- After changing the source, refresh `file_hashes` in `manifest.json`; record releases in `docs/CHANGELOG.md`.
- Known limits: Windows 10+ only; stdio transport only; Everything's HTTP/ETP server is never enabled.

## License

- Project code: [MIT](./docs/LICENSE)
- Third-party components (Everything, ES, upstream everything-mcp): [THIRD-PARTY-NOTICES.md](./docs/THIRD-PARTY-NOTICES.md)
- Bundled Everything / ES binaries are unmodified official builds (MIT, Copyright © David Carpenter)

## Acknowledgements

- [voidtools Everything](https://www.voidtools.com/) — file indexing and IPC
- [elis132/everything-mcp](https://github.com/elis132/everything-mcp) — the original MCP server implementation
- Dependencies: `mcp==2.3.0`, `pydantic==2.14.1` (fetched from PyPI at install time, not redistributed)
