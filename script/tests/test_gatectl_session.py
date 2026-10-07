"""Tests for the Phase 2 session wrapper; they use temporary repositories and never run gatectl."""

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gatectl_session as session

APPROVED = "| Owner decision | **pass** |"
UNSIGNED = "| Owner decision | _not yet recorded: pass or fail_ |"


def make_repo(root: Path, decision: str) -> str:
    """Builds a tiny git repo with vendor/gatectl and a review doc, and returns the vendor tree hash."""
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / "vendor/gatectl/src/gatectl").mkdir(parents=True)
    (root / "vendor/gatectl/src/gatectl/__init__.py").write_text("")
    (root / "docs").mkdir()
    (root / "docs/gatectl-security-review.md").write_text(f"# Review\n\n## Approval record\n\n| Field | Value |\n| --- | --- |\n{decision}\n")
    git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.com"]
    subprocess.run([*git, "add", "-A"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "init"], check=True)
    return subprocess.run([*git, "rev-parse", "HEAD:vendor/gatectl"], check=True, capture_output=True, text=True).stdout.strip()


class SessionWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "repo"
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def plan(self, args: list[str], *, tree: str | None = None, decision: str = APPROVED, env: dict[str, str] | None = None):
        actual = make_repo(self.root, decision)
        return session.plan_invocation(
            repo=self.root,
            home=self.home,
            approved_tree=tree or actual,
            session_name="mac",
            gatectl_args=args,
            environ=env or {},
        )

    def test_builds_an_isolated_invocation(self) -> None:
        argv, env = self.plan(["status"])
        private = self.home / ".config/myq-carplay"
        self.assertEqual(argv[1:], ["-m", "gatectl", "status"])
        self.assertEqual(env["PYTHONPATH"], str(self.root / "vendor/gatectl/src"))
        self.assertEqual(env["GATECTL_CONFIG"], str(private / "mac-targets.json"))
        self.assertEqual(env["GATECTL_TOKEN_FILE"], str(private / "mac-tokens.json"))
        self.assertEqual(env["GATECTL_STATE_FILE"], str(private / "mac-state.json"))
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)

    def test_phone_seed_session_uses_its_own_token_file(self) -> None:
        make_repo(self.root, APPROVED)
        tree = subprocess.run(["git", "-C", str(self.root), "rev-parse", "HEAD:vendor/gatectl"], capture_output=True, text=True, check=True).stdout.strip()
        _, env = session.plan_invocation(repo=self.root, home=self.home, approved_tree=tree, session_name="phone-seed", gatectl_args=["status"], environ={})
        self.assertTrue(env["GATECTL_TOKEN_FILE"].endswith("phone-seed-tokens.json"))
        self.assertTrue(env["GATECTL_STATE_FILE"].endswith("phone-seed-state.json"))
        self.assertTrue(env["GATECTL_CONFIG"].endswith("mac-targets.json"))

    def test_refuses_without_an_owner_pass(self) -> None:
        for decision in (UNSIGNED, "| Owner decision | **fail** |", "| Owner decision | pass pending |", ""):
            with self.subTest(decision=decision), tempfile.TemporaryDirectory() as other:
                self.root = Path(other) / "repo"
                with self.assertRaisesRegex(session.SessionRefused, "approval record"):
                    self.plan(["status"], decision=decision)

    def test_refuses_a_different_tree(self) -> None:
        with self.assertRaisesRegex(session.SessionRefused, "tree"):
            self.plan(["status"], tree="0" * 40)

    def test_refuses_local_changes_under_vendor(self) -> None:
        tree = make_repo(self.root, APPROVED)
        (self.root / "vendor/gatectl/src/gatectl/__init__.py").write_text("x = 1\n")
        with self.assertRaisesRegex(session.SessionRefused, "uncommitted"):
            session.plan_invocation(repo=self.root, home=self.home, approved_tree=tree, session_name="mac", gatectl_args=["status"], environ={})

    def test_refuses_untracked_files_under_vendor(self) -> None:
        tree = make_repo(self.root, APPROVED)
        (self.root / "vendor/gatectl/src/gatectl/extra.py").write_text("")
        with self.assertRaisesRegex(session.SessionRefused, "uncommitted"):
            session.plan_invocation(repo=self.root, home=self.home, approved_tree=tree, session_name="mac", gatectl_args=["status"], environ={})

    def test_refuses_yes_in_any_position(self) -> None:
        for args in (["open", "Big", "--yes"], ["close", "--yes", "Big"], ["open", "Big", "-y"], ["open", "--yes=true", "Big"]):
            with self.subTest(args=args), tempfile.TemporaryDirectory() as other:
                self.root = Path(other) / "repo"
                with self.assertRaisesRegex(session.SessionRefused, "--yes"):
                    self.plan(args)

    def test_refuses_password_from_the_environment(self) -> None:
        with self.assertRaisesRegex(session.SessionRefused, "MYQ_PASSWORD"):
            self.plan(["login"], env={"MYQ_PASSWORD": "x"})

    def test_strips_inherited_gatectl_and_python_settings(self) -> None:
        _, env = self.plan(["status"], env={"GATECTL_TOKEN_FILE": "/tmp/other.json", "PYTHONSTARTUP": "/tmp/evil.py", "HOME": "/h", "PATH": "/usr/bin"})
        self.assertNotEqual(env["GATECTL_TOKEN_FILE"], "/tmp/other.json")
        self.assertNotIn("PYTHONSTARTUP", env)
        self.assertEqual(env["PATH"], "/usr/bin")

    def test_refuses_an_unsafe_private_directory(self) -> None:
        private = self.home / ".config/myq-carplay"
        private.parent.mkdir(parents=True)
        real = self.home / "elsewhere"
        real.mkdir()
        private.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(session.SessionRefused, "symbolic link"):
            self.plan(["status"])

    def test_tightens_an_existing_loose_private_directory(self) -> None:
        private = self.home / ".config/myq-carplay"
        private.mkdir(parents=True, mode=0o755)
        os.chmod(private, 0o755)
        self.plan(["status"])
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)

    def test_refuses_unknown_sessions_and_old_python(self) -> None:
        tree = make_repo(self.root, APPROVED)
        with self.assertRaisesRegex(session.SessionRefused, "session"):
            session.plan_invocation(repo=self.root, home=self.home, approved_tree=tree, session_name="widget", gatectl_args=["status"], environ={})
        with self.assertRaisesRegex(session.SessionRefused, "Python 3.11"):
            session.plan_invocation(
                repo=self.root, home=self.home, approved_tree=tree, session_name="mac", gatectl_args=["status"], environ={}, python_version=(3, 10)
            )

    def write_local_config(self, text: str) -> None:
        (self.root / "config").mkdir(exist_ok=True)
        (self.root / "config/MyQ.local.xcconfig").write_text(text)

    def plan_with_config(self, text: str | None, env: dict[str, str] | None = None):
        actual = make_repo(self.root, APPROVED)
        if text is not None:
            self.write_local_config(text)
        return session.plan_invocation(repo=self.root, home=self.home, approved_tree=actual, session_name="mac", gatectl_args=["status"], environ=env or {})

    def test_passes_the_debug_token_from_the_shared_local_config(self) -> None:
        _, env = self.plan_with_config("// Local only\n\nMYQ_APP_CHECK_DEBUG_TOKEN = 00000000-1111-4222-8333-444444444444\n")
        self.assertEqual(env["GATECTL_APP_CHECK_DEBUG_TOKEN"], "00000000-1111-4222-8333-444444444444")

    def test_runs_without_a_debug_token_when_the_config_is_missing_or_blank(self) -> None:
        for text in (None, "", "MYQ_APP_CHECK_DEBUG_TOKEN =\n", "// MYQ_APP_CHECK_DEBUG_TOKEN = 00000000-1111-4222-8333-444444444444\n"):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as other:
                self.root = Path(other) / "repo"
                _, env = self.plan_with_config(text)
                self.assertNotIn("GATECTL_APP_CHECK_DEBUG_TOKEN", env)

    def test_ignores_an_inherited_debug_token(self) -> None:
        _, env = self.plan_with_config(None, env={"GATECTL_APP_CHECK_DEBUG_TOKEN": "inherited"})
        self.assertNotIn("GATECTL_APP_CHECK_DEBUG_TOKEN", env)

    def test_refuses_a_symlinked_local_config(self) -> None:
        make_repo(self.root, APPROVED)
        target = Path(self.temp.name) / "elsewhere.xcconfig"
        target.write_text("MYQ_APP_CHECK_DEBUG_TOKEN = 00000000-1111-4222-8333-444444444444\n")
        (self.root / "config").mkdir()
        (self.root / "config/MyQ.local.xcconfig").symlink_to(target)
        tree = subprocess.run(["git", "-C", str(self.root), "rev-parse", "HEAD:vendor/gatectl"], capture_output=True, text=True, check=True).stdout.strip()
        with self.assertRaisesRegex(session.SessionRefused, "symbolic link"):
            session.plan_invocation(repo=self.root, home=self.home, approved_tree=tree, session_name="mac", gatectl_args=["status"], environ={})

    def test_approved_tree_constant_matches_the_review(self) -> None:
        review = (Path(__file__).resolve().parents[2] / "docs/gatectl-security-review.md").read_text()
        self.assertIn(f"Patched tree | `{session.APPROVED_TREE}`", review)


if __name__ == "__main__":
    unittest.main()
