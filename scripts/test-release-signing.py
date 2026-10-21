#!/usr/bin/env python3
"""Exercise release signing with generated identities and disposable keychains."""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile


def run(arguments, **kwargs):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        if Path(arguments[0]).name in ("release-signing", "codesign"):
            print(result.stderr.decode(errors="replace"), end="")
        result.check_returncode()
    return result.stdout


def main():
    root = Path(__file__).resolve().parent.parent
    # Compare metadata internally. Never print the user's keychain list or read
    # any item from those keychains; all keys and app code below are synthetic.
    before = run(["/usr/bin/security", "list-keychains", "-d", "user"])
    directory = Path(tempfile.mkdtemp(prefix="agentswap-signing-fixture-", dir="/tmp"))
    os.chmod(directory, 0o700)
    helper = directory / "release-signing"
    keychains = []
    wrapper_cleanup = None
    try:
        run(["/usr/bin/xcrun", "swiftc", "-suppress-warnings", str(root / "scripts/release-signing.swift"), "-o", str(helper)])
        certificates = []
        for label in ("a", "b"):
            folder = directory / label
            folder.mkdir(mode=0o700)
            config = folder / "openssl.cnf"
            config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=AgentSwap Release Signing
O=AgentSwap Synthetic Fixture
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
            run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509", "-days", "1", "-sha256", "-config", str(config), "-keyout", str(folder / "private.pem"), "-out", str(folder / "certificate.pem")])
            der = folder / "certificate.cer"
            run(["/usr/bin/openssl", "x509", "-in", str(folder / "certificate.pem"), "-outform", "DER", "-out", str(der)])
            password = secrets.token_hex(32)
            run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(folder / "private.pem"), "-in", str(folder / "certificate.pem"), "-out", str(folder / "identity.p12"), "-passout", "stdin"], input=(password + "\n").encode())
            keychain = folder / "release.keychain-db"
            envelope = json.dumps({"p12": base64.b64encode((folder / "identity.p12").read_bytes()).decode(), "password": password}).encode()
            run([str(helper), "create-keychain", str(keychain), str(der)], input=envelope)
            keychains.append(keychain)
            certificates.append((der, keychain))
        # Exercise the actual CI launcher in a tiny fixture checkout. Its pinned
        # certificate is synthetic; no production private key is exported.
        fixture_scripts = directory / "checkout/scripts"
        (fixture_scripts / "signing").mkdir(parents=True)
        for filename in ("prepare-release-signing.py", "release-signing.swift"):
            shutil.copyfile(root / "scripts" / filename, fixture_scripts / filename)
        shutil.copyfile(certificates[1][0], fixture_scripts / "signing/release-certificate.cer")
        github_env = directory / "github-env"
        github_env.touch()
        wrapper_environment = dict(os.environ, GITHUB_ENV=str(github_env))
        wrapper = fixture_scripts / "prepare-release-signing.py"
        wrapper_cleanup = (wrapper, github_env, wrapper_environment)
        import_environment = dict(wrapper_environment,
            AGENTSWAP_SIGNING_P12_BASE64=base64.b64encode((directory / "b/identity.p12").read_bytes()).decode(),
            AGENTSWAP_SIGNING_P12_PASSWORD=password)
        run(["/usr/bin/python3", str(wrapper), "prepare"], env=import_environment)
        wrapper_values = dict(line.split("=", 1) for line in github_env.read_text().splitlines())
        run([str(helper), "preflight", str(certificates[1][0]), wrapper_values["AGENTSWAP_RELEASE_SIGNING_KEYCHAIN"]])
        run(["/usr/bin/python3", str(wrapper), "cleanup"], env=dict(wrapper_environment, **wrapper_values))
        assert not Path(wrapper_values["AGENTSWAP_RELEASE_SIGNING_DIRECTORY"]).exists(), "The CI signing directory was not removed."
        # Repeated cleanup is safe, including after a failed preparation.
        run(["/usr/bin/python3", str(wrapper), "cleanup"], env=dict(wrapper_environment, **wrapper_values))
        assert before == run(["/usr/bin/security", "list-keychains", "-d", "user"]), "Signing preparation changed the search list."
        requirements = []
        applications = []
        for label, certificate_index, return_value in (("v1", 0, 1), ("v2", 0, 2), ("wrong-signer", 1, 3)):
            der, keychain = certificates[certificate_index]
            fingerprint = run([str(helper), "preflight", str(der), str(keychain)]).decode().strip()
            assert fingerprint == hashlib.sha1(der.read_bytes()).hexdigest().upper()
            app = directory / f"{label}.app"
            executable = app / "Contents/MacOS/AgentSwap"
            executable.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "net.mercen.agentswap", "CFBundleExecutable": "AgentSwap", "CFBundleVersion": str(return_value), "CFBundlePackageType": "APPL"}))
            run(["/usr/bin/xcrun", "clang", "-x", "c", "-o", str(executable), "-"], input=f"int main(void) {{ return {return_value}; }}".encode())
            requirement = f'=designated => identifier "net.mercen.agentswap" and certificate leaf = H"{fingerprint}"'
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", fingerprint, "--keychain", str(keychain), "--identifier", "net.mercen.agentswap", "--requirements", requirement, "--timestamp=none", str(app)])
            run([str(helper), "verify", str(app), str(der)])
            requirements.append(run(["/usr/bin/codesign", "--display", "--requirements", "-", str(app)]))
            applications.append(app)
        assert requirements[0] == requirements[1], "Consecutive releases changed their designated requirement."
        # A valid signature from a different key with the same common name is
        # insufficient. Ad-hoc signatures must also be rejected.
        rejected = subprocess.run([str(helper), "verify", str(applications[2]), str(certificates[0][0])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert rejected.returncode != 0, "A different signing certificate was accepted."
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(applications[0])])
        rejected = subprocess.run([str(helper), "verify", str(applications[0]), str(certificates[0][0])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert rejected.returncode != 0, "An ad-hoc release was accepted."
        print("Release signing fixture passed: stdin import, CI preparation/cleanup, stable requirement across code changes, wrong-certificate/ad-hoc rejection, unchanged keychain search list.")
    finally:
        if wrapper_cleanup is not None:
            wrapper, github_env, wrapper_environment = wrapper_cleanup
            wrapper_values = dict(line.split("=", 1) for line in github_env.read_text().splitlines())
            subprocess.run(["/usr/bin/python3", str(wrapper), "cleanup"], env=dict(wrapper_environment, **wrapper_values), check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for keychain in keychains:
            subprocess.run([str(helper), "delete-keychain", str(keychain)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(directory)
        assert before == run(["/usr/bin/security", "list-keychains", "-d", "user"]), "Signing cleanup changed the search list."


main()
