# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格，
版本号使用 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-11-18

### 新增

- `supervisor.py`：Everything 实例的按需生命周期管理
  - 启动顺序：显式实例 → 已在运行的实例 → 本机安装的 `everything.exe`（隐藏启动）→ 包内副本
  - 自动检测本机 Everything：环境变量 / `host-config.json` / 注册表 / 常见目录，最后对固定磁盘做限定深度扫描以发现便携版（`EVERYTHING_NO_DRIVE_SCAN=1` 可关闭）
  - **复用本机安装时直接使用它的 `Everything.db`，不复制、不重建索引，也不预热**
  - 启动前检查本机 Everything 的存储目录是否可写（便携版 exe 目录 / 安装版 `%APPDATA%\Everything`），不可写则不启动，避免「无法保存设置」弹窗
  - 包内副本使用独立实例名 `everything-mcp`、独立索引，无窗口 / 任务栏 / 托盘图标
  - 空闲 `EVERYTHING_IDLE_TIMEOUT`（默认 600 秒）或 MCP 服务端退出时关闭；只停止自己启动的实例，绝不结束用户自己运行的 Everything
  - 跨进程心跳 + owner 文件；崩溃遗留的自启实例由下次启动清理；退出超时则保留记录留给下次重试，不强行结束写盘中的进程
- `scripts\setup.ps1`：交互式安装器
  - 三种运行模式（A 只连接 / B 优先复用+包内兜底 / C 只连接）
  - 模式 B 检测本机 Everything，并用 WinForms 弹窗让用户选择「复用这个安装 / 浏览指定 everything.exe / 使用包内副本」；`-UserEverythingExe`、`-UseBundledEverything`、`-NoEverythingDialog` 可跳过交互
  - 只有使用包内副本时才预热索引；复用现有索引时跳过预热
  - 自动检测 Python（>= 3.10）或下载（官方优先，华为云 / TUNA 镜像兜底，SHA-256 校验）
  - 创建 venv 并安装固定版本 `mcp==2.3.0`、`pydantic==2.14.1`
  - venv 无法创建时自动退化为 `runtime\site-packages` + `--target`
  - 模式 B 申请一次 UAC 安装 Everything 服务（优先使用用户自己的 exe）
  - 生成 Claude Code / Cursor / Gemini CLI / Codex / DSH 配置片段
- `scripts\uninstall.ps1`：卸载 venv、包内索引、本安装器装的服务、生成的配置，支持保留选项
  - 服务的二进制指向包内目录时同样视为本安装器所装（升级重跑 setup 后也能正确卸载），用户自己的服务不动
- `scripts\run-mcp.cmd`：通用启动器（venv → `--target` → `runtime\python` → PATH）
- 文档：双语 README——`README.md` 为英文（默认首页，含 "Changes relative to upstream everything-mcp" 章节），`docs/README.zh-CN.md` 为中文（含「相对上游 everything-mcp 的改动」章节），两者都逐模块说明新增功能、修改的上游文件与兼容性差异，并在顶部互相链接；`docs/THIRD-PARTY-NOTICES.md`、`docs/LICENSE`、`manifest.json`（`components.everything_mcp.changes` 记录逐模块改动）

### 变更

- 发行版与 Python 包版本统一为 `1.0.0`；上游基线版本仍为 `1.0.9`
- 文档集中存放于 `docs/`，根目录保留英文 `README.md` 作为入口；安装、卸载和启动脚本集中存放于 `scripts/`
- 更新双语 README 的链接、命令和目录结构，以及 `manifest.json` 的入口路径与文件校验值

- 不再随包内置 Python 解释器（改为安装时检测/下载）
- 包内 Everything 从"随包常驻"改为"按需启动的兜底实例"
- 本机已装 Everything 时复用其索引，不再建立第二份数据库，也不再预热
- MCP 客户端配置改为通过 `scripts\run-mcp.cmd` 启动，避免写死解释器路径

### 修复

- 空闲看门狗没在自动启动实例后真正启动，且把单调时钟与心跳文件的墙上时钟混在一起比较导致永不触发；现在启动成功立即启动看门狗并统一时间基准
- `es.exe` 默认等待 IPC 应答不设上限，应答丢失（Everything 刚启动、索引仍在加载时常见）会让它永久挂起并把会话卡在 busy；现在给每次调用传 `-timeout`，并有硬性兜底清理
- 每次工具调用都会重新确认实例存活并自动拉起（Everything 被手动关闭后不再连续超时 30 秒）
- 需要强制结束遗留实例时优先用 `TerminateProcess`，避免受限令牌下 `taskkill` 被拒绝后留下进程
- 卸载器把二进制位于包内的 Everything 服务也视为自己安装的（重跑 setup 升级后仍能正确卸载）

### 移除

- 内置嵌入式 Python 压缩包与预装 `site-packages`
- Windows 7 支持（仅支持 Windows 10+）

## 早期打包版本（历史记录）

- 首个可移植打包版本：`es.exe` + `everything_mcp` 源码 + 嵌入式 Python + 手动配置片段
