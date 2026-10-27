#!/usr/bin/env python3
"""Pure menu contract tests for the vendored acme-script source.

Only the real menu/install_menu function bodies are extracted.  The upstream
script's root/user-agent detection and all installation handlers are replaced
with local stubs, so this file never talks to a server or the local ACME state.
"""

from __future__ import annotations

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "acme_cf_token.sh"


def extract_function(source: str, name: str) -> str:
    match = re.search(r"(?m)^" + re.escape(name) + r"\(\)\s*\{", source)
    if not match:
        raise AssertionError(f"missing {name}() function")
    start = match.start()
    lines = source[start:].splitlines(keepends=True)
    depth = 0
    seen = False
    result: list[str] = []
    for line in lines:
        result.append(line)
        depth += line.count("{") - line.count("}")
        seen = True
        if seen and depth == 0:
            return "".join(result)
    raise AssertionError(f"unterminated {name} function")


class AcmeMenuContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_text = SOURCE.read_text(encoding="utf-8")
        cls.install_menu = extract_function(cls.source_text, "install_menu")
        cls.menu = extract_function(cls.source_text, "menu")

    def test_declares_persistent_menu_contract(self) -> None:
        self.assertIn("# acme-script: persistent-menu-v1", self.source_text.splitlines())

    def run_menu(self, input_text: str, *, install_status: int = 1, install_exit: int = 0) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory(prefix="acme-menu-test-") as temp:
            events = Path(temp) / "events.log"
            script = "\n".join([
                "set -u",
                "GREEN=''; RED=''; YELLOW=''; PLAIN=''",
                "clear(){ :; }",
                "red(){ printf '%s\\n' \"$*\"; }",
                f"EVENT_FILE={events!s}",
                f"INSTALL_STATUS={install_status}",
                f"INSTALL_EXIT={install_exit}",
                "record(){ printf '%s\\n' \"$*\" >>\"$EVENT_FILE\"; }",
                "inst_acme(){ record \"inst:$1\"; [[ $INSTALL_EXIT == 0 ]] || exit \"$INSTALL_EXIT\"; return \"$INSTALL_STATUS\"; }",
                "unst_acme(){ record unst; return 1; }",
                "acme_standalone(){ record standalone; return 1; }",
                "acme_cfapiTLD(){ record cfapi-tld; return 1; }",
                "acme_cfapiNTLD(){ record cfapi-ntld; return 1; }",
                "view_cert(){ record view; return 1; }",
                "revoke_cert(){ record revoke; return 1; }",
                "renew_cert(){ record renew; return 1; }",
                "switch_provider(){ record provider; return 1; }",
                self.install_menu,
                self.menu,
                "menu",
            ])
            env = os.environ.copy()
            env["TERM"] = "dumb"
            result = subprocess.run(
                ["bash", "-c", script],
                input=input_text,
                text=True,
                capture_output=True,
                env=env,
                timeout=10,
            )
            events_value = events.read_text(encoding="utf-8") if events.exists() else ""
            return result, events_value.splitlines()

    def assert_returns_to_menu(self, result: subprocess.CompletedProcess[str], minimum_titles: int = 2) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreaterEqual(result.stdout.count("Acme  证书一键申请脚本"), minimum_titles)

    def test_install_cancel_returns_to_acme_menu_until_main_zero(self) -> None:
        result, events = self.run_menu("1\n0\n\n0\n")
        self.assert_returns_to_menu(result)
        self.assertEqual(events, [])

    def test_direct_and_proxy_failures_return_to_menu_without_retrying_action(self) -> None:
        for mode in ("1", "2"):
            with self.subTest(mode=mode):
                result, events = self.run_menu(f"1\n{mode}\n\n0\n")
                self.assert_returns_to_menu(result)
                self.assertEqual(events, [f"inst:{'direct' if mode == '1' else 'proxy'}"])

    def test_other_actions_return_to_menu_after_nonzero(self) -> None:
        for choice, event in (("2", "unst"), ("3", "standalone"), ("4", "cfapi-tld"), ("5", "cfapi-ntld"), ("6", "view"), ("7", "revoke"), ("8", "renew"), ("9", "provider")):
            with self.subTest(choice=choice):
                result, events = self.run_menu(f"{choice}\n\n0\n")
                self.assert_returns_to_menu(result)
                self.assertEqual(events, [event])

    def test_invalid_main_choice_returns_to_menu_without_action(self) -> None:
        result, events = self.run_menu("99\n\n0\n")
        self.assert_returns_to_menu(result)
        self.assertIn("无效选项", result.stdout + result.stderr)
        self.assertEqual(events, [])

    def test_successful_install_stays_in_menu_and_runs_once(self) -> None:
        result, events = self.run_menu("1\n1\n\n0\n", install_status=0)
        self.assert_returns_to_menu(result)
        self.assertEqual(events, ["inst:direct"])

    def test_action_exit_status_does_not_exit_parent_menu(self) -> None:
        result, events = self.run_menu("1\n1\n\n0\n", install_status=0, install_exit=47)
        self.assert_returns_to_menu(result)
        self.assertEqual(events, ["inst:direct"])

    def test_eof_after_action_exits_cleanly_without_repeating_action(self) -> None:
        result, events = self.run_menu("1\n1\n", install_status=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events, ["inst:direct"])

    def test_main_zero_exits_without_running_any_action(self) -> None:
        result, events = self.run_menu("0\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Acme  证书一键申请脚本"), 1)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
