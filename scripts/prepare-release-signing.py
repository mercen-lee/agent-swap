#!/usr/bin/env python3
"""Import CI-only release credentials without secret command-line arguments."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def fail(message):
    print(f"Release signing: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    # Remove secrets before starting the compiler or any other subprocess.
    p12 = os.environ.pop("AGENTSWAP_SIGNING_P12_BASE64", "")
    password = os.environ.pop("AGENTSWAP_SIGNING_P12_PASSWORD", "")
    root = Path(__file__).resolve().parent.parent
    # security(1)'s interactive parser receives an ASCII-only absolute keychain
    # path. Avoid runner account names or arbitrary RUNNER_TEMP path characters.
    temporary_root = Path("/private/tmp")
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode == "cleanup":
        directory_value = os.environ.get("AGENTSWAP_RELEASE_SIGNING_DIRECTORY", "")
        if not directory_value:
            return
        directory = Path(directory_value)
        if directory.is_symlink() or directory.parent.resolve() != temporary_root or not directory.name.startswith("agentswap-release-signing-"):
            fail("refusing an unexpected cleanup directory.")
        if not directory.exists():
            return
        if not directory.is_dir():
            fail("the signing cleanup target is not a directory.")
        helper = directory / "release-signing"
        keychain = directory / "release.keychain-db"
        if helper.is_file() and not helper.is_symlink() and keychain.exists():
            subprocess.run([str(helper), "delete-keychain", str(keychain)], check=True)
        shutil.rmtree(directory)
        return
    if mode != "prepare":
        fail("use prepare or cleanup.")
    if not p12 or not password:
        fail("configure AGENTSWAP_SIGNING_P12_BASE64 and AGENTSWAP_SIGNING_P12_PASSWORD repository secrets.")
    if len(p12) > 12 * 1024 * 1024 or len(password) > 4096:
        fail("the signing credentials exceed their input limits.")
    github_env = os.environ.get("GITHUB_ENV", "")
    if not github_env or not Path(github_env).is_file() or Path(github_env).is_symlink():
        fail("GITHUB_ENV must name an existing regular file.")
    directory = Path(tempfile.mkdtemp(prefix="agentswap-release-signing-", dir=temporary_root))
    os.chmod(directory, 0o700)
    helper = directory / "release-signing"
    keychain = directory / "release.keychain-db"
    try:
        values = {
            "AGENTSWAP_RELEASE_SIGNING_KEYCHAIN": str(keychain),
            "AGENTSWAP_RELEASE_SIGNING_HELPER": str(helper),
            "AGENTSWAP_RELEASE_SIGNING_DIRECTORY": str(directory),
        }
        if any("\n" in value or "\r" in value for value in values.values()):
            fail("temporary signing paths cannot contain line breaks.")
        # Publish only public paths early, so the always() cleanup step can also
        # remove a keychain if preparation is interrupted by a cancelled job.
        with open(github_env, "a") as output:
            for name, value in values.items():
                output.write(f"{name}={value}\n")
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-suppress-warnings", str(root / "scripts/release-signing.swift"), "-o", str(helper)], check=True)
        subprocess.run(
            [str(helper), "create-keychain", str(keychain), str(root / "scripts/signing/release-certificate.cer")],
            input=json.dumps({"p12": p12, "password": password}).encode(),
            check=True,
        )
    except BaseException:
        if helper.is_file() and keychain.exists():
            subprocess.run([str(helper), "delete-keychain", str(keychain)], check=False)
        shutil.rmtree(directory, ignore_errors=True)
        raise
    finally:
        p12 = ""
        password = ""


try:
    main()
except (OSError, subprocess.SubprocessError):
    fail("the signing preparation or cleanup operation failed.")
