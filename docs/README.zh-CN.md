# everything-mcp bundle

[English](../README.md) | **简体中文**

> 让 AI agent 直接搜索 Windows 本地文件的 MCP 服务端：Windows 10+ / 免安装 / 优先复用本机 Everything 的索引，没装时使用包内不可见的后备实例。基于 [everything-mcp](https://github.com/elis132/everything-mcp) 扩展。

[![platform](https://img.shields.io/badge/platform-Windows%2010%2B-0078D6)](#)
[![python](https://img.shields.io/badge/python-3.10%2B-3776AB)](#)
[![mcp](https://img.shields.io/badge/MCP-stdio-8A2BE2)](#)
[![license](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![version](https://img.shields.io/badge/version-1.0.0-blue)](./CHANGELOG.md)

`everything-mcp bundle` 把 [Everything](https://www.voidtools.com/) 的文件索引能力包装成
标准 MCP 工具，任何支持 MCP 的客户端（Claude Code、Cursor、Codex、DSH 等）都能让 agent
按文件名、类型、修改时间、大小检索本机文件，无需打开 Everything 窗口。

提供 5 个工具：

| 工具 | 用途 |
|---|---|
| `everything_search` | 按文件名通配符 / 正则搜索 |
| `everything_search_by_type` | 按类型（图片、视频、文档、代码……）搜索 |
| `everything_find_recent` | 查找最近修改的文件 |
| `everything_file_details` | 查询单个文件/目录的元数据 |
| `everything_count_stats` | 统计匹配文件的数量与总大小 |

## 特性

- **复用已有索引**：本机已装 Everything 时直接复用它的 `Everything.db`，按需隐藏启动、空闲 600 秒或 MCP 退出后关闭——不为 agent 再建第二份索引。
- **零常驻**：不安装 Everything GUI/托盘常驻项（模式 B 的索引服务除外）；只在工具调用时拉起，用完即走。
- **不碰用户环境**：只停止自己启动的进程；用户手动运行的 Everything 永不结束，原有索引与服务原样保留。
- **安装时可选**：检测到本机 Everything 时弹窗让你选「复用这个安装 / 浏览指定 `everything.exe` / 使用包内副本」。
- **包内兜底**：本机没有 Everything 时使用包内副本（独立实例名 `everything-mcp`、独立索引；首次构建需几分钟）。
- **Python 不打包**：安装时检测本机 Python（>= 3.10），没有才下载官方版本（官方源优先，镜像兜底，SHA-256 校验）。
- **一次 UAC**：模式 B 安装时申请一次管理员权限安装 Everything 服务，之后索引 NTFS 卷无需再提权。
- **可离线部署**：`bin\es.exe`、`runtime\everything\everything.exe` 均为官方未修改二进制，随包分发。
- **自动生成宿主配置**：`hosts\` 下直接产出 Claude Code / Cursor / Gemini CLI / Codex / DSH 的配置片段。

## 相对上游 everything-mcp 的改动

本发行版基于上游 [elis132/everything-mcp](https://github.com/elis132/everything-mcp) **1.0.9**（MIT）。
上游提供「用 `es.exe` 查询 Everything，再以 MCP 工具返回结果」的最小实现；本发行版沿用它的查询内核，
补齐了免安装分发、进程生命周期、故障恢复和安装/卸载。按模块对照：

| 模块 | 上游 1.0.9 | 本发行版新增 / 增强 |
|---|---|---|
| 工具接口 | 基础文件搜索 | 5 个结构化工具（见上表）：类型筛选、最近修改、文件详情、数量/大小统计；单次结果有上限（`EVERYTHING_MAX_RESULTS_CAP`），输出为可读文本 |
| 进程生命周期 | 要求 Everything 已在运行，不负责启动/停止 | 新增 `supervisor.py`：IPC 窗口探测 → 按需隐藏启动 → 轮询就绪（默认 60 秒）→ 空闲/退出时只关闭自己启动的实例；跨进程 owner + 心跳文件；MCP 崩溃遗留的自启实例由下次启动清理 |
| 索引复用 | 使用当前运行的 Everything 实例 | 直接复用本机 Everything 的现有 `Everything.db`，不复制、不重建、不预热；便携版通过固定磁盘限定深度扫描发现（`EVERYTHING_NO_DRIVE_SCAN=1` 可关闭）；启动前做存储可写性预检，避免「无法保存设置」弹窗 |
| 运行模式 | 单一「连接已运行实例」行为 | `EVERYTHING_USER_EXE` / `EVERYTHING_AUTOSTART` / `EVERYTHING_INSTANCE` / `EVERYTHING_DISABLE_USER_INSTALL` 组合出模式 A（只连接）、B（复用 + 包内兜底，默认）、C（严格只连接） |
| 安装部署 | 手动配置 | `scripts\setup.ps1`：检测/下载 Python（默认 3.13.17，官方源 + 镜像，SHA-256 校验）、创建 venv、安装固定依赖、检测本机 Everything、可选 WinForms 弹窗选择复用或指定 exe、模式 B 一次 UAC 安装索引服务、生成 5 种宿主配置片段、写 `host-config.json` |
| 可靠性 | 直接调用 `es.exe` | 每次调用注入 `-timeout`（服务端超时 + 余量），避免 IPC 应答丢失时永久挂起；单飞锁 + 跨进程互斥；子进程 I/O 放在 daemon 线程；每次工具调用前确认实例存活并自动恢复 |
| 配置 | 少量环境变量 | 11 个环境变量全覆盖（见下表）；`host-config.json` 记录安装事实，供升级/卸载复用 |
| 诊断 | 无 | `python -m everything_mcp.supervisor --status / --prewarm / --stop`；服务端日志输出到 stderr |
| 打包 | 仅源码 | 官方 `es.exe`、包内 Everything 兜底副本（独立实例名 `everything-mcp`、独立索引）、官方 `ES-*.zip` 与 `get-pip.py` 离线资产、`manifest.json` 逐文件 SHA-256 |
| 卸载 | 无 | `scripts\uninstall.ps1`：只删除本安装创建的 venv / Python / 索引 / 服务 / 配置片段；用户的 Everything、索引、服务原样保留 |

### 修改的上游文件

- `mcp\everything_mcp\server.py`：工具定义扩展到 5 个；加入启动/退出生命周期钩子；每次工具调用前做实例存活检查；补充日志与错误信息。
- `mcp\everything_mcp\backend.py`：`es.exe` 查询层加固（参数与 `-timeout` 注入、单飞/跨进程锁、daemon 线程 I/O、挂起进程清理、结果截断与格式化）。
- `mcp\everything_mcp\config.py`：新增 `EVERYTHING_USER_EXE`、`EVERYTHING_DISABLE_USER_INSTALL`、`EVERYTHING_AUTOSTART`、`EVERYTHING_MCP_INSTANCE` 等配置项，补默认值与路径探测顺序。
- `mcp\everything_mcp\__init__.py`、`__main__.py`：包入口与版本。
- `supervisor.py`、`scripts\setup.ps1`、`scripts\uninstall.ps1`、`scripts\run-mcp.cmd`、`hosts\`、`manifest.json`：本项目新增（上游没有对应文件）。

### 兼容性说明

- 工具名与参数以本 README「提供 5 个工具」表为准；从上游迁移时请重新生成宿主配置（`hosts\` 或 `dsh-snippet.yml`）。
- Everything 查询语法（通配符、正则、`ext:`、`path:`、`size:`、`dm:` 等）仍由 `es.exe` 原样执行，语义不变。
- 默认行为差异：上游要求宿主自行保证 Everything 已运行，也不会关闭它；本发行版默认隐藏启动，并在空闲 600 秒或 MCP 退出时关闭「自己拉起的」实例。设 `EVERYTHING_AUTOSTART=0` 或安装时选模式 A/C，可恢复「只连接、不启动」的行为。
- 许可不变：本发行版与上游同为 MIT，上游版权声明保留在 `docs/LICENSE-everything-mcp.txt`；修改与新增内容同样以 MIT 发布，第三方组件见 `docs/THIRD-PARTY-NOTICES.md`。

## 快速开始

以下命令均在打包根目录执行。

```powershell
git clone https://github.com/<your-account>/everything-mcp-bundle.git
cd everything-mcp-bundle
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

安装器会询问运行模式（默认 **B**），随后：

1. 检测/下载 Python；
2. 创建 `runtime\venv` 并安装固定版本依赖（`mcp==2.3.0`、`pydantic==2.14.1`）；
3. 模式 B 检测本机 Everything：找到时弹窗选择复用方式（复用现有索引，**不预热**）；没找到时才用包内副本，并申请一次 UAC 安装索引服务、预热包内索引（首次几分钟）；
4. 在 `hosts\` 生成各宿主配置片段。

把对应片段合并进宿主配置，重启宿主程序即可。也可以不生成片段，直接让宿主执行：

```
command: C:\Windows\System32\cmd.exe
args:    ["/c", "<bundle>\scripts\run-mcp.cmd"]
```

> 每次更新这个包（或改动 MCP 配置）后都要重启宿主程序，宿主才会重新拉起 MCP 服务端。
> 服务端启动后第一次搜索会等待本机 Everything 加载已有索引（139 MB 约 5–15 秒），之后每次搜索都是毫秒级。

## 运行模式

| 模式 | 行为 | 适用场景 |
|---|---|---|
| `A` | 只连接已经运行的 Everything，从不启动任何实例 | 机器上已有 Everything 常驻 |
| `B`（默认） | 优先复用本机 Everything（需要时隐藏启动它，空闲/退出时关闭）；都不可用时用包内副本兜底 | 大多数场景，开箱即用 |
| `C` | 只连接，连不上直接报错，不做任何兜底 | 受控/安全要求高的机器 |

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode A
```

## 工作原理

```
MCP 宿主（Claude / Cursor / Codex / DSH …）
        │  stdio JSON-RPC
        ▼
   scripts\run-mcp.cmd  →  runtime\venv\python.exe -m everything_mcp
        │
        ├─ es.exe ──IPC──▶ 已在运行的 Everything（默认实例或命名实例）
        │
        └─ supervisor.py：没有实例在运行时按顺序
             1. 复用本机安装的 everything.exe（隐藏启动，-startup）
             2. 没有本机安装 → 启动包内 runtime\everything\everything.exe
                （实例名 everything-mcp，独立索引）
             3. 轮询 IPC 直到就绪（默认 60 秒超时）
             4. 空闲超时或 MCP 服务端退出时用 es -exit 关闭"自己启动的"实例
```

- 复用本机安装时索引库就是用户已有的 `Everything.db`，不复制、不重建；
- 便携版 Everything（不在注册表/常见目录）通过限定深度的固定磁盘扫描发现，可用 `EVERYTHING_NO_DRIVE_SCAN=1` 关闭；
- 启动本机 Everything 前先检查它的存储是否可写（便携版 = exe 所在目录，安装版 = `%APPDATA%\Everything`）：不可写就不启动，避免弹出「无法保存设置」对话框；
- 包内副本使用独立实例名 `everything-mcp`，便携设置与索引库都在 `runtime\everything\` 下；
- 跨进程心跳 + owner 文件：MCP 崩溃后遗留的自启实例，会在下次启动时按"只清理自己启动的进程"规则处理；
- 所有路径都可以用环境变量覆盖（见下表）。

## 目录结构

```
everything-mcp-bundle\
├─ README.md                       英文说明与快速开始入口
├─ docs\                           文档与许可证
│  ├─ README.zh-CN.md              中文说明与快速开始
│  ├─ CHANGELOG.md                 版本变更记录
│  ├─ LICENSE                      项目许可证
│  ├─ LICENSE-everything-mcp.txt    上游许可证
│  └─ THIRD-PARTY-NOTICES.md        第三方组件声明
├─ scripts\                        安装、卸载与启动脚本
│  ├─ setup.ps1                    安装器
│  ├─ uninstall.ps1                卸载器
│  └─ run-mcp.cmd                  通用启动器
├─ bin\es.exe                      voidtools ES CLI（官方二进制）
├─ runtime\everything\             不可见的包内 Everything 后备副本
│  ├─ everything.exe               Everything 1.4.1.1026（MIT）
│  ├─ Everything.ini               便携设置（实例名 everything-mcp）
│  └─ License-Everything.txt
├─ mcp\everything_mcp\             MCP 服务端源码（含 supervisor.py）
├─ hosts\                          安装时生成的宿主配置片段
├─ src\es-cli.c                    ES 源码（来自官方压缩包，便于审计）
├─ vendor\ES-1.1.0.27.zip           官方 ES 压缩包
└─ manifest.json                   组件信息与 SHA-256 校验值
```

## 安装参数

```powershell
-Mode A|B|C              运行模式（省略则交互选择，默认 B）
-UserEverythingExe <path> 直接指定要复用的 everything.exe（跳过选择弹窗）
-UseBundledEverything     不询问，直接使用包内副本
-NoEverythingDialog       不显示选择弹窗，改用控制台提示
-PythonExe <path>        指定解释器，跳过检测/下载
-PythonVersion 3.13.17   无解释器时下载的版本
-InstallForm portable|installer   portable = 官方 zip 解压到 runtime\python（默认）
-NoPrewarm               使用包内副本兜底时跳过索引预热
-DryRun                  只打印计划，不改系统
-Force                   重建 venv
```

下载与校验顺序：

- Python：`python.org` → 华为云镜像 → TUNA 镜像；SHA-256 取自官方 `windows-<版本>.json`；
- pip 依赖：PyPI → TUNA → 阿里云。

## 配置宿主

安装后 `hosts\` 会生成：

| 文件 | 宿主 |
|---|---|
| `claude-desktop.json` | Claude Desktop / Claude Code |
| `cursor.json` | Cursor |
| `gemini-cli.json` | Gemini CLI |
| `codex.toml` | Codex |
| `dsh-snippet.yml` | DSH（追加到 profile 的 `cordis.patch.yml`） |

示例（JSON，复用本机 Everything 时）：

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

使用包内副本兜底时，把 `EVERYTHING_USER_EXE` 换成：

```json
"EVERYTHING_EXE": "C:\\path\\to\\everything-mcp-bundle\\runtime\\everything\\everything.exe",
"EVERYTHING_MCP_INSTANCE": "everything-mcp",
"EVERYTHING_DISABLE_USER_INSTALL": "1"
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `EVERYTHING_ES_PATH` | 包内 `bin\es.exe` | es.exe 路径 |
| `EVERYTHING_USER_EXE` | 空 | 复用这份 `everything.exe`（优先于自动检测） |
| `EVERYTHING_DISABLE_USER_INSTALL` | 空 | `1` = 不复用本机 Everything，只用包内副本 |
| `EVERYTHING_NO_DRIVE_SCAN` | 空 | `1` = 不做便携版磁盘扫描（只查环境变量 / 配置 / 注册表 / 常见目录） |
| `EVERYTHING_EXE` | 包内 `runtime\everything\everything.exe` | 包内副本路径 |
| `EVERYTHING_MCP_INSTANCE` | `everything-mcp` | 包内副本实例名 |
| `EVERYTHING_AUTOSTART` | `1` | `0` = 只连接已有 Everything（模式 A/C） |
| `EVERYTHING_IDLE_TIMEOUT` | `600` | 空闲多少秒后关闭自己启动的实例，`0` = 不按空闲关闭 |
| `EVERYTHING_START_TIMEOUT` | `60` | 等待 IPC 就绪的秒数 |
| `EVERYTHING_INSTANCE` | 空 | 只连接指定命名实例；设置后不会启动任何实例 |
| `EVERYTHING_MAX_RESULTS_CAP` | `1000` | 单次搜索结果上限 |

## 验证与排错

```powershell
# 当前状态：检测到的本机安装 / 正在运行的实例 / 是否由本进程启动
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --status

# 连接或启动并等待索引可用（包内副本兜底时会构建索引）
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --prewarm --timeout 900

# 停止本进程启动的实例
runtime\venv\Scripts\python.exe -m everything_mcp.supervisor --stop

# 直接测试 IPC（复用本机安装时不要加 -instance）
bin\es.exe -get-everything-version
```

| 现象 | 处理 |
|---|---|
| 刚更新完包 / 改完 MCP 配置后工具不可用 | 重启宿主程序，宿主会重新拉起 MCP 服务端（旧进程仍加载着旧代码） |
| 提示 `busy` / 单次调用超时 30 秒 | Everything 刚启动、索引仍在加载时可能丢失一次 IPC 应答；等十几秒再调用即可，服务端会自动恢复。若长期如此，重启宿主程序 |
| `Error 8: Everything IPC window not found` | 没有已运行的 Everything，也没有可启动的副本。检查 `EVERYTHING_AUTOSTART`、`EVERYTHING_USER_EXE` 是否指向存在的文件 |
| 搜索结果为 0 / 首次调用很慢 | 没有可复用的索引，正在构建包内副本的索引；用 `--status` 确认，或重新运行 `scripts\setup.ps1 -Mode B` 并预热 |
| 只想复用指定安装 | 安装时用 `-UserEverythingExe <path>`，或设置 `EVERYTHING_USER_EXE` |
| 不想复用本机 Everything | 安装时选「使用包内副本」或 `-UseBundledEverything`，或设置 `EVERYTHING_DISABLE_USER_INSTALL=1` |
| 出现「无法保存设置」对话框 | 本机 Everything 的存储目录不可写（便携版看 exe 目录、安装版看 `%APPDATA%\Everything`）；本工具会跳过启动并改用包内副本，不会主动弹窗 |
| UAC 被取消 | 服务未安装；可重新运行 `scripts\setup.ps1 -Mode B`，或改用 `-Mode A` 连接已有 Everything |
| 杀软误报 | `es.exe` / `everything.exe` 均为官方未修改二进制，可用 `manifest.json` 中的 SHA-256 核对 |

服务端日志输出到 stderr（MCP stdio 传输的约定）。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

默认清理：包内副本进程、本安装器安装的 Everything 服务（服务二进制指向包内时才删除；用户原有的不动）、
包内索引库、`runtime\venv` / `site-packages`、下载的 Python、生成的配置片段和 `host-config.json`。

始终保留：用户自己的 Everything 程序、它的索引库，以及用户自己安装/配置的 Everything 服务——
卸载器不会停止它们，也不会删除它们的数据。

保留选项：`-KeepVenv`、`-KeepPython`、`-KeepIndex`；`-RemoveBundle` 会连同
`es.exe`、`everything.exe`、MCP 源码一起删除。

## 开发说明

- MCP 源码在 `mcp\everything_mcp\`：`server.py` 工具定义、`config.py` 连接探测、`supervisor.py` 生命周期。
- 生命周期顺序：显式实例 → 已在运行的实例 → 本机安装（`-startup` 隐藏启动）→ 包内副本；只有自己启动的实例会被停止或清理。
- `scripts\setup.ps1` / `scripts\uninstall.ps1` 兼容 Windows PowerShell 5.1 与 PowerShell 7。
- 修改源码后更新 `manifest.json` 的 `file_hashes`；`docs/CHANGELOG.md` 记录版本变更。
- 已知限制：仅 Windows 10+；仅支持 stdio 传输；不启用 Everything 的 HTTP/ETP Server。

## 许可

- 本项目代码：[MIT](./LICENSE)
- 第三方组件（Everything、ES、上游 everything-mcp）：[THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md)
- 打包的 Everything / ES 二进制均为官方未修改版本（MIT，Copyright © David Carpenter）

## 致谢

- [voidtools Everything](https://www.voidtools.com/) —— 文件索引与 IPC
- [elis132/everything-mcp](https://github.com/elis132/everything-mcp) —— 原始 MCP 服务端实现
- 依赖：`mcp==2.3.0`、`pydantic==2.14.1`（安装时从 PyPI 获取，不随仓库分发）
