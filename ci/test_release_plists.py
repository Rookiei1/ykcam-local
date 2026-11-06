"""Offline regression fixtures for codesign's explicit plist output contract."""
from pathlib import Path
import contextlib
import datetime as dt
import io
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import verify_release


class ReleasePlistTests(unittest.TestCase):
    def setUp(self):
        self.entitlements = {
            "application-identifier": "LOCALTEST1.com.example.offline",
            "com.apple.developer.team-identifier": "LOCALTEST1",
            "get-task-allow": False,
        }
        self.xml = plistlib.dumps(self.entitlements, fmt=plistlib.FMT_XML)
        # A synthetic human-readable representation; this is not output captured
        # from the production app, and must never be treated as plist XML.
        self.human_readable = b"[Dict]\n\t[Key] get-task-allow\n\t[Value] [Bool] false\n"

    def test_request_xml_instead_of_default_human_readable_output(self):
        def fake_codesign(*args):
            return self.xml if "--xml" in args else self.human_readable

        with patch.object(verify_release, "command", side_effect=fake_codesign) as run:
            result = verify_release.read_signed_entitlements(Path("Fixture.app"))
        self.assertEqual(result, self.entitlements)
        run.assert_called_once_with("/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", "Fixture.app")

    def test_xml_after_a_diagnostic_prefix(self):
        self.assertEqual(verify_release.read_plist(b"Executable=Fixture.app\n" + self.xml), self.entitlements)

    def test_binary_plist_remains_supported(self):
        data = plistlib.dumps(self.entitlements, fmt=plistlib.FMT_BINARY)
        self.assertEqual(verify_release.read_plist(data), self.entitlements)

    def test_human_readable_output_fails_closed(self):
        with patch.object(verify_release, "command", return_value=self.human_readable):
            with self.assertRaisesRegex(RuntimeError, "refusing upload"):
                verify_release.read_signed_entitlements(Path("Fixture.app"))

    def test_missing_entitlements_fail_closed(self):
        with patch.object(verify_release, "command", return_value=b""):
            with self.assertRaisesRegex(RuntimeError, "refusing upload"):
                verify_release.read_signed_entitlements(Path("Fixture.app"))

    def test_non_dictionary_plist_fails_closed(self):
        with patch.object(verify_release, "command", return_value=plistlib.dumps(["not an entitlement dictionary"])):
            with self.assertRaisesRegex(RuntimeError, "plist dictionary"):
                verify_release.read_signed_entitlements(Path("Fixture.app"))


class ReleaseCertificateExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release certificate fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Fixture.app"
        self.app.mkdir()
        info = {
            "CFBundleIdentifier": verify_release.BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "DTPlatformName": "iphoneos",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1009",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleExecutable": "Fixture",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
        (self.app / "Fixture").write_bytes(b"offline executable fixture")
        (self.app / "embedded.mobileprovision").write_bytes(b"offline profile fixture")
        self.profile_certificate = b"offline leaf certificate fixture"
        self.extracted_certificate = self.profile_certificate
        self.entitlements = {
            "application-identifier": "LOCALTEST1." + verify_release.BUNDLE_ID,
            "com.apple.developer.team-identifier": "LOCALTEST1",
            "get-task-allow": False,
        }
        self.profile = {
            "TeamIdentifier": ["LOCALTEST1"],
            "ApplicationIdentifierPrefix": ["LOCALTEST1"],
            "Platform": ["iOS"],
            "ExpirationDate": dt.datetime.now() + dt.timedelta(days=1),
            "Entitlements": self.entitlements,
            "DeveloperCertificates": [self.profile_certificate],
        }

    def fake_command(self, *args):
        # Model getopt's optional_argument behavior: a separated prefix is a
        # positional code object. Only the = form binds it to this option.
        if "--extract-certificates" in args:
            raise RuntimeError("signer: No such file or directory")
        bound = [arg for arg in args if arg.startswith("--extract-certificates=")]
        if bound:
            self.assertEqual(args, ("/usr/bin/codesign", "--display", bound[0], str(self.app)))
            Path(bound[0].split("=", 1)[1] + "0").write_bytes(self.extracted_certificate)
            return b""
        if args[0] == "/usr/bin/security":
            return plistlib.dumps(self.profile)
        if "--entitlements" in args:
            self.assertIn("--xml", args)
            return plistlib.dumps(self.entitlements)
        if "--verify" in args:
            return b""
        self.fail(f"Unexpected verification command: {args}")

    def verify_fixture(self):
        with patch.object(verify_release, "command", side_effect=self.fake_command), contextlib.redirect_stdout(io.StringIO()):
            verify_release.verify_app(self.app, "LOCALTEST1", "0.1.0", "1009", "Offline fixture")

    def test_old_separated_optional_prefix_is_a_code_path(self):
        with self.assertRaisesRegex(RuntimeError, "signer: No such file"):
            self.fake_command("/usr/bin/codesign", "--display", "--extract-certificates", "signer", str(self.app))

    def test_bound_prefix_extracts_the_profile_certificate(self):
        self.verify_fixture()

    def test_real_certificate_mismatch_still_fails_closed(self):
        self.extracted_certificate = b"different offline leaf certificate fixture"
        with self.assertRaisesRegex(RuntimeError, "signing certificate is not included"):
            self.verify_fixture()


if __name__ == "__main__":
    unittest.main()
