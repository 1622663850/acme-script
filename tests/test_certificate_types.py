#!/usr/bin/env python3
"""Offline regression tests for certificate selection and export isolation."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

from test_menu import extract_function, SOURCE


class CertificateTypeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        names = (
            "select_key_type", "valid_cert_domain", "cert_paths",
            "issue_selected_cert", "install_selected_cert", "revoke_cert",
        )
        cls.functions = "\n".join(extract_function(cls.source, n) for n in names)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="acme-cert-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.acme = self.home / ".acme.sh"
        self.acme.mkdir()
        self.export = self.home / "export"
        self.export.mkdir()
        self.log = self.home / "args.log"
        (self.acme / "acme.sh").write_text(
            """#!/bin/bash
printf '%s\\n' '---' "$@" >> "$CALL_LOG"
case "$1" in
    --issue) exit "${ISSUE_STATUS:-0}" ;;
    --install-cert)
        [[ "${INSTALL_STATUS:-0}" == 0 ]] || exit "$INSTALL_STATUS"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key-file) key="$2"; shift ;;
                --fullchain-file) cert="$2"; shift ;;
            esac
            shift
        done
        printf 'new-key' > "$key"
        printf 'new-cert' > "$cert"
        ;;
    --revoke) exit "${REVOKE_STATUS:-0}" ;;
    --remove) exit "${REMOVE_STATUS:-0}" ;;
esac
""".replace("\\${", "${"), encoding="utf-8")

    def run_bash(self, body, inputs="", **extra_env):
        env = dict(os.environ, HOME=str(self.home), CALL_LOG=str(self.log),
                   TEST_EXPORT=str(self.export), LC_ALL="C", **extra_env)
        script = "\n".join([
            "set -u",
            "red(){ printf '%s\\n' \"$*\"; }",
            "yellow(){ printf '%s\\n' \"$*\"; }",
            "green(){ printf '%s\\n' \"$*\"; }",
            "ensure_acme(){ :; }",
            self.functions.replace("cert_paths() {", "cert_paths_impl() {"),
            'cert_paths(){ cert_paths_impl "$1" "$TEST_EXPORT"; }',
            'checktls(){ [[ -s "$CERT_KEY_FILE" && -s "$CERT_FULLCHAIN_FILE" ]] || return 1; echo INSTALLED; }',
            body,
        ])
        return subprocess.run(["bash", "-c", script], input=inputs, text=True,
                              capture_output=True, env=env, timeout=15)

    def calls(self):
        if not self.log.exists():
            return []
        return [x.splitlines() for x in self.log.read_text().split("---\n") if x]

    def make_slot(self, domain="example.com", ecc=False, bits=None):
        slot = self.acme / (domain + ("_ecc" if ecc else ""))
        slot.mkdir()
        (slot / (domain + ".conf")).write_text(
            "Le_Keylength='" + ("ec-256" if ecc else str(bits or 2048)) + "'\n")
        if bits:
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:" + str(bits),
                 "-nodes", "-days", "1", "-subj", "/CN=example.com",
                 "-keyout", str(slot / (domain + ".key")),
                 "-out", str(slot / "fullchain.cer")],
                check=True, capture_output=True, timeout=15)
        else:
            (slot / (domain + ".key")).write_text("key")
            (slot / "fullchain.cer").write_text("cert")
        (slot / (domain + ".cer")).write_bytes((slot / "fullchain.cer").read_bytes())
        return slot

    def test_issue_selects_each_key_length(self):
        for choice, expected in [("", "ec-256"), ("1", "ec-256"), ("2", "2048"), ("3", "4096")]:
            with self.subTest(choice=choice):
                self.log.unlink(missing_ok=True)
                result = self.run_bash(
                    'select_key_type && issue_selected_cert example.com --dns dns_cf -d example.com',
                    choice + "\n")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), [["--issue", "--dns", "dns_cf",
                                                "-d", "example.com", "-k", expected]])

    def test_invalid_or_cancelled_selection_does_not_issue(self):
        for inputs in ["9\n", ""]:
            result = self.run_bash(
                'select_key_type && issue_selected_cert example.com -d example.com', inputs)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])

    def test_existing_rsa_key_size_change_forces_only_selected_certificate(self):
        self.make_slot()
        result = self.run_bash(
            'select_key_type && issue_selected_cert example.com -d example.com', "3\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["--issue", "-d", "example.com", "-k", "4096", "--force"]])

    def test_rsa_export_has_no_ecc_flag_and_preserves_legacy_files(self):
        self.make_slot(bits=2048)
        legacy = self.export / "cert.crt"
        legacy.write_text("old ECC")
        result = self.run_bash('select_key_type && install_selected_cert example.com', "2\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = self.calls()[0]
        self.assertEqual(call[:3], ["--install-cert", "-d", "example.com"])
        self.assertNotIn("--ecc", call)
        self.assertEqual(call[-2:], ["--keylength", "2048"])
        path = self.export / "certs" / "example.com" / "rsa"
        self.assertEqual((path / "cert.crt").read_text(), "new-cert")
        self.assertEqual((path / "private.key").stat().st_mode & 0o777, 0o600)
        self.assertEqual(legacy.read_text(), "old ECC")

    def test_ecc_preserves_existing_output_paths(self):
        self.make_slot(ecc=True)
        result = self.run_bash('select_key_type && install_selected_cert example.com', "1\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--ecc", self.calls()[0])
        self.assertEqual((self.export / "cert.crt").read_text(), "new-cert")

    def test_missing_rsa_does_not_fall_back_to_ecc(self):
        self.make_slot(ecc=True)
        result = self.run_bash('select_key_type && install_selected_cert example.com', "2\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rsa_wrong_length_does_not_overwrite_export(self):
        self.make_slot(bits=2048)
        result = self.run_bash('select_key_type && install_selected_cert example.com', "3\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.export / "certs").exists())

    def test_failed_issue_does_not_install_old_certificate(self):
        result = self.run_bash(
            'select_key_type && issue_selected_cert example.com -d example.com && install_selected_cert example.com',
            "2\n", ISSUE_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertNotIn("INSTALLED", result.stdout)

    def test_failed_install_does_not_report_success(self):
        self.make_slot(ecc=True)
        result = self.run_bash('select_key_type && install_selected_cert example.com',
                               "1\n", INSTALL_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("INSTALLED", result.stdout)

    def test_wildcard_rsa_has_separate_paths(self):
        result = self.run_bash(
            'select_key_type && cert_paths "*.example.com" && printf "%s\\n" "$CERT_KEY_FILE"',
            "2\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(str(self.export / "certs/example.com/wildcard/rsa/private.key"), result.stdout)
        self.assertNotEqual(self.run_bash('select_key_type && cert_paths "../outside"', "2\n").returncode, 0)

    def test_revoke_only_selected_family(self):
        rsa = self.make_slot()
        ecc = self.make_slot(ecc=True)
        legacy = self.export / "cert.crt"
        legacy.write_text("unrelated certificate")
        result = self.run_bash("revoke_cert", "example.com\n2\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(rsa.exists())
        self.assertTrue(ecc.exists())
        self.assertEqual(legacy.read_text(), "unrelated certificate")
        self.assertEqual(self.calls()[1:], [
            ["--revoke", "-d", "example.com", "--keylength", "2048"],
            ["--remove", "-d", "example.com", "--keylength", "2048"],
        ])

    def test_failed_revoke_preserves_certificate_and_renewal(self):
        rsa = self.make_slot()
        result = self.run_bash("revoke_cert", "example.com\n2\n", REVOKE_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(rsa.exists())
        self.assertEqual(len(self.calls()), 2)


if __name__ == "__main__":
    unittest.main()
