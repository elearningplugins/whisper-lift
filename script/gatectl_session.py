#!/usr/bin/env python3
"""Runs the approved vendor/gatectl for a supervised Phase 2 session, enforcing the PLAN.md operational restrictions first."""

import os
import stat
import subprocess
import sys
from pathlib import Path

# The patched tree recorded in docs/gatectl-security-review.md; any change under vendor/gatectl must update both.
APPROVED_TREE = "c1e3996937a493454dca51a7bd456d1490df2e05"
SESSIONS = {"mac": "mac", "phone-seed": "phone-seed"}
KEPT_ENVIRONMENT = ("HOME", "PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "USER", "LOGNAME")
# The one ignored local file that holds the App Check debug token for both Xcode and gatectl.
LOCAL_CONFIG = "config/MyQ.local.xcconfig"
DEBUG_TOKEN_SETTING = "MYQ_APP_CHECK_DEBUG_TOKEN"


class SessionRefused(Exception):
    """The session would break an operational restriction, so gatectl is not started."""


def plan_invocation(
    *,
    repo: Path,
    home: Path,
    approved_tree: str,
    session_name: str,
    gatectl_args: list[str],
    environ: dict[str, str],
    python_version: tuple[int, int] = sys.version_info[:2],
) -> tuple[list[str], dict[str, str]]:
    """Checks every restriction and returns the argv and environment to exec, without running anything."""
    if session_name not in SESSIONS:
        raise SessionRefused(f"Unknown session {session_name!r}; use one of {', '.join(SESSIONS)}")
    if python_version < (3, 11):
        raise SessionRefused("gatectl needs Python 3.11 or newer")
    if any(arg == "-y" or arg == "--yes" or arg.startswith("--yes=") for arg in gatectl_args):
        raise SessionRefused("--yes is not allowed; confirm each door command interactively")
    if "MYQ_PASSWORD" in environ:
        raise SessionRefused("Unset MYQ_PASSWORD; enter the password only at gatectl's hidden prompt")
    _require_owner_pass(repo / "docs/gatectl-security-review.md")
    _require_approved_tree(repo, approved_tree)
    private = _private_directory(home / ".config/myq-carplay")
    prefix = SESSIONS[session_name]
    env = {name: environ[name] for name in KEPT_ENVIRONMENT if name in environ}
    env.update(
        PYTHONPATH=str(repo / "vendor/gatectl/src"),
        PYTHONNOUSERSITE="1",
        GATECTL_CONFIG=str(private / "mac-targets.json"),
        GATECTL_TOKEN_FILE=str(private / f"{prefix}-tokens.json"),
        GATECTL_STATE_FILE=str(private / f"{prefix}-state.json"),
    )
    debug_token = _local_setting(repo / LOCAL_CONFIG, DEBUG_TOKEN_SETTING)
    if debug_token:
        env["GATECTL_APP_CHECK_DEBUG_TOKEN"] = debug_token
    return [sys.executable, "-m", "gatectl", *gatectl_args], env


def _require_owner_pass(review: Path) -> None:
    try:
        lines = review.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise SessionRefused(f"Cannot read the approval record in {review}") from error
    for line in lines:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) == 2 and cells[0] == "Owner decision":
            if cells[1].strip("*_ ").casefold() == "pass":
                return
            break
    raise SessionRefused("The approval record has no owner pass decision; Phase 2 is blocked")


def _require_approved_tree(repo: Path, approved_tree: str) -> None:
    def git(*args: str) -> str:
        result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise SessionRefused(f"git {' '.join(args)} failed")
        return result.stdout.strip()

    if git("status", "--porcelain", "--untracked-files=all", "--", "vendor/gatectl"):
        raise SessionRefused("vendor/gatectl has uncommitted or untracked changes")
    actual = git("rev-parse", "HEAD:vendor/gatectl")
    if actual != approved_tree:
        raise SessionRefused(f"vendor/gatectl tree is {actual}, not the approved {approved_tree}")


def _local_setting(path: Path, name: str) -> str | None:
    """Reads one `NAME = value` line from the xcconfig-style local file; a missing file or blank value means not configured."""
    if path.is_symlink():
        raise SessionRefused(f"{path} is a symbolic link")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SessionRefused(f"Cannot read {path}") from error
    for line in lines:
        key, separator, value = line.partition("=")
        if separator and key.strip() == name:
            return value.strip() or None
    return None


def _private_directory(path: Path) -> Path:
    if path.is_symlink():
        raise SessionRefused(f"{path} is a symbolic link")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise SessionRefused(f"{path} must be a directory owned by you")
    os.chmod(path, 0o700)
    return path


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in SESSIONS:
        print("usage: script/gatectl_session.py mac|phone-seed <gatectl arguments>", file=sys.stderr)
        return 2
    repo = Path(__file__).resolve().parent.parent
    try:
        command, env = plan_invocation(
            repo=repo, home=Path.home(), approved_tree=APPROVED_TREE, session_name=argv[0], gatectl_args=argv[1:], environ=dict(os.environ)
        )
    except SessionRefused as error:
        print(f"gatectl-session: refused: {error}", file=sys.stderr)
        return 3
    print(f"gatectl-session: {argv[0]} session, approved tree {APPROVED_TREE[:12]}, tokens in {env['GATECTL_TOKEN_FILE']}", file=sys.stderr)
    os.execve(command[0], command, env)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
