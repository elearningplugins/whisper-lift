from __future__ import annotations

import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Mapping

from .errors import MyQApiError, TokenStoreError
from .models import OAuthTokens

CONFIG_ROOT = Path("/usr/local/config/gatectl")


def token_path() -> Path:
    override = os.environ.get("GATECTL_TOKEN_FILE")
    return Path(override).expanduser() if override else CONFIG_ROOT / "tokens.json"


def observation_path() -> Path:
    override = os.environ.get("GATECTL_STATE_FILE")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local/state/gatectl/last-observation.json"


def target_config_path() -> Path:
    override = os.environ.get("GATECTL_CONFIG")
    return Path(override).expanduser() if override else CONFIG_ROOT / "targets.json"


def save_tokens(tokens: OAuthTokens, path: Path | None = None) -> Path:
    target = path or token_path()
    _atomic_private_json(target, tokens.as_dict())
    return target


def load_tokens(path: Path | None = None) -> OAuthTokens:
    target = path or token_path()
    if not os.path.lexists(target):
        raise TokenStoreError(f"No MyQ session found at {target}; run `gatectl login`")
    _require_private(target.parent, directory=True)
    _require_private(target, directory=False)
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise TokenStoreError(f"No MyQ session found at {target}; run `gatectl login`") from error
    except (OSError, json.JSONDecodeError) as error:
        raise TokenStoreError(f"Unable to read MyQ session at {target}") from error
    if not isinstance(data, dict):
        raise TokenStoreError(f"MyQ session at {target} is invalid")
    try:
        return OAuthTokens.from_dict(data)
    except MyQApiError as error:
        raise TokenStoreError(str(error)) from error


def save_observation(data: Mapping[str, object], path: Path | None = None) -> Path:
    target = path or observation_path()
    _atomic_private_json(target, data)
    return target


def _require_private(path: Path, *, directory: bool) -> None:
    """Refuses a symlink, the wrong file type, another owner, or group or other access, without following links (GQ-06)."""
    try:
        info = os.lstat(path)
    except OSError as error:
        raise TokenStoreError(f"Unable to inspect {path}") from error
    if stat.S_ISLNK(info.st_mode):
        raise TokenStoreError(f"{path} is a symbolic link; refusing to use it for private data")
    if directory and not stat.S_ISDIR(info.st_mode):
        raise TokenStoreError(f"{path} is not a directory")
    if not directory and not stat.S_ISREG(info.st_mode):
        raise TokenStoreError(f"{path} is not a regular file")
    if info.st_uid != os.getuid():
        raise TokenStoreError(f"{path} is owned by another user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise TokenStoreError(
            f"{path} has unsafe permissions; it must not be accessible to group or others"
        )


def _atomic_private_json(path: Path, data: Mapping[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = os.lstat(path.parent)
    if stat.S_ISLNK(info.st_mode):
        raise TokenStoreError(
            f"{path.parent} is a symbolic link; refusing to use it for private data"
        )
    if info.st_uid != os.getuid():
        raise TokenStoreError(f"{path.parent} is owned by another user")
    try:
        os.chmod(path.parent, 0o700)
    except OSError as error:
        raise TokenStoreError(f"Unable to make {path.parent} private") from error
    _require_private(path.parent, directory=True)
    if os.path.lexists(path):
        existing = os.lstat(path)
        if stat.S_ISLNK(existing.st_mode) or existing.st_uid != os.getuid():
            raise TokenStoreError(
                f"{path} is a symbolic link or owned by another user; refusing to replace it"
            )
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise
