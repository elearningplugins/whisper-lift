"""Runs the vendored gatectl unit tests with DNS and every non-loopback connection blocked, so no test can reach myQ."""

import contextlib
import io
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path

GATECTL = Path(__file__).resolve().parent.parent / "vendor" / "gatectl"
LOOPBACK = {"127.0.0.1", "::1", "localhost"}

_real_connect = socket.socket.connect
_real_connect_ex = socket.socket.connect_ex
_real_getaddrinfo = socket.getaddrinfo


class NetworkBlockedError(OSError):
    """Raised when a test tries to leave the loopback interface."""


def _check(address: object) -> None:
    if isinstance(address, tuple) and address and address[0] in LOOPBACK:
        return
    if isinstance(address, (str, bytes)):
        return
    raise NetworkBlockedError(f"offline test run blocked a connection to {address!r}")


def _connect(self: socket.socket, address: object) -> None:
    _check(address)
    return _real_connect(self, address)


def _connect_ex(self: socket.socket, address: object) -> int:
    _check(address)
    return _real_connect_ex(self, address)


def _getaddrinfo(host: object, *args: object, **kwargs: object):  # type: ignore[no-untyped-def]
    if host is None or (host.decode() if isinstance(host, bytes) else host) in LOOPBACK:
        return _real_getaddrinfo(host, *args, **kwargs)
    raise NetworkBlockedError(f"offline test run blocked a DNS lookup for {host!r}")


def smoke() -> bool:
    """Runs the real CLI offline and checks each path fails cleanly before any network use."""
    from gatectl.cli import main as gatectl_main

    ok = True
    with tempfile.TemporaryDirectory() as directory:
        private = Path(directory) / "private"
        config = Path(directory) / "targets.json"
        config.write_text('{"account":"Demo Home","devices":["Garage Door"]}', encoding="utf-8")
        os.environ.update(
            GATECTL_CONFIG=str(config),
            GATECTL_TOKEN_FILE=str(private / "tokens.json"),
            GATECTL_STATE_FILE=str(private / "state.json"),
        )
        cases = [
            (["--help"], 0, "usage: gatectl"),
            (["status"], 2, "No MyQ session found"),
            (["open", "Garage Door"], 2, "No MyQ session found"),
            (["close", "Garage Door", "--wait", "500"], 2, "--wait must be between"),
            (["--config", str(Path(directory) / "missing.json"), "status"], 2, "No target config found"),
        ]
        for argv, expected_code, expected_text in cases:
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                try:
                    code = gatectl_main(argv)
                except SystemExit as exit_:
                    code = exit_.code
            passed = code == expected_code and expected_text in output.getvalue()
            ok = ok and passed
            print(f"smoke {'ok  ' if passed else 'FAIL'} gatectl {' '.join(argv)} -> {code}")
    return ok


def main() -> int:
    socket.socket.connect = _connect  # type: ignore[method-assign]
    socket.socket.connect_ex = _connect_ex  # type: ignore[method-assign]
    socket.getaddrinfo = _getaddrinfo  # type: ignore[assignment]
    try:
        socket.create_connection(("partner-identity.myq-cloud.com", 443), timeout=1)
    except NetworkBlockedError:
        pass
    else:
        print("network guard failed to block myQ", file=sys.stderr)
        return 1
    sys.path.insert(0, str(GATECTL / "src"))
    suite = unittest.defaultTestLoader.discover(str(GATECTL / "tests"), top_level_dir=str(GATECTL / "tests"))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    smoke_ok = smoke()
    return 0 if result.wasSuccessful() and smoke_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
