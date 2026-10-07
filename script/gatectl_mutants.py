"""Applies each targeted mutant to the patched gatectl guards and requires the offline suite to fail for every one."""

import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
mutants = [
    ("auth.py", 'parts.scheme != "https"', 'parts.scheme == "ftp"'),
    ("auth.py", 'or "@" in parts.netloc\n', "\n"),
    ("auth.py", "or port not in (None, 443)", "or port not in (None, 443, 8443)"),
    ("auth.py", "(parts.hostname or \"\").casefold() != (_IDENTITY.hostname or \"\").casefold()", "not (parts.hostname or \"\").endswith(\"myq-cloud.com\")"),
    ("auth.py", "        _require_identity_origin(url)\n", ""),
    ("auth.py", "and parts.netloc == _CALLBACK.netloc", "and parts.netloc.startswith(_CALLBACK.netloc)"),
    ("auth.py", "and parts.path == _CALLBACK.path", ""),
    ("client.py", "if not 200 <= response.status < 300:", "if not 200 <= response.status < 600:"),
    ("client.py", "except (MyQApiError, OSError) as error:", "except MyQApiError as error:"),
    ("client.py", 'if method != "GET":', 'if method not in {"GET", "PUT"}:'),
    ("cli.py", "if (live.name, live.door_state, live.online) != (device.name, device.door_state, device.online):", "if live.door_state != device.door_state:"),
    ("cli.py", "    live = _refetch(client, device)\n", "    live = device\n"),
    ("cli.py", "if len(found) != 1:", "if not found:"),
    ("cli.py", "and candidate.serial_number == device.serial_number", ""),
    ("cli.py", "matches = tuple(device for device in matches if device.serial_number == pinned_serial)", "pass"),
    ("http.py", "if len(raw) > max_body_bytes:", "if len(raw) > max_body_bytes + 1:"),
    ("http.py", "raw = response.read(max_body_bytes + 1)", "raw = response.read()"),
    ("storage.py", "if stat.S_ISLNK(info.st_mode):\n        raise TokenStoreError(f\"{path} is", "if False:\n        raise TokenStoreError(f\"{path} is"),
    ("storage.py", "if info.st_uid != os.getuid():\n        raise TokenStoreError(f\"{path} is owned", "if False:\n        raise TokenStoreError(f\"{path} is owned"),
    ("storage.py", "if stat.S_IMODE(info.st_mode) & 0o077:", "if stat.S_IMODE(info.st_mode) & 0o007:"),
    ("storage.py", "if stat.S_IMODE(info.st_mode) & 0o077:", "if stat.S_IMODE(info.st_mode) & 0o070:"),
    ("storage.py", "if stat.S_IMODE(info.st_mode) & 0o077:", "if stat.S_IMODE(info.st_mode) & 0o066:"),
    ("models.py", "access_token=<redacted>", "access_token={self.access_token}"),
    ("client.py", "        _require_safe_fault_and_vacation(device, action)\n", ""),
    ("client.py", "        if faults:", "        if not faults:"),
    ("client.py", "if not isinstance(faults, list) or not all(isinstance(code, str) for code in faults):", "if False:"),
    ("client.py", "if not isinstance(vacation, bool):", "if False:"),
    ("client.py", 'if vacation and action == "open":', "if vacation:"),
    ("client.py", 'if vacation and action == "open":', 'if action == "open":'),
]
src = root / "vendor/gatectl/src/gatectl"
survivors = 0
for name, old, new in mutants:
    path = src / name
    original = path.read_text()
    if original.count(old) < 1:
        print(f"NOT FOUND  {name}: {old[:60]!r}")
        survivors += 1
        continue
    path.write_text(original.replace(old, new, 1))
    try:
        result = subprocess.run([sys.executable, "-I", str(root / "script/offline_unittest.py")], capture_output=True, text=True, timeout=300, check=False)
    finally:
        path.write_text(original)
    killed = result.returncode != 0
    survivors += not killed
    print(f"{'killed  ' if killed else 'SURVIVED'}  {name}: {old.strip()[:70]!r}")
print(f"{len(mutants) - survivors}/{len(mutants)} killed")
sys.exit(1 if survivors else 0)
