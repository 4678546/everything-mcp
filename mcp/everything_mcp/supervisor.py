"""Lifecycle supervisor for Everything, reusing the user's own installation.

The MCP server talks to Everything over IPC.  This module decides *which*
Everything that is, in this order:

1. an explicitly configured instance (``EVERYTHING_INSTANCE``) - connect only;
2. an Everything that is already running - connect to it, never stop it;
3. an Everything **installed on this machine** - start it with ``-startup``
   (hidden window) so it loads its *existing* index; this is what makes the
   first search instant and avoids building a second database;
4. only when no installation is available, the ``everything.exe`` bundled with
   this package - the first run of that copy has to build its own index, so a
   warning is logged and the user is told once.

Only an instance this process started is ever stopped (idle timeout, MCP server
exit, stale-owner cleanup).  An Everything the user had running is never
touched.  State for that bookkeeping lives in ``%TEMP%\\everything-mcp``:

* ``*.heartbeat`` - activity marker shared with other MCP server processes;
* ``*.owner.json`` - PID, image path and instance of the instance *we* started,
  so a crashed server cannot leave an orphan behind; the next start reaps it
  only when the recorded image still matches.

Environment variables (all optional):

``EVERYTHING_USER_EXE``           path to the user's own everything.exe
``EVERYTHING_EXE``                path to the bundled fallback everything.exe
``EVERYTHING_MCP_INSTANCE``       instance name for the bundled fallback
                                  (default ``everything-mcp``)
``EVERYTHING_AUTOSTART``          ``0``/``false``/``no``/``off`` disables
                                  starting anything (setup modes A and C)
``EVERYTHING_DISABLE_USER_INSTALL`` ``1`` forces the bundled fallback (tests)
``EVERYTHING_IDLE_TIMEOUT``       seconds of inactivity before shutdown, ``0``
                                  disables the idle watchdog
``EVERYTHING_START_TIMEOUT``      seconds to wait for the IPC window on start
"""

from __future__ import annotations

import atexit
import ctypes
import json
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

__all__ = [
    "EverythingSupervisor",
    "get_supervisor",
    "reset_supervisor",
    "find_user_everything",
    "main",
]

logger = logging.getLogger("everything_mcp")

_IS_WIN = sys.platform == "win32"
_IPC_CLASS = "EVERYTHING_TASKBAR_NOTIFICATION"
_CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

# Poll interval while waiting for the IPC window / index readiness.
_POLL_INTERVAL = 0.15
_PROBE_INTERVAL = 2.0

_TRUTHY = {"1", "true", "yes", "on"}
_FALSY = {"0", "false", "no", "off"}

# State file stem: one supervisor per machine, regardless of which instance
# name is in use, because only one MCP-managed Everything exists at a time.
_STATE_STEM = "everything-mcp"


# ── paths ─────────────────────────────────────────────────────────────────


def _bundle_root() -> Path:
    """Bundle root, derived from ``mcp/everything_mcp/supervisor.py``."""
    return Path(__file__).resolve().parents[2]


def _default_exe() -> Path:
    return _bundle_root() / "runtime" / "everything" / "everything.exe"


def _default_es() -> Path:
    return _bundle_root() / "bin" / "es.exe"


def _read_bundle_config() -> dict:
    """Parsed ``host-config.json`` written by setup.ps1 (empty when absent)."""
    try:
        raw = (_bundle_root() / "host-config.json").read_text(encoding="utf-8-sig")
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _is_inside(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (OSError, ValueError):
        return False


def _same_path(left: str | os.PathLike[str] | None, right: str | os.PathLike[str] | None) -> bool:
    if not left or not right:
        return False
    try:
        return os.path.normcase(os.path.abspath(str(left))) == os.path.normcase(
            os.path.abspath(str(right))
        )
    except OSError:  # pragma: no cover - defensive
        return False


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        logger.warning("%s='%s' is not a number, using %s", name, raw, default)
        return default
    return value if value >= 0 else default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if raw in _TRUTHY:
        return True
    if raw in _FALSY:
        return False
    return default


def _state_dir() -> Path:
    """Per-user temp directory for heartbeat / owner files."""
    path = Path(tempfile.gettempdir()) / "everything-mcp"
    try:
        path.mkdir(mode=0o700, exist_ok=True)
    except OSError:
        return Path(tempfile.gettempdir())
    return path


def _dir_writable(directory: Path) -> bool:
    """True when a new file can be written to *directory*."""
    probe = directory / f".everything-mcp-write-test-{os.getpid()}-{int(time.time() * 1000)}"
    try:
        probe.write_bytes(b"x")
        return True
    except OSError:
        return False
    finally:
        try:
            probe.unlink()
        except OSError:
            pass


_WM_CLOSE = 0x0010


def _dismiss_dialogs(pid: int) -> int:
    """Close modal dialogs owned by *pid* (Everything's save-settings prompt).

    A modal dialog blocks Everything's normal message loop, so ``es -exit``
    times out; closing the window is the least destructive way to recover.
    Returns the number of windows asked to close.
    """
    if not _IS_WIN or pid <= 0:
        return 0
    try:
        user32 = ctypes.windll.user32
        enum_proc_type = ctypes.WINFUNCTYPE(
            ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p
        )
    except (AttributeError, OSError):  # pragma: no cover - non-Windows
        return 0

    closed = 0

    def _callback(hwnd, _lparam):
        nonlocal closed
        try:
            window_pid = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(window_pid))
            if window_pid.value != pid:
                return True
            class_name = ctypes.create_unicode_buffer(64)
            user32.GetClassNameW(hwnd, class_name, 64)
            title = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, title, 256)
            if class_name.value == "#32770" or "everything" in title.value.lower():
                user32.PostMessageW(hwnd, _WM_CLOSE, 0, 0)
                closed += 1
        except OSError:  # pragma: no cover - best effort
            pass
        return True

    try:
        user32.EnumWindows(enum_proc_type(_callback), 0)
    except OSError:  # pragma: no cover - best effort
        return closed
    return closed


# ── user installation discovery ───────────────────────────────────────────


def _registry_install_dirs() -> list[Path]:
    """Everything install directories from the Windows Registry."""
    if sys.platform != "win32":
        return []
    try:
        import winreg
    except ImportError:  # pragma: no cover
        return []

    dirs: list[Path] = []
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for subkey in (
            r"SOFTWARE\voidtools\Everything",
            r"SOFTWARE\WOW6432Node\voidtools\Everything",
        ):
            try:
                key = winreg.OpenKey(hive, subkey)
            except OSError:
                continue
            with key:
                for value in ("InstallLocation", "InstallPath"):
                    try:
                        dirs.append(Path(winreg.QueryValueEx(key, value)[0]))
                    except OSError:
                        continue
    return dirs


def _common_install_dirs() -> list[Path]:
    """Well-known install directories for Everything (including portable)."""
    dirs: list[Path] = []
    for env in ("ProgramFiles", "ProgramFiles(x86)"):
        root = os.environ.get(env)
        if root:
            dirs.append(Path(root) / "Everything")
            dirs.append(Path(root) / "Everything 1.5a")
    for env in ("LOCALAPPDATA", "PROGRAMDATA", "USERPROFILE"):
        root = os.environ.get(env)
        if not root:
            continue
        dirs.append(Path(root) / "Everything")
        dirs.append(Path(root) / "Programs" / "Everything")
    return dirs


def _exe_from_command(command: str) -> Path | None:
    """Extract the executable path from a shell/command-line string."""
    text = command.strip()
    if not text:
        return None
    if text.startswith('"'):
        end = text.find('"', 1)
        candidate = text[1:end] if end > 0 else text[1:]
    else:
        lower = text.lower()
        index = lower.find(".exe")
        candidate = text[: index + 4] if index >= 0 else text.split(" ")[0]
    candidate = candidate.replace("\\??\\", "").strip().strip('"')
    return Path(candidate) if candidate.lower().endswith(".exe") else None


def _registry_exe_candidates() -> list[Path]:
    """Everything executables referenced by the Registry (installed copies)."""
    if sys.platform != "win32":
        return []
    try:
        import winreg
    except ImportError:  # pragma: no cover
        return []

    paths: list[Path] = []
    app_path_keys = (
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Everything.exe"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Everything.exe"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Everything.exe"),
    )
    for hive, subkey in app_path_keys:
        try:
            key = winreg.OpenKey(hive, subkey)
        except OSError:
            continue
        with key:
            try:
                value, _kind = winreg.QueryValueEx(key, "")
            except OSError:
                continue
        if value:
            paths.append(Path(str(value).strip().strip('"')))

    # The Everything service binary is an Everything executable as well.
    try:
        service_key = winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Services\Everything"
        )
    except OSError:
        service_key = None
    if service_key is not None:
        with service_key:
            try:
                image_path, _kind = winreg.QueryValueEx(service_key, "ImagePath")
            except OSError:
                image_path = None
        if image_path:
            exe = _exe_from_command(str(image_path).replace("\\??\\", ""))
            if exe is not None:
                paths.append(exe)

    # Explorer's "Search Everything..." context-menu command.
    shell_keys = (
        r"SOFTWARE\Classes\*\shell\Everything\command",
        r"SOFTWARE\Classes\Directory\shell\Everything\command",
        r"SOFTWARE\Classes\Folder\shell\Everything\command",
    )
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for subkey in shell_keys:
            try:
                key = winreg.OpenKey(hive, subkey)
            except OSError:
                continue
            with key:
                try:
                    command, _kind = winreg.QueryValueEx(key, "")
                except OSError:
                    continue
            exe = _exe_from_command(str(command))
            if exe is not None:
                paths.append(exe)
    return paths


def _exe_candidates(directory: Path) -> list[Path]:
    """Everything executables inside *directory* (x64 build preferred)."""
    preferred = (directory / "Everything64.exe", directory / "Everything.exe")
    found = [candidate for candidate in preferred if candidate.is_file()]
    if found:
        return found
    try:
        return [
            entry
            for entry in directory.iterdir()
            if entry.is_file()
            and entry.name.lower().startswith("everything")
            and entry.suffix.lower() == ".exe"
        ]
    except OSError:
        return []


def _score_install(exe: Path) -> int:
    """Prefer installs that already have an index/database next to the exe."""
    score = 0
    folder = exe.parent
    try:
        has_db = any(
            entry.is_file() and entry.name.lower() == "everything.db"
            for entry in folder.iterdir()
        )
        has_ini = any(
            entry.is_file() and entry.name.lower() == "everything.ini"
            for entry in folder.iterdir()
        )
    except OSError:
        has_db = has_ini = False
    if has_db:
        score += 2
    elif has_ini:
        score += 1
    return score


def _is_bundle_copy(path: Path, bundle_root: Path) -> bool:
    """True for our own bundled fallback copy (never a user installation).

    Besides the current bundle root this also recognises another checkout or a
    previously deployed bundle, so the fallback can never be "reused" as if it
    were the user's installation.
    """
    if _is_inside(path, bundle_root):
        return True
    if any(part.lower() == "everything-mcp-bundle" for part in path.parts):
        return True
    folder = path.parent
    for marker in ("Everything-everything-mcp.ini", "Everything-everything-mcp.db"):
        try:
            if (folder / marker).is_file():
                return True
        except OSError:  # pragma: no cover - defensive
            pass
    return False


def _pick_best_install(
    candidates: list[Path],
    bundle_root: Path,
    seen: set[str],
    best: Path | None,
    best_score: int,
) -> tuple[Path | None, int]:
    """Score *candidates* and return the best acceptable Everything executable."""
    for candidate in candidates:
        try:
            path = candidate if candidate.is_file() else None
        except OSError:
            path = None
        if path is None:
            continue
        if path.suffix.lower() != ".exe" or not path.name.lower().startswith("everything"):
            continue
        if _is_bundle_copy(path, bundle_root):
            # Never treat the bundled fallback as a user installation.
            continue
        key = os.path.normcase(os.path.abspath(str(path)))
        if key in seen:
            continue
        seen.add(key)
        score = _score_install(path)
        if score > best_score:
            best, best_score = path, score
    return best, best_score


# Directory names that never contain a user-installed Everything; pruning them
# keeps the portable-copy scan fast on large drives.
_PORTABLE_SCAN_PRUNE = {
    "$recycle.bin",
    "$winreagent",
    ".git",
    "__pycache__",
    "node_modules",
    "perflogs",
    "recovery",
    "system volume information",
    "windows",
    "windows.old",
}


def _fixed_drives() -> list[Path]:
    """Locally attached fixed drives (no network or removable drives)."""
    if not _IS_WIN:
        return []
    try:
        mask = int(ctypes.windll.kernel32.GetLogicalDrives())
        drive_type = ctypes.windll.kernel32.GetDriveTypeW
    except OSError:  # pragma: no cover - defensive
        return []
    drives: list[Path] = []
    for index in range(26):
        if not mask & (1 << index):
            continue
        letter = chr(ord("A") + index)
        try:
            if int(drive_type(f"{letter}:\\")) != 3:  # DRIVE_FIXED
                continue
        except OSError:  # pragma: no cover - defensive
            continue
        drives.append(Path(f"{letter}:\\"))
    return drives


def _portable_exe_candidates() -> list[Path]:
    """Everything executables in non-standard folders (portable installations).

    Only used when the registry and the well-known folders found nothing, so a
    portable copy such as ``D:\\Tools\\Everything\\everything.exe`` is still
    reused instead of building a second index.  Copies that already have an
    ``Everything.db`` are preferred and stop the scan early.
    """
    found: list[Path] = []
    with_db: list[Path] = []
    system_drive = os.environ.get("SystemDrive", "C:").rstrip("\\").rstrip(":").upper()
    for drive in _fixed_drives():
        depth = 3 if drive.drive.rstrip(":").upper() == system_drive else 6
        try:
            for dirpath, dirnames, filenames in os.walk(
                drive, topdown=True, onerror=lambda _exc: None
            ):
                current = Path(dirpath)
                try:
                    level = len(current.relative_to(drive).parts)
                except ValueError:  # pragma: no cover - defensive
                    level = 0
                if level >= depth:
                    dirnames[:] = []
                else:
                    dirnames[:] = [d for d in dirnames if d.lower() not in _PORTABLE_SCAN_PRUNE]
                for name in filenames:
                    if name.lower() not in ("everything.exe", "everything64.exe"):
                        continue
                    exe = current / name
                    found.append(exe)
                    try:
                        if (current / "Everything.db").is_file():
                            with_db.append(exe)
                    except OSError:
                        pass
        except OSError:  # pragma: no cover - unreadable drive
            continue
        if with_db:
            break
    return with_db or found


def find_user_everything() -> Path | None:
    """Locate the user's own Everything installation, if any.

    Sources, in priority order: ``EVERYTHING_USER_EXE``, ``host-config.json``
    (written by setup.ps1), the Windows Registry, well-known install
    directories, and finally a bounded scan of local fixed drives for portable
    copies.  Installs with an existing ``Everything.db`` are preferred, because
    they are the ones whose index makes the first search instant.
    """
    if _env_bool("EVERYTHING_DISABLE_USER_INSTALL", False):
        logger.info("EVERYTHING_DISABLE_USER_INSTALL is set: using the bundled fallback")
        return None

    candidates: list[Path] = []

    env_exe = os.environ.get("EVERYTHING_USER_EXE", "").strip()
    if env_exe:
        candidates.append(Path(env_exe))

    config = _read_bundle_config()
    recorded = config.get("everything") if isinstance(config, dict) else None
    if isinstance(recorded, dict):
        for key in ("user_install", "user_exe"):
            value = recorded.get(key)
            if isinstance(value, str) and value.strip():
                candidates.append(Path(value.strip()))

    for directory in _registry_install_dirs() + _common_install_dirs():
        candidates.extend(_exe_candidates(directory))
    candidates.extend(_registry_exe_candidates())

    bundle_root = _bundle_root()
    seen: set[str] = set()
    best: Path | None = None
    best_score = -1
    best, best_score = _pick_best_install(candidates, bundle_root, seen, best, best_score)
    if best is None and not _env_bool("EVERYTHING_NO_DRIVE_SCAN", False):
        logger.info("Scanning local drives for a portable Everything installation")
        best, best_score = _pick_best_install(
            _portable_exe_candidates(), bundle_root, seen, best, best_score
        )
    return best


# ── Win32 helpers ─────────────────────────────────────────────────────────


def _ipc_window(instance: str) -> int:
    """HWND of Everything's IPC window for *instance*, 0 when absent."""
    if not _IS_WIN:
        return 0
    name = _IPC_CLASS + (f"_({instance})" if instance else "")
    try:
        return int(ctypes.windll.user32.FindWindowW(name, None) or 0)
    except OSError:  # pragma: no cover - defensive
        return 0


def _pid_image(pid: int) -> str | None:
    """Full image path of a live *pid*, or ``None`` when it is gone/denied."""
    if not _IS_WIN or pid <= 0:
        return None
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return None
    try:
        size = ctypes.c_ulong(1024)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return None
        return buffer.value
    finally:
        kernel32.CloseHandle(handle)


def _kill(pid: int) -> None:
    """Terminate *pid* (Windows), preferring the direct API over ``taskkill``.

    ``taskkill`` can be denied when the caller runs under a restricted token or
    sandbox even though the process itself is ours; OpenProcess/TerminateProcess
    is the same call Everything's own supervisor path needs and never depends on
    spawning an extra utility.
    """
    if pid <= 0:
        return
    if _IS_WIN:
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x0001, False, int(pid))  # PROCESS_TERMINATE
        if handle:
            try:
                kernel32.TerminateProcess(handle, 1)
            finally:
                kernel32.CloseHandle(handle)
            return
    try:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            capture_output=True,
            timeout=15,
            creationflags=_CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover
        logger.warning("taskkill %s failed: %s", pid, exc)


class EverythingSupervisor:
    """Reuse a running Everything, or start the best available copy on demand."""

    def __init__(
        self,
        exe_path: str | os.PathLike[str] | None = None,
        es_path: str | os.PathLike[str] | None = None,
        instance: str | None = None,
        enabled: bool | None = None,
        idle_timeout: float | None = None,
        start_timeout: float | None = None,
        user_exe: str | os.PathLike[str] | None = None,
    ) -> None:
        self.bundle_exe = Path(
            exe_path
            or os.environ.get("EVERYTHING_EXE", "").strip()
            or _default_exe()
        )
        self.es_path = Path(
            es_path
            or os.environ.get("EVERYTHING_ES_PATH", "").strip()
            or _default_es()
        )
        self.bundle_instance = (
            instance
            or os.environ.get("EVERYTHING_MCP_INSTANCE", "").strip()
            or "everything-mcp"
        )
        self.user_exe_hint = Path(user_exe) if user_exe else None
        self.explicit_instance = os.environ.get("EVERYTHING_INSTANCE", "").strip() or None
        self.enabled = (
            _env_bool("EVERYTHING_AUTOSTART", True) if enabled is None else bool(enabled)
        )
        self.idle_timeout = (
            _env_float("EVERYTHING_IDLE_TIMEOUT", 600.0)
            if idle_timeout is None
            else float(idle_timeout)
        )
        self.start_timeout = (
            _env_float("EVERYTHING_START_TIMEOUT", 60.0)
            if start_timeout is None
            else float(start_timeout)
        )

        self._lock = threading.RLock()
        self._pid = 0
        self._own = False
        self._active_instance = ""  # "" = Everything's default instance
        self._connected = False
        self._active_exe: Path | None = None
        self._kind = "none"  # "user", "bundled", "already-running", "explicit"
        self._last_activity = time.monotonic()
        self._watchdog: threading.Thread | None = None
        self._stop_watchdog = threading.Event()

    # ── introspection ─────────────────────────────────────────────────────

    @property
    def pid(self) -> int:
        return self._pid

    @property
    def instance(self) -> str:
        """Instance name to pass to es.exe (bundled fallback only)."""
        return self.bundle_instance

    @property
    def active_instance(self) -> str:
        """Instance currently in use (``""`` = Everything's default)."""
        return self._active_instance

    @property
    def connected(self) -> bool:
        return self._connected

    @property
    def own_instance(self) -> bool:
        """True when *this* process started the Everything in use."""
        return self._own

    @property
    def kind(self) -> str:
        return self._kind

    @property
    def active_exe(self) -> Path | None:
        return self._active_exe

    def set_es_path(self, es_path: str | os.PathLike[str]) -> None:
        """Prefer the es.exe location the config module detected."""
        if es_path:
            self.es_path = Path(es_path)

    def touch(self) -> None:
        """Record MCP activity (for the idle watchdog and other processes)."""
        self._last_activity = time.monotonic()
        try:
            self._heartbeat_path().write_text(f"{time.time():.3f}", encoding="ascii")
        except OSError:  # pragma: no cover - heartbeat is best effort
            pass

    # ── probes ────────────────────────────────────────────────────────────

    def probe(self, instance: str | None = None) -> bool:
        """True when Everything answers on *instance* (None/"" = default)."""
        return bool(_ipc_window(instance or ""))

    def ipc_alive(self) -> bool:
        """True when the instance currently in use still answers."""
        if self._connected:
            return self.probe(self._active_instance)
        return self.probe(self.explicit_instance) or self.probe(self.bundle_instance)

    # ── lifecycle ─────────────────────────────────────────────────────────

    def ensure_available(self) -> bool:
        """Make an Everything available and remember which one to talk to.

        Never stops anything.  Returns ``True`` when an instance answers
        afterwards; ``own_instance`` then tells whether this process started
        it (and is therefore responsible for stopping it).
        """
        with self._lock:
            if self._connected and self.ipc_alive():
                self.touch()
                return True

            # 1. Explicit EVERYTHING_INSTANCE: connect only, never autostart.
            if self.explicit_instance:
                if self.probe(self.explicit_instance):
                    self._connected = True
                    self._own = False
                    self._active_instance = self.explicit_instance
                    self._kind = "explicit"
                    logger.info(
                        "Connected to explicitly configured Everything instance '%s'",
                        self.explicit_instance,
                    )
                    self.touch()
                    return True
                logger.warning(
                    "Everything instance '%s' from EVERYTHING_INSTANCE is not running",
                    self.explicit_instance,
                )
                return False

            # Reap an instance this package started earlier but never stopped
            # (crashed server, timed-out idle shutdown, ...) before treating a
            # running Everything as somebody else's.
            self._cleanup_stale_owner()

            # 2. An Everything is already running: use it, never stop it.
            if self.probe(""):
                return self._connect_existing()

            if not self.enabled:
                logger.info("Everything autostart disabled (EVERYTHING_AUTOSTART=0)")
                return False

            # 3./4. Start the user's installation, else the bundled fallback.

            user_exe = self._resolve_user_exe()
            if user_exe is not None:
                if self._storage_writable(user_exe):
                    if self._start(exe=user_exe, instance="", kind="user"):
                        return True
                    logger.warning(
                        "Could not start the installed Everything at %s; "
                        "falling back to the bundled copy",
                        user_exe,
                    )
                else:
                    logger.warning(
                        "The installed Everything at %s cannot write its settings/data "
                        "from this process (its folder or %%APPDATA%%\\Everything is not "
                        "writable), so starting it would make Everything show a "
                        "save-settings dialog. Using the bundled fallback instead.",
                        user_exe,
                    )

            if self._same_as_user_install():
                logger.warning("The bundled everything.exe is the only available copy")
            if not self.bundle_exe.is_file():
                logger.warning("Bundled everything.exe not found: %s", self.bundle_exe)
                return False
            if not _IS_WIN:
                logger.warning("Everything autostart is Windows-only")
                return False
            if self._start(self.bundle_exe, self.bundle_instance, kind="bundled"):
                logger.info(
                    "Using the bundled Everything fallback: its first run has to build "
                    "its own file index, which can take a while"
                )
                return True
            return False

    def _connect_existing(self) -> bool:
        self._connected = True
        self._own = False
        self._active_instance = ""
        self._kind = "already-running"
        logger.info("Everything is already running: connecting to it (never stopped by us)")
        self.touch()
        return True

    def _resolve_user_exe(self) -> Path | None:
        if self.user_exe_hint is not None:
            try:
                if self.user_exe_hint.is_file():
                    return self.user_exe_hint
            except OSError:
                pass
        return find_user_everything()

    def _same_as_user_install(self) -> bool:
        return _same_path(self.bundle_exe, find_user_everything())

    def _storage_writable(self, exe: Path) -> bool:
        """Whether Everything can save its settings when started from here.

        Portable copies keep ``Everything.ini``/``Everything.db`` next to the
        executable and need that folder to be writable; installed copies keep
        their data in ``%APPDATA%\\Everything``.  Starting a copy whose storage
        is not writable makes Everything pop up a modal "cannot save settings"
        dialog, so refuse instead.
        """
        folder = exe.parent
        try:
            portable = (folder / "Everything.ini").is_file()
        except OSError:
            portable = False
        if portable:
            return _dir_writable(folder)
        appdata = os.environ.get("APPDATA", "").strip()
        if not appdata:
            return True
        target = Path(appdata) / "Everything"
        try:
            target.mkdir(parents=True, exist_ok=True)
        except OSError:
            return False
        return target.is_dir() and _dir_writable(target)

    def _start(self, exe: Path, instance: str, kind: str) -> bool:
        """Start *exe* hidden and wait for its IPC window."""
        try:
            if not exe.is_file():
                logger.warning("%s Everything executable not found: %s", kind, exe)
                return False
        except OSError:
            return False

        if not self._storage_writable(exe):
            logger.warning(
                "Refusing to start the %s Everything at %s: its settings folder is "
                "not writable, so Everything would show a save-settings dialog.",
                kind,
                exe,
            )
            return False

        cmd = [str(exe), "-startup"]
        if instance:
            cmd += ["-instance", instance]
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(exe.parent),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=_CREATE_NO_WINDOW,
                close_fds=True,
            )
        except OSError as exc:
            logger.warning("Failed to start %s Everything (%s): %s", kind, exe, exc)
            return False

        self._pid = proc.pid
        self._own = True
        self._active_instance = instance
        self._active_exe = exe
        self._kind = kind
        self.touch()
        self._write_owner()

        deadline = time.monotonic() + max(self.start_timeout, 5.0)
        while time.monotonic() < deadline:
            if self.probe(instance):
                self._connected = True
                logger.info(
                    "Started the %s Everything (pid %s, instance %s, exe %s) and it answers",
                    kind,
                    proc.pid,
                    instance or "default",
                    exe,
                )
                self.touch()
                self.start_watchdog()
                return True
            if proc.poll() is not None:
                logger.warning("%s Everything exited during startup (code %s)", kind, proc.returncode)
                break
            time.sleep(_POLL_INTERVAL)

        logger.warning(
            "%s Everything did not create its IPC window within %.0fs",
            kind,
            self.start_timeout,
        )
        self._terminate_own()
        return False

    def shutdown(self, reason: str = "") -> None:
        """Stop the instance this supervisor started (no-op otherwise)."""
        with self._lock:
            self.stop_watchdog()
            if not self._own:
                self._remove_owner()
                self._remove_heartbeat()
                self._connected = False
                return
            pid = self._pid
            instance = self._active_instance
            logger.info(
                "Stopping the %s Everything (pid %s, instance %s): %s",
                self._kind,
                pid,
                instance or "default",
                reason or "shutdown",
            )
            graceful = self._request_exit(instance, 8.0)
            if not graceful and pid > 0:
                dialogs = _dismiss_dialogs(pid)
                if dialogs:
                    logger.info(
                        "Closed %d modal dialog window(s) of Everything and retried", dialogs
                    )
                    time.sleep(0.5)
                    graceful = self._request_exit(instance, 8.0)
            # Everything flushes its database while exiting; give it time and
            # never kill it while it may still be writing.  If it refuses to
            # exit, keep the owner record so the next start retries the cleanup.
            if not self._wait_ipc_gone(instance, 30.0):
                logger.warning(
                    "Everything did not exit within %.0f s; leaving it running "
                    "(the next everything-mcp start will retry)",
                    30.0,
                )
                self._own = False
                self._pid = 0
                self._connected = False
                self._active_exe = None
                self._kind = "left-running"
                self._remove_heartbeat()
                return
            self._spawned_reset()
            self._remove_owner()
            self._remove_heartbeat()

    def _spawned_reset(self) -> None:
        self._own = False
        self._pid = 0
        self._connected = False
        self._active_exe = None
        self._kind = "none"

    def _request_exit(self, instance: str, timeout: float) -> bool:
        """Ask *instance* to quit via ``es.exe -exit``."""
        if not self.es_path.is_file():
            return False
        cmd = [str(self.es_path)]
        if instance:
            cmd += ["-instance", instance]
        cmd.append("-exit")
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                timeout=timeout,
                creationflags=_CREATE_NO_WINDOW,
            )
            if proc.returncode == 0:
                logger.info("es.exe -exit succeeded")
                return True
            logger.warning(
                "es.exe -exit returned %s: %s",
                proc.returncode,
                (proc.stderr or b"").decode("utf-8", "replace").strip()[:200],
            )
        except (OSError, subprocess.SubprocessError) as exc:
            logger.warning("es.exe -exit failed: %s", exc)
        return False

    def _terminate_own(self) -> None:
        """Terminate the process this supervisor just spawned."""
        pid = self._pid
        instance = self._active_instance
        self._spawned_reset()
        self._remove_owner()
        if pid:
            _dismiss_dialogs(pid)
        if pid and _pid_image(pid):
            _kill(pid)
        if pid:
            self._wait_ipc_gone(instance, 5.0)

    def _wait_ipc_gone(self, instance: str, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.probe(instance):
                return True
            time.sleep(_POLL_INTERVAL)
        return not self.probe(instance)

    # ── idle watchdog ─────────────────────────────────────────────────────

    def start_watchdog(self) -> None:
        """Start the idle-timeout thread (idempotent)."""
        with self._lock:
            if self._watchdog is not None and self._watchdog.is_alive():
                return
            if self.idle_timeout <= 0:
                return
            self._stop_watchdog.clear()
            self._watchdog = threading.Thread(
                target=self._watch_loop, name="everything-idle-watchdog", daemon=True
            )
            self._watchdog.start()
            logger.info("Idle watchdog started (%.0f s)", self.idle_timeout)

    def stop_watchdog(self) -> None:
        self._stop_watchdog.set()
        thread = self._watchdog
        self._watchdog = None
        if thread is not None and thread.is_alive() and thread is not threading.current_thread():
            thread.join(timeout=3)

    def _watch_loop(self) -> None:
        interval = max(1.0, min(30.0, self.idle_timeout / 4.0))
        while not self._stop_watchdog.wait(interval):
            if not self._own:
                continue
            # ``_last_activity`` is monotonic while the heartbeat file mtime is
            # wall-clock time; never compare them directly.  A heartbeat from
            # another session keeps the instance alive, so take the smaller age.
            idle = time.monotonic() - self._last_activity
            heartbeat = self._heartbeat_mtime()
            if heartbeat > 0:
                idle = min(idle, max(0.0, time.time() - heartbeat))
            if idle >= self.idle_timeout:
                try:
                    self.shutdown("idle timeout")
                except Exception:  # pragma: no cover - watchdog must survive
                    logger.exception("Idle shutdown failed")

    # ── index readiness (used by setup prewarm) ───────────────────────────

    def result_count(self) -> int | None:
        """Total indexed file count (``es -get-result-count``), or None."""
        if not self.es_path.is_file():
            return None
        cmd = [str(self.es_path)]
        if self._active_instance:
            cmd += ["-instance", self._active_instance]
        cmd += ["-get-result-count", "*"]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                timeout=max(15.0, self.start_timeout),
                creationflags=_CREATE_NO_WINDOW,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if proc.returncode != 0:
            return None
        text = proc.stdout.decode("utf-8", "replace").strip()
        try:
            return int(text)
        except ValueError:
            return None

    def wait_until_indexed(self, timeout: float = 900.0) -> int | None:
        """Wait until the index answers with at least one file."""
        deadline = time.monotonic() + timeout
        next_probe = 0.0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_probe:
                next_probe = now + _PROBE_INTERVAL
                count = self.result_count()
                if count is not None and count > 0:
                    return count
            time.sleep(_POLL_INTERVAL)
        return None

    # ── state files ───────────────────────────────────────────────────────

    def _heartbeat_path(self) -> Path:
        return _state_dir() / f"{_STATE_STEM}.heartbeat"

    def _remove_heartbeat(self) -> None:
        try:
            self._heartbeat_path().unlink()
        except OSError:
            pass

    def _heartbeat_mtime(self) -> float:
        try:
            return self._heartbeat_path().stat().st_mtime
        except OSError:
            return 0.0

    def _owner_path(self) -> Path:
        return _state_dir() / f"{_STATE_STEM}.owner.json"

    def _write_owner(self) -> None:
        payload = {
            "pid": self._pid,
            "exe": str(self._active_exe or ""),
            "instance": self._active_instance,
            "kind": self._kind,
            "started_at": time.time(),
        }
        try:
            self._owner_path().write_text(json.dumps(payload), encoding="utf-8")
        except OSError:  # pragma: no cover - best effort
            pass

    def _remove_owner(self) -> None:
        try:
            self._owner_path().unlink()
        except OSError:
            pass

    def _cleanup_stale_owner(self) -> None:
        """Reap an instance this bundle started earlier but never stopped."""
        path = self._owner_path()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            pid = int(payload.get("pid", 0))
            exe = str(payload.get("exe", ""))
            instance = str(payload.get("instance", "") or "")
        except (OSError, ValueError, TypeError):
            self._remove_owner()
            return
        if pid <= 0 or not exe:
            self._remove_owner()
            return
        image = _pid_image(pid)
        if image is None or not _same_path(image, exe):
            # Either the process is gone, or the PID was reused by another image.
            self._remove_owner()
            self._remove_heartbeat()
            return
        logger.info("Cleaning up a stale Everything instance from a previous session (pid %s)", pid)
        if not self._request_exit(instance, 10.0) and pid > 0:
            dialogs = _dismiss_dialogs(pid)
            if dialogs:
                logger.info("Closed %d modal dialog window(s) of Everything", dialogs)
        if not self._wait_ipc_gone(instance, 10.0):
            if pid > 0 and _pid_image(pid):
                logger.warning(
                    "The stale Everything instance did not exit; terminating pid %s", pid
                )
                _kill(pid)
                self._wait_ipc_gone(instance, 5.0)
        self._remove_owner()
        self._remove_heartbeat()


# ── process-wide singleton ────────────────────────────────────────────────

_supervisor: EverythingSupervisor | None = None
_supervisor_lock = threading.Lock()


def get_supervisor() -> EverythingSupervisor:
    """Return the process-wide supervisor (created on first use)."""
    global _supervisor
    with _supervisor_lock:
        if _supervisor is None:
            _supervisor = EverythingSupervisor()
            atexit.register(_supervisor.shutdown, "process exit")
        return _supervisor


def reset_supervisor() -> None:
    """Drop the singleton without stopping it (tests only)."""
    global _supervisor
    with _supervisor_lock:
        _supervisor = None


# ── command line (setup prewarm / manual control) ─────────────────────────

def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m everything_mcp.supervisor",
        description="Control the Everything instance used by everything-mcp.",
    )
    parser.add_argument("--prewarm", action="store_true", help="wait until the index is ready")
    parser.add_argument("--stop", action="store_true", help="stop the instance we started")
    parser.add_argument("--status", action="store_true", help="print the current state")
    parser.add_argument("--timeout", type=float, default=900.0, help="prewarm timeout in seconds")
    parser.add_argument("--quiet", action="store_true", help="only log warnings")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.WARNING if args.quiet else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        stream=sys.stderr,
    )
    supervisor = get_supervisor()

    if args.stop:
        if not supervisor.own_instance:
            print("nothing started by this process; leaving Everything alone")
            return 0
        supervisor.shutdown("command line --stop")
        print("stopped the Everything instance started by everything-mcp")
        return 0

    if args.status:
        user_exe = find_user_everything()
        running_default = supervisor.probe("")
        running_bundle = supervisor.probe(supervisor.bundle_instance)
        explicit = supervisor.explicit_instance
        running_explicit = bool(explicit) and supervisor.probe(explicit)
        print(
            json.dumps(
                {
                    "user_install": str(user_exe) if user_exe else None,
                    "bundled_exe": str(supervisor.bundle_exe),
                    "es": str(supervisor.es_path),
                    "running_default": running_default,
                    "running_bundled_instance": running_bundle,
                    "explicit_instance": explicit,
                    "running_explicit_instance": running_explicit,
                    "connected": supervisor.connected,
                    "own_instance": supervisor.own_instance,
                    "kind": supervisor.kind,
                    "active_instance": supervisor.active_instance or None,
                    "active_exe": str(supervisor.active_exe) if supervisor.active_exe else None,
                    "pid": supervisor.pid,
                    "idle_timeout_s": supervisor.idle_timeout,
                    "autostart": supervisor.enabled,
                },
                indent=2,
            )
        )
        return 0

    available = supervisor.ensure_available()
    if not available or not supervisor.ipc_alive():
        print(
            "ERROR: no Everything is available. Start Everything yourself, or check "
            f"{supervisor.bundle_exe}.",
            file=sys.stderr,
        )
        return 2
    target = supervisor.active_instance or "default"
    if not args.prewarm:
        print(
            f"Everything available: instance={target}, kind={supervisor.kind}, "
            f"own_instance={supervisor.own_instance}, pid={supervisor.pid}"
        )
        return 0

    count = supervisor.wait_until_indexed(args.timeout)
    if count is None:
        print(
            f"ERROR: the index did not become ready within {args.timeout:.0f}s",
            file=sys.stderr,
        )
        return 3
    print(f"index ready: {count} files indexed (instance={target}, kind={supervisor.kind})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
