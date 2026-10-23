#!/usr/bin/env python3
"""Synthetic ZIP/pin validation tests. No signing keys, Keychain, or network."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("vault_artifact", ROOT / "scripts/fetch-vault-service.py")
ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARTIFACT)


class ArtifactValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentswap-vault-artifact-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.certificate = self.root / "synthetic-public.cer"
        self.certificate.write_bytes(b"synthetic-public-certificate-no-key")
        self.contents = {
            "Contents/Info.plist": plistlib.dumps({
                "CFBundleIdentifier": ARTIFACT.IDENTIFIER, "CFBundleExecutable": ARTIFACT.EXECUTABLE,
                "CFBundleName": "AgentSwap Vault", "CFBundleShortVersionString": "1.0",
                "CFBundlePackageType": "XPC!", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0",
                "XPCService": {"ServiceType": "Application", "RunLoopType": "dispatch_main"},
            }),
            "Contents/MacOS/AgentSwapVaultService": b"synthetic-executable-bytes-not-signed\0\xff",
            "Contents/_CodeSignature/CodeResources": plistlib.dumps({"synthetic": True}),
        }
        fingerprint = hashlib.sha1(self.certificate.read_bytes()).hexdigest().upper()
        self.pin = {
            "schemaVersion": 1, "protocolVersion": 1, "bundleName": ARTIFACT.BUNDLE,
            "executable": ARTIFACT.EXECUTABLE, "bundleIdentifier": ARTIFACT.IDENTIFIER,
            "sourceCommit": "a" * 40, "runID": "1234", "certificateSHA1": fingerprint,
            "designatedRequirement": f'identifier "{ARTIFACT.IDENTIFIER}" and certificate leaf = H"{fingerprint}"',
            "architectures": {arch: {"cdhash": "b" * 40, "minimumOS": "14.0"} for arch in ("arm64", "x86_64")},
            "files": {name: {"sha256": ARTIFACT.sha256(data), "size": len(data),
                             "mode": 0o755 if name.startswith("Contents/MacOS/") else 0o644}
                      for name, data in self.contents.items()},
            "executableSHA256": ARTIFACT.sha256(self.contents["Contents/MacOS/AgentSwapVaultService"]),
        }
        self.archive = self.root / f'AgentSwapVaultService-{self.pin["sourceCommit"]}-universal.zip'
        self.write_archive()
        self.pin_path = self.root / "pin.json"
        self.write_pin()

    def write_archive(self, extra=None, mode_override=None, name_override=None):
        entries = [(ARTIFACT.BUNDLE + "/" + name, data) for name, data in self.contents.items()]
        if extra:
            entries += extra
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w") as output:
                for name, data in entries:
                    entry = zipfile.ZipInfo(name_override or name)
                    entry.create_system = 3
                    member = name.removeprefix(ARTIFACT.BUNDLE + "/")
                    mode = self.pin["files"].get(member, {}).get("mode", 0o644)
                    entry.external_attr = (mode_override or (stat.S_IFREG | mode)) << 16
                    output.writestr(entry, data)
        self.pin["archive"] = {"name": self.archive.name, "sha256": ARTIFACT.sha256(self.archive.read_bytes()), "size": self.archive.stat().st_size}

    def write_pin(self):
        self.pin_path.write_text(json.dumps(self.pin))

    def load(self):
        self.write_pin()
        return ARTIFACT.load_manifest(self.pin_path, self.certificate)

    def extract(self):
        destination = self.root / ARTIFACT.BUNDLE
        ARTIFACT.extract_archive(self.archive, destination, self.load())
        return destination

    def test_valid_exact_manifest_round_trip(self):
        bundle = self.extract()
        ARTIFACT.verify_files(bundle, self.pin)
        self.assertEqual({name: (bundle / name).read_bytes() for name in self.contents}, self.contents)

    def test_archive_byte_change_rejected_before_extraction(self):
        with self.archive.open("ab") as output:
            output.write(b"unexpected-change")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.extract()
        self.assertFalse((self.root / ARTIFACT.BUNDLE).exists())

    def test_duplicate_members_rejected(self):
        self.write_archive(extra=[(ARTIFACT.BUNDLE + "/Contents/Info.plist", b"duplicate")])
        with self.assertRaisesRegex(ValueError, "duplicate ZIP"):
            self.extract()

    def test_paths_outside_bundle_rejected(self):
        for name in ("../outside", "/absolute", ARTIFACT.BUNDLE + "/Contents/../outside", "other.xpc/Contents/Info.plist", ARTIFACT.BUNDLE + "\\Contents\\Info.plist"):
            with self.subTest(name=name):
                self.write_archive(name_override=name)
                with self.assertRaises(ValueError):
                    self.extract()
                self.assertFalse((self.root / "outside").exists())

    def test_symlink_and_special_file_entries_rejected(self):
        for mode in (stat.S_IFLNK | 0o755, stat.S_IFIFO | 0o644):
            with self.subTest(mode=mode):
                self.write_archive(mode_override=mode)
                with self.assertRaisesRegex(ValueError, "regular files"):
                    self.extract()

    def test_unexpected_files_and_directories_rejected(self):
        self.write_archive(extra=[(ARTIFACT.BUNDLE + "/Contents/Resources/unexpected", b"extra")])
        with self.assertRaises(ValueError):
            self.extract()

    def test_wrong_signer_requirement_protocol_and_architecture_rejected(self):
        original = copy.deepcopy(self.pin)
        cases = {"certificateSHA1": "0" * 40, "designatedRequirement": 'identifier "other"',
                 "protocolVersion": 2, "bundleIdentifier": "other", "architectures": {"arm64": {}}}
        for key, value in cases.items():
            with self.subTest(key=key):
                self.pin = copy.deepcopy(original)
                self.pin[key] = value
                with self.assertRaises(ValueError):
                    self.load()

    def test_duplicate_json_keys_rejected(self):
        self.pin_path.write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaisesRegex(ValueError, "duplicate JSON keys"):
            ARTIFACT.load_manifest(self.pin_path, self.certificate)

    def test_metadata_version_cannot_change_with_a_new_manifest(self):
        info = plistlib.loads(self.contents["Contents/Info.plist"])
        info["XPCService"]["RunLoopType"] = "NSRunLoop"
        self.contents["Contents/Info.plist"] = plistlib.dumps(info)
        self.pin["files"]["Contents/Info.plist"].update(
            sha256=ARTIFACT.sha256(self.contents["Contents/Info.plist"]), size=len(self.contents["Contents/Info.plist"]))
        self.write_archive()
        bundle = self.extract()
        with self.assertRaisesRegex(ValueError, "XPC bundle metadata"):
            ARTIFACT.verify_files(bundle, self.pin)

    def test_bundle_tamper_and_extra_file_rejected(self):
        bundle = self.extract()
        (bundle / "Contents/Info.plist").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "frozen file manifest"):
            ARTIFACT.verify_files(bundle, self.pin)
        (bundle / "Contents/Info.plist").write_bytes(self.contents["Contents/Info.plist"])
        (bundle / "Contents/unexpected").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "unexpected bundle file"):
            ARTIFACT.verify_files(bundle, self.pin)

    def test_existing_destination_and_symlinks_never_replaced(self):
        destination = self.root / ARTIFACT.BUNDLE
        destination.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "destination already exists"):
            ARTIFACT.extract_archive(self.archive, destination, self.load())
        self.assertTrue(destination.is_symlink())

    def test_unsafe_download_urls_rejected_without_network(self):
        for url in ("http://github.com/anything", "https://example.com/anything",
                    "https://github.com/other/repo/releases/download/v1/test.zip",
                    "https://github.com/mercen-lee/agent-swap/releases/download/v1/test.zip?token=secret"):
            with self.subTest(url=url):
                pin = copy.deepcopy(self.pin)
                pin["archive"]["url"] = url
                with self.assertRaises(ValueError):
                    ARTIFACT.download(pin, self.root / "must-not-download")
                self.assertFalse((self.root / "must-not-download").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
