"""Security regression tests for the myq-carplay patches GQ-01 to GQ-06; every test uses fakes or loopback only."""

from __future__ import annotations

import os
import stat
import tempfile
import threading
import unittest
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Mapping
from unittest.mock import patch

from gatectl.auth import MyQAuth, MyQLoginSession
from gatectl.cli import _operate
from gatectl.client import MyQClient
from gatectl.constants import APP_CHECK_DEBUG_TOKEN_ENV, MFA_METHOD_EMAIL
from gatectl.errors import (
    MyQApiError,
    MyQAuthenticationError,
    MyQCommandOutcomeUnknownError,
    TokenStoreError,
)
from gatectl.http import HttpResponse, HttpSession
from gatectl.models import MyQAccount, MyQDevice, OAuthTokens
from gatectl.storage import load_tokens, save_tokens

IDENTITY = "https://partner-identity.myq-cloud.com"


@dataclass(frozen=True)
class Call:
    method: str
    url: str
    kwargs: Mapping[str, object]


class FakeSession:
    def __init__(self, responses: list[HttpResponse | Exception]) -> None:
        self.responses = responses
        self.calls: list[Call] = []

    def request(self, method: str, url: str, **kwargs: object) -> HttpResponse:
        self.calls.append(Call(method, url, kwargs))
        if not self.responses:
            raise AssertionError(f"Unexpected request: {method} {url}")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    def sent_values(self) -> list[str]:
        values: list[str] = []
        for call in self.calls:
            data = call.kwargs.get("data") or {}
            values.extend(str(value) for value in data.values())  # type: ignore[union-attr]
        return values


def page(path: str, body: str = "", status: int = 200, location: str | None = None) -> HttpResponse:
    headers = {"Location": location} if location is not None else {}
    return HttpResponse(f"{IDENTITY}{path}", status, headers, body)


def login_html(action: str = "/Account/Login?returnUrl=auth") -> str:
    return f"""
    <form method="post" action="{action}">
      <input type="hidden" name="__RequestVerificationToken" value="csrf-login">
      <input type="email" name="Email">
      <input type="password" name="Password">
    </form>
    """


def mfa_html(action: str = "/AccountMfa/VerifyOtp?returnUrl=auth") -> str:
    return f"""
    <form method="post" action="{action}">
      <input type="hidden" name="SelectedMfaMethod" value="Email">
      <input type="number" id="login_otp_input" name="Otp">
    </form>
    """


HOSTILE_DESTINATIONS = (
    "https://evil.example/Account/Login",
    "https://partner-identity.myq-cloud.com@evil.example/Account/Login",
    "https://user:pw@partner-identity.myq-cloud.com/Account/Login",  # pragma: allowlist secret
    "https://partner-identity.myq-cloud.com.evil.example/Account/Login",
    "https://evil-partner-identity.myq-cloud.com/Account/Login",
    "http://partner-identity.myq-cloud.com/Account/Login",
    "https://partner-identity.myq-cloud.com:8443/Account/Login",
    "//evil.example/Account/Login",
    "javascript:alert(1)",
    "file:///etc/passwd",
)


# A fabricated value in the debug-token shape; the real one lives only in ignored local configuration.
@patch.dict("os.environ", {APP_CHECK_DEBUG_TOKEN_ENV: "00000000-1111-4222-8333-444444444444"})
class OAuthDestinationTests(unittest.TestCase):
    """GQ-01: no sign-in request may leave the exact HTTPS identity origin."""

    def test_hostile_redirects_are_never_followed(self) -> None:
        for location in HOSTILE_DESTINATIONS:
            with self.subTest(location=location):
                session = FakeSession([page("/connect/authorize", status=302, location=location)])
                with self.assertRaisesRegex(MyQApiError, "unapproved"):
                    MyQLoginSession(session).start("driver@example.com", "secret", MFA_METHOD_EMAIL)  # type: ignore[arg-type]
                self.assertEqual(len(session.calls), 1)

    def test_cross_origin_login_form_never_receives_credentials(self) -> None:
        for action in HOSTILE_DESTINATIONS:
            with self.subTest(action=action):
                session = FakeSession([page("/Account/Login", login_html(action))])
                with self.assertRaisesRegex(MyQApiError, "unapproved"):
                    MyQLoginSession(session).start("driver@example.com", "secret", MFA_METHOD_EMAIL)  # type: ignore[arg-type]
                self.assertNotIn("secret", session.sent_values())
                self.assertNotIn("driver@example.com", session.sent_values())

    def test_cross_origin_mfa_form_never_receives_the_code(self) -> None:
        session = FakeSession(
            [
                page("/Account/Login", login_html()),
                page("/Account/Login", status=302, location="/AccountMfa/VerifyOtp"),
                page("/AccountMfa/VerifyOtp", mfa_html("https://evil.example/otp")),
            ]
        )
        login = MyQLoginSession(session)  # type: ignore[arg-type]
        try:
            login.start("driver@example.com", "secret", MFA_METHOD_EMAIL)
        except MyQApiError:
            pass
        with self.assertRaises(MyQApiError):
            login.submit_mfa("123456")
        self.assertNotIn("123456", session.sent_values())

    def test_cross_origin_consent_form_is_not_posted(self) -> None:
        consent = '<form method="post" action="https://evil.example/consent"><input name="x" value="y"></form>'
        session = FakeSession(
            [
                page("/Account/Login", login_html()),
                page("/Account/Login", status=302, location="/AccountMfa/VerifyOtp"),
                page("/AccountMfa/VerifyOtp", mfa_html()),
                page("/AccountMfa/VerifyOtp", status=302, location="/consent"),
                page("/consent", consent),
            ]
        )
        login = MyQLoginSession(session)  # type: ignore[arg-type]
        self.assertIsNone(login.start("driver@example.com", "secret", MFA_METHOD_EMAIL))
        with self.assertRaisesRegex(MyQApiError, "unapproved"):
            login.submit_mfa("123456")
        self.assertFalse(any("evil.example" in call.url for call in session.calls))

    def test_callback_must_match_scheme_host_and_path_exactly(self) -> None:
        for location in (
            "com.myqops://android.evil.example/?code=stolen",
            "com.myqops://androidx?code=stolen",
            "com.myqops://android/extra?code=stolen",
            "com.myqops://user@android?code=stolen",
            "com.myqopsx://android?code=stolen",
        ):
            with self.subTest(location=location):
                session = FakeSession([page("/connect/authorize", status=302, location=location)])
                with self.assertRaises(MyQApiError):
                    MyQLoginSession(session).start("driver@example.com", "secret", MFA_METHOD_EMAIL)  # type: ignore[arg-type]
                self.assertEqual(len(session.calls), 1)

    def test_exact_callback_is_accepted(self) -> None:
        session = FakeSession(
            [
                page("/connect/authorize", status=302, location="com.myqops://android?code=fresh"),
                HttpResponse("https://firebase", 200, {}, '{"token":"app-check"}'),
                HttpResponse(
                    f"{IDENTITY}/connect/token",
                    200,
                    {},
                    '{"access_token":"a","refresh_token":"r","expires_in":3600}',
                ),
            ]
        )
        tokens = MyQLoginSession(session).start("driver@example.com", "secret", MFA_METHOD_EMAIL)  # type: ignore[arg-type]
        self.assertIsNotNone(tokens)
        self.assertEqual(session.calls[-1].kwargs["data"]["code"], "fresh")  # type: ignore[index]


class FakeAuth:
    def __init__(self) -> None:
        self.refreshes = 0

    def access_token(self) -> str:
        return "access"

    def refresh(self) -> OAuthTokens:
        self.refreshes += 1
        return OAuthTokens("refreshed", "refresh", 9999999999)


def door(
    state: str = "closed",
    *,
    name: str = "Garage Door",
    serial: str = "door-1",
    account: str = "account-1",
) -> MyQDevice:
    return MyQDevice(
        account,
        "Demo Home",
        serial,
        name,
        "garagedoor",
        None,
        {
            "door_state": state,
            "online": True,
            "is_unattended_open_allowed": True,
            "is_unattended_close_allowed": True,
        },
    )


class PhysicalCommandTests(unittest.TestCase):
    """GQ-02: a physical PUT is sent at most once, whatever happens."""

    def test_no_put_is_repeated_after_any_unproven_outcome(self) -> None:
        outcomes: list[HttpResponse | Exception] = [
            HttpResponse("https://gdo/open", 401, {}, ""),
            HttpResponse("https://gdo/open", 403, {}, ""),
            HttpResponse("https://gdo/open", 429, {}, ""),
            HttpResponse("https://gdo/open", 500, {}, ""),
            HttpResponse("https://gdo/open", 302, {"Location": "/login"}, ""),
            MyQApiError("Unable to reach MyQ: timed out"),
            ConnectionResetError("connection reset"),
        ]
        for outcome in outcomes:
            with self.subTest(outcome=outcome):
                session = FakeSession([outcome])
                auth = FakeAuth()
                with self.assertRaises(MyQCommandOutcomeUnknownError):
                    MyQClient(session, auth).open_device(door("closed"))  # type: ignore[arg-type]
                self.assertEqual(len(session.calls), 1)
                self.assertEqual(auth.refreshes, 0)

    def test_outcome_unknown_is_an_api_error_that_says_not_to_repeat(self) -> None:
        session = FakeSession([HttpResponse("https://gdo/close", 500, {}, "")])
        with self.assertRaises(MyQApiError) as raised:
            MyQClient(session, FakeAuth()).close_device(door("open"))  # type: ignore[arg-type]
        self.assertIn("not repeated", str(raised.exception))

    def test_accepted_command_with_empty_body_is_sent_once(self) -> None:
        session = FakeSession([HttpResponse("https://gdo/open", 204, {}, "")])
        self.assertTrue(MyQClient(session, FakeAuth()).open_device(door("closed")))  # type: ignore[arg-type]
        self.assertEqual([call.method for call in session.calls], ["PUT"])

    def test_reads_still_refresh_once_after_401(self) -> None:
        session = FakeSession(
            [
                HttpResponse("https://accounts", 401, {}, ""),
                HttpResponse("https://accounts", 200, {}, '{"accounts":[]}'),
            ]
        )
        auth = FakeAuth()
        self.assertEqual(MyQClient(session, auth).get_accounts(), ())  # type: ignore[arg-type]
        self.assertEqual(auth.refreshes, 1)
        self.assertEqual(len(session.calls), 2)

    def test_reads_fail_after_a_second_401(self) -> None:
        session = FakeSession(
            [
                HttpResponse("https://accounts", 401, {}, ""),
                HttpResponse("https://accounts", 401, {}, ""),
            ]
        )
        with self.assertRaises(MyQAuthenticationError):
            MyQClient(session, FakeAuth()).get_accounts()  # type: ignore[arg-type]
        self.assertEqual(len(session.calls), 2)

    def test_the_retrying_read_path_refuses_every_write(self) -> None:
        session = FakeSession([])
        client = MyQClient(session, FakeAuth())  # type: ignore[arg-type]
        url = "https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/a/door_openers/d/open"
        for method in ("PUT", "POST", "DELETE", "PATCH"):
            with self.subTest(method=method):
                with self.assertRaisesRegex(MyQApiError, "unsupported MyQ write"):
                    client._request(method, url)  # noqa: SLF001
        self.assertEqual(session.calls, [])


class SequencedClient:
    """Fake client whose successive device fetches return the given batches."""

    def __init__(self, *batches: tuple[MyQDevice, ...]) -> None:
        self._batches = list(batches)
        self.fetches: list[tuple[MyQAccount, ...]] = []
        self.commands: list[tuple[str, MyQDevice]] = []

    def get_accounts(self) -> tuple[MyQAccount, ...]:
        return (MyQAccount("account-1", "Demo Home"),)

    def get_devices(self, accounts: tuple[MyQAccount, ...]) -> tuple[MyQDevice, ...]:
        self.fetches.append(tuple(accounts))
        if not self._batches:
            raise MyQApiError("Unable to reach MyQ: offline")
        return self._batches.pop(0)

    def open_device(self, device: MyQDevice) -> bool:
        self.commands.append(("open", device))
        return True

    def close_device(self, device: MyQDevice) -> bool:
        self.commands.append(("close", device))
        return True


class ConfirmationRaceTests(unittest.TestCase):
    """GQ-03: the command uses the door re-fetched by account ID and serial after confirmation."""

    def operate(
        self,
        client: SequencedClient,
        action: str,
        config: str = '{"account":"Demo Home","devices":["Garage Door"]}',
    ) -> int:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "targets.json"
            path.write_text(config, encoding="utf-8")
            with (
                patch("gatectl.cli._client", return_value=client),
                patch("gatectl.cli._save_observation"),
                patch("gatectl.cli.sys.stdin.isatty", return_value=True),
                patch("builtins.input", return_value=action),
                patch("builtins.print"),
            ):
                return _operate("Garage Door", action, False, 0, path)

    def test_state_change_while_confirming_sends_nothing(self) -> None:
        client = SequencedClient((door("closed"),), (door("opening"),))
        with self.assertRaisesRegex(ValueError, "changed while waiting for confirmation"):
            self.operate(client, "open")
        self.assertEqual(client.commands, [])

    def test_rename_while_confirming_sends_nothing(self) -> None:
        client = SequencedClient((door("closed"),), (door("closed", name="Shed"),))
        with self.assertRaisesRegex(ValueError, "changed while waiting for confirmation"):
            self.operate(client, "open")
        self.assertEqual(client.commands, [])

    def test_missing_or_duplicated_serial_on_refetch_sends_nothing(self) -> None:
        for refetched in ((), (door("closed"), door("closed", name="Other"))):
            with self.subTest(count=len(refetched)):
                client = SequencedClient((door("closed"),), refetched)
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    self.operate(client, "open")
                self.assertEqual(client.commands, [])

    def test_failed_refetch_sends_nothing(self) -> None:
        client = SequencedClient((door("closed"),))
        with self.assertRaises(MyQApiError):
            self.operate(client, "open")
        self.assertEqual(client.commands, [])

    def test_unchanged_door_is_commanded_using_the_refetched_object(self) -> None:
        refetched = door("closed")
        client = SequencedClient((door("closed"),), (refetched,))
        self.assertEqual(self.operate(client, "open"), 0)
        self.assertEqual(client.commands, [("open", refetched)])
        self.assertIs(client.commands[0][1], refetched)
        self.assertEqual(client.fetches[1], (MyQAccount("account-1", "Demo Home"),))

    def test_unknown_outcome_reports_live_state_and_is_not_repeated(self) -> None:
        class UncertainClient(SequencedClient):
            def open_device(self, device: MyQDevice) -> bool:
                self.commands.append(("open", device))
                raise MyQCommandOutcomeUnknownError("timed out; it was not repeated")

        client = UncertainClient((door("closed"),), (door("closed"),), (door("opening"),))
        printed: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "targets.json"
            path.write_text('{"account":"Demo Home","devices":["Garage Door"]}', encoding="utf-8")
            with (
                patch("gatectl.cli._client", return_value=client),
                patch("gatectl.cli._save_observation"),
                patch(
                    "builtins.print",
                    side_effect=lambda *args, **_: printed.append(" ".join(map(str, args))),
                ),
            ):
                with self.assertRaises(MyQCommandOutcomeUnknownError):
                    _operate("Garage Door", "open", True, 30, path)
        self.assertEqual(len(client.commands), 1)
        self.assertEqual(len(client.fetches), 3)
        self.assertTrue(any("state=opening" in line for line in printed), printed)

    def test_duplicate_display_names_are_refused(self) -> None:
        client = SequencedClient((door("closed"), door("closed", serial="door-2")))
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.operate(client, "open")
        self.assertEqual(client.commands, [])

    def test_pinned_serial_must_match(self) -> None:
        config = '{"account":"Demo Home","devices":[{"name":"Garage Door","serial":"door-9"}]}'
        client = SequencedClient((door("closed"),))
        with self.assertRaisesRegex(ValueError, "serial"):
            self.operate(client, "open", config)
        self.assertEqual(client.commands, [])

    def test_pinned_serial_selects_the_right_door_among_duplicates(self) -> None:
        config = '{"account":"Demo Home","devices":[{"name":"Garage Door","serial":"door-2"}]}'
        wanted = door("closed", serial="door-2")
        client = SequencedClient((door("closed"), wanted), (door("closed"), wanted))
        self.assertEqual(self.operate(client, "open", config), 0)
        self.assertEqual([device.serial_number for _, device in client.commands], ["door-2"])

    def test_pinned_account_id_must_match(self) -> None:
        config = '{"account":"Demo Home","account_id":"account-9","devices":["Garage Door"]}'
        client = SequencedClient((door("closed"),))
        with self.assertRaisesRegex(ValueError, "account"):
            self.operate(client, "open", config)
        self.assertEqual(client.commands, [])


class _BodyHandler(BaseHTTPRequestHandler):
    size = 0
    status = 200

    def do_GET(self) -> None:
        self.send_response(type(self).status)
        self.send_header("Content-Length", str(type(self).size))
        self.end_headers()
        self.wfile.write(b"x" * type(self).size)

    def log_message(self, format: str, *args: object) -> None:
        return


class BoundedReadTests(unittest.TestCase):
    """GQ-04: response bodies are read with an upper bound."""

    def fetch(self, size: int, status: int = 200, limit: int = 1024) -> HttpResponse:
        _BodyHandler.size = size
        _BodyHandler.status = status
        server = ThreadingHTTPServer(("127.0.0.1", 0), _BodyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            return HttpSession(timeout=2, max_body_bytes=limit).request(
                "GET", f"http://127.0.0.1:{server.server_port}/"
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_body_at_the_limit_is_read(self) -> None:
        self.assertEqual(len(self.fetch(1024).body), 1024)

    def test_body_over_the_limit_is_rejected(self) -> None:
        with self.assertRaisesRegex(MyQApiError, "too large"):
            self.fetch(1025)

    def test_error_body_over_the_limit_is_rejected(self) -> None:
        with self.assertRaisesRegex(MyQApiError, "too large"):
            self.fetch(1025, status=500)

    def test_reads_only_one_byte_past_the_limit(self) -> None:
        class Recording:
            requested: list[int | None] = []
            headers = HttpResponse("", 200, {}, "").headers

            def geturl(self) -> str:
                return "https://partner-identity.myq-cloud.com/"

            status = 200

            def read(self, amount: int | None = None) -> bytes:
                type(self).requested.append(amount)
                return b"x" * (amount or 10_000_000)

            def close(self) -> None:
                return

        with self.assertRaisesRegex(MyQApiError, "too large"):
            HttpSession._response(Recording(), 1024)  # noqa: SLF001
        self.assertEqual(Recording.requested, [1025])

    def test_default_limit_is_one_mebibyte(self) -> None:
        self.assertEqual(HttpSession().max_body_bytes, 1024 * 1024)


class PrivateStorageTests(unittest.TestCase):
    """GQ-06: private files must be owned by the user, not symlinks, and not readable by others."""

    tokens = OAuthTokens("access-secret", "refresh-secret", 12345.0)

    def test_round_trip_creates_private_directory_and_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private" / "tokens.json"
            save_tokens(self.tokens, path)
            self.assertEqual(load_tokens(path), self.tokens)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_token_file_accessible_to_group_or_others_is_refused(self) -> None:
        for mode in (0o644, 0o640, 0o604, 0o620, 0o602, 0o610, 0o601):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "private" / "tokens.json"
                save_tokens(self.tokens, path)
                os.chmod(path, mode)
                with self.assertRaisesRegex(TokenStoreError, "permissions"):
                    load_tokens(path)

    def test_directory_accessible_to_group_is_refused_for_reads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private" / "tokens.json"
            save_tokens(self.tokens, path)
            os.chmod(path.parent, 0o750)
            with self.assertRaisesRegex(TokenStoreError, "permissions"):
                load_tokens(path)

    def test_symlinked_token_file_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / "private" / "real.json"
            save_tokens(self.tokens, real)
            link = real.parent / "tokens.json"
            link.symlink_to(real)
            with self.assertRaisesRegex(TokenStoreError, "symbolic link"):
                load_tokens(link)

    def test_symlinked_directory_is_refused_for_writes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / "real"
            real.mkdir(mode=0o700)
            link = Path(directory) / "private"
            link.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(TokenStoreError, "symbolic link"):
                save_tokens(self.tokens, link / "tokens.json")
            self.assertEqual(list(real.iterdir()), [])

    def test_files_owned_by_another_user_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private" / "tokens.json"
            save_tokens(self.tokens, path)
            with patch("gatectl.storage.os.getuid", return_value=os.getuid() + 1):
                with self.assertRaisesRegex(TokenStoreError, "owned"):
                    load_tokens(path)
                with self.assertRaisesRegex(TokenStoreError, "owned"):
                    save_tokens(self.tokens, path)


class SecretRedactionTests(unittest.TestCase):
    def test_token_repr_and_str_hide_secrets(self) -> None:
        tokens = OAuthTokens("access-secret", "refresh-secret", 12345.0)
        for text in (repr(tokens), str(tokens), f"{tokens}"):
            self.assertNotIn("access-secret", text)
            self.assertNotIn("refresh-secret", text)

    def test_refresh_failure_does_not_echo_the_refresh_token(self) -> None:
        session = FakeSession(
            [
                HttpResponse(
                    f"{IDENTITY}/connect/token",
                    400,
                    {},
                    '{"error":"invalid_grant","refresh_token":"refresh-secret"}',
                )
            ]
        )
        auth = MyQAuth(session, OAuthTokens("a", "refresh-secret", 0), lambda _: None)  # type: ignore[arg-type]
        with self.assertRaises(MyQAuthenticationError) as raised:
            auth.refresh()
        self.assertNotIn("refresh-secret", str(raised.exception))

    def test_command_errors_do_not_include_the_access_token(self) -> None:
        session = FakeSession([HttpResponse("https://gdo/open", 500, {}, "Bearer access")])
        with self.assertRaises(MyQApiError) as raised:
            MyQClient(session, FakeAuth()).open_device(door("closed"))  # type: ignore[arg-type]
        self.assertNotIn("Bearer", str(raised.exception))


if __name__ == "__main__":
    unittest.main()


def guarded_door(state: str = "closed", **extra: object) -> MyQDevice:
    fields: dict[str, object] = {
        "door_state": state,
        "online": True,
        "is_unattended_open_allowed": True,
        "is_unattended_close_allowed": True,
    }
    fields.update(extra)
    return MyQDevice("account-1", "Demo Home", "door-1", "Garage Door", "garagedoor", None, fields)


class FaultAndVacationGuardTests(unittest.TestCase):
    """GQ-03 completion: fault and vacation checks run on the re-fetched door before any PUT."""

    def command(self, action: str, door: MyQDevice) -> FakeSession:
        session = FakeSession([HttpResponse("https://gdo", 202, {}, "")])
        client = MyQClient(session, FakeAuth())  # type: ignore[arg-type]
        (client.open_device if action == "open" else client.close_device)(door)
        return session

    def assert_refused(self, action: str, door: MyQDevice, pattern: str) -> None:
        session = FakeSession([])
        client = MyQClient(session, FakeAuth())  # type: ignore[arg-type]
        with self.assertRaisesRegex(MyQApiError, pattern):
            (client.open_device if action == "open" else client.close_device)(door)
        self.assertEqual(session.calls, [])

    def test_active_faults_refuse_both_actions(self) -> None:
        self.assert_refused("open", guarded_door("closed", active_fault_codes=["E1"]), "fault")
        self.assert_refused("close", guarded_door("open", active_fault_codes=["E1"]), "fault")

    def test_vacation_mode_refuses_opening_but_allows_closing(self) -> None:
        self.assert_refused("open", guarded_door("closed", in_vacation_mode=True), "vacation")
        self.assertEqual(
            len(self.command("close", guarded_door("open", in_vacation_mode=True)).calls), 1
        )

    def test_malformed_safety_fields_refuse(self) -> None:
        for extra in (
            {"active_fault_codes": "E1"},
            {"active_fault_codes": {"E1": True}},
            {"active_fault_codes": ["E1", 7]},
            {"active_fault_codes": None},
            {"in_vacation_mode": "true"},
            {"in_vacation_mode": 1},
            {"in_vacation_mode": None},
        ):
            with self.subTest(extra=extra):
                self.assert_refused("open", guarded_door("closed", **extra), "could not be read")

    def test_absent_fields_mean_not_reported(self) -> None:
        self.assertEqual(len(self.command("open", guarded_door("closed")).calls), 1)

    def test_well_formed_clear_fields_allow_the_command(self) -> None:
        door = guarded_door("closed", active_fault_codes=[], in_vacation_mode=False)
        self.assertEqual(len(self.command("open", door).calls), 1)

    def test_refetched_door_with_a_new_fault_is_refused_after_confirmation(self) -> None:
        client = SequencedClient(
            (door("closed"),), (guarded_door("closed", active_fault_codes=["E2"]),)
        )
        client.open_device = MyQClient(FakeSession([]), FakeAuth()).open_device  # type: ignore[method-assign,arg-type]
        with self.assertRaisesRegex(MyQApiError, "fault"):
            ConfirmationRaceTests().operate(client, "open")
