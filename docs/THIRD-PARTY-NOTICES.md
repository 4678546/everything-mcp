# Third-party notices

`everything-mcp bundle` ships or uses the third-party components listed below.
All bundled binaries are unmodified copies of official releases; their
SHA-256 digests are recorded in `manifest.json`.

---

## 1. Everything (everything.exe) — MIT

- Component: `runtime\everything\everything.exe`
- Version: 1.4.1.1026 (portable, unmodified official build)
- Upstream: <https://www.voidtools.com/>
- License: MIT, Copyright (C) 2018 David Carpenter
- Local copy of the license text: `runtime\everything\License-Everything.txt`

```text
MIT License

Copyright (C) 2018 David Carpenter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## 2. Everything CLI (ES, es.exe) — MIT

- Component: `bin\es.exe`, source `src\es-cli.c`
- Version: 1.1.0.27 (official `ES-1.1.0.27.zip`, also kept in `vendor\`)
- Upstream: <https://www.voidtools.com/downloads/> (`ES-1.1.0.27.zip`)
- License: MIT, Copyright (C) 2020 David Carpenter (see the header of `src\es-cli.c`)

```text
Copyright (C) 2020 David Carpenter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. everything-mcp (MCP server source) — MIT

- Component: `mcp\everything_mcp\` (modified: `supervisor.py` and the
  install/diagnostic scripts added, `server.py` / `backend.py` / `config.py`
  extended for five tools, the on-demand instance lifecycle and the hardened
  `es.exe` query path)
- Upstream: <https://github.com/elis132/everything-mcp> (base version 1.0.9)
- License: MIT. The upstream copyright notice is kept in
  `LICENSE-everything-mcp.txt`; the same MIT terms as reproduced above apply.
  Modifications and additions are distributed under the same MIT license.
- What changed and why: see "Changes relative to upstream everything-mcp" in
  [README.md](../README.md) (English, the default front page) or「相对上游 everything-mcp 的改动」
  in [README.zh-CN.md](README.zh-CN.md), and the `components.everything_mcp.changes` list in
  `manifest.json`.

---

## 4. Python runtime — PSF-2.0 (not redistributed)

Python is **not** bundled. `scripts\setup.ps1` looks for an existing interpreter
(>= 3.10) or offers to download the official python.org build
(default 3.13.17). Downloaded Python is licensed under the Python Software
Foundation License Version 2; its license file ships inside the downloaded
build (`LICENSE.txt`).

## 5. Python dependencies — not redistributed

Installed into `runtime\venv` (or `runtime\site-packages`) at install time:

| Package | Pinned version | License |
|---|---|---|
| `mcp` | 2.3.0 | MIT |
| `pydantic` | 2.14.1 | MIT |
| transitive dependencies | pinned by pip resolution | MIT / BSD / Apache-2.0 |

The dependency set is installed at install time and is not part of this
repository or the published archive. Their license files are retained by pip
inside `runtime\venv\Lib\site-packages\*.dist-info\licenses\`.
