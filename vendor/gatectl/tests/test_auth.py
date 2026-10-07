from __future__ import annotations

import time
import unittest
from dataclasses import dataclass
from typing import Mapping
from unittest.mock import patch

from gatectl.auth import MyQAuth, MyQLoginSession, require_app_check_debug_token
from gatectl.constants import APP_CHECK_DEBUG_TOKEN_ENV, MFA_METHOD_EMAIL
from gatectl.errors import MyQApiError
from gatectl.http import HttpResponse
from gatectl.models import OAuthTokens

# A fabricated value in the debug-token shape; the real one lives only in ignored local configuration.
FAKE_DEBUG_TOKEN = "00000000-1111-4222-8333-444444444444"


@dataclass(frozen=True)
class RecordedCall:
    method: str
    url: str
    kwargs: Mapping[str, object]


class FakeSession:
    def __init__(self, responses: list[HttpResponse]) -> None:
        self.responses = responses
        self.calls: list[RecordedCall] = []

    def request(self, method: str, url: str, **kwargs: object) -> HttpResponse:
        self.calls.append(RecordedCall(method, url, kwargs))
        if not self.responses:
            raise AssertionError(f"Unexpected request: {method} {url}")
        return self.responses.pop(0)


LOGIN_HTML = """
<form method="post" action="/Account/Login?returnUrl=auth">
  <input type="hidden" name="__RequestVerificationToken" value="csrf-login">
  <input type="email" name="Email">
  <input type="password" name="Password">
</form>
"""

MFA_HTML = """
<form method="post" action="/AccountMfa/VerifyOtp?returnUrl=auth">
  <input type="hidden" name="__RequestVerificationToken" value="csrf-mfa">
  <input type="hidden" name="SelectedMfaMethod" value="Email">
  <input type="number" id="login_otp_input" name="Otp">
</form>
"""


class AppCheckConfigurationTests(unittest.TestCase):
    def test_missing_debug_token_refuses_before_any_request(self) -> None:
        session = FakeSession([])
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(MyQApiError) as raised:
                MyQLoginSession(session).start("driver@example.com", "secret", MFA_METHOD_EMAIL)  # type: ignore[arg-type]
        self.assertIn(APP_CHECK_DEBUG_TOKEN_ENV, str(raised.exception))
        self.assertEqual(session.calls, [])

    def test_malformed_debug_token_is_refused_without_echoing_it(self) -> None:
        for value in (
            "",
            "   ",
            "not-a-token",
            "$(MYQ_APP_CHECK_DEBUG_TOKEN)",
            FAKE_DEBUG_TOKEN + "0",
        ):
            with (
                self.subTest(value=value),
                patch.dict("os.environ", {APP_CHECK_DEBUG_TOKEN_ENV: value}, clear=True),
            ):
                with self.assertRaises(MyQApiError) as raised:
                    require_app_check_debug_token()
                if value.strip():
                    self.assertNotIn(value, str(raised.exception))

    def test_configured_debug_token_is_returned_trimmed(self) -> None:
        with patch.dict(
            "os.environ", {APP_CHECK_DEBUG_TOKEN_ENV: f" {FAKE_DEBUG_TOKEN}\n"}, clear=True
        ):
            self.assertEqual(require_app_check_debug_token(), FAKE_DEBUG_TOKEN)


@patch.dict("os.environ", {APP_CHECK_DEBUG_TOKEN_ENV: FAKE_DEBUG_TOKEN})
class LoginTests(unittest.TestCase):
    def test_mfa_login_exchanges_code_without_storing_password(self) -> None:
        session = FakeSession(
            [
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/connect/authorize",
                    302,
                    {"Location": "/Account/Login"},
                    "",
                ),
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/Account/Login", 200, {}, LOGIN_HTML
                ),
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/Account/Login",
                    302,
                    {"Location": "/AccountMfa/VerifyOtp"},
                    "",
                ),
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/AccountMfa/VerifyOtp", 200, {}, MFA_HTML
                ),
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/AccountMfa/VerifyOtp",
                    302,
                    {"Location": "com.myqops://android?code=fresh-code"},
                    "",
                ),
                HttpResponse("https://firebase/appcheck", 200, {}, '{"token":"app-check"}'),
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/connect/token",
                    200,
                    {},
                    '{"access_token":"access","refresh_token":"refresh","expires_in":3600}',
                ),
            ]
        )
        login = MyQLoginSession(session)  # type: ignore[arg-type]

        self.assertIsNone(login.start("driver@example.com", "secret", MFA_METHOD_EMAIL))
        tokens = login.submit_mfa("123456")

        self.assertEqual(tokens.access_token, "access")
        self.assertEqual(tokens.refresh_token, "refresh")
        self.assertGreater(tokens.expires_at, time.time() + 3500)
        login_post = session.calls[2]
        self.assertEqual(login_post.kwargs["data"]["Email"], "driver@example.com")  # type: ignore[index]
        self.assertEqual(login_post.kwargs["data"]["Password"], "secret")  # type: ignore[index]
        token_post = session.calls[-1]
        self.assertEqual(token_post.kwargs["headers"]["Firebase-AppCheck-Token"], "app-check")  # type: ignore[index]
        app_check_post = session.calls[-2]
        self.assertEqual(app_check_post.kwargs["json_body"], {"debugToken": FAKE_DEBUG_TOKEN})  # type: ignore[index]

    def test_expired_token_refreshes_and_persists_rotation(self) -> None:
        session = FakeSession(
            [
                HttpResponse(
                    "https://partner-identity.myq-cloud.com/connect/token",
                    200,
                    {},
                    '{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}',
                )
            ]
        )
        persisted: list[OAuthTokens] = []
        auth = MyQAuth(
            session,  # type: ignore[arg-type]
            OAuthTokens("expired", "old-refresh", 0),
            persisted.append,
        )

        self.assertEqual(auth.access_token(), "new-access")
        self.assertEqual(len(persisted), 1)
        self.assertEqual(persisted[0].refresh_token, "new-refresh")


if __name__ == "__main__":
    unittest.main()
