"""Signed IPC tests of unchanged production session/server/SDK implementations."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import subprocess
import tempfile
import time

from fixture_cleanup import cleanup_fixture, stop_owned_processes

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent
CORE = ROOT / "AgentSwapCore/Sources/AgentSwapCore"
SERVER = ROOT / "AgentSwapCore/Sources/AgentSwapVaultService"
PROTOCOL = ROOT / "AgentSwapCore/Sources/AgentSwapVaultProtocol/VaultProtocol.swift"
PARENT_ID = "net.mercen.agentswap.xpcfixture.parent"
HELPER_ID = "net.mercen.agentswap.vault"


def run(arguments, *, input=None, timeout=90, success=True):
    result = subprocess.run([str(a) for a in arguments], input=input, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if success and result.returncode:
        raise RuntimeError(Path(str(arguments[0])).name + " failed: " + result.stderr.decode(errors="replace")[-6000:])
    return result


def metadata():
    # Metadata only: never read an item from the login/default Keychain.
    return (run(["/usr/bin/security", "list-keychains", "-d", "user"]).stdout,
            run(["/usr/bin/security", "default-keychain", "-d", "user"]).stdout)



def main():
    started = time.monotonic()
    before = metadata()
    source_paths = [PROTOCOL, SERVER / "Info.plist", SERVER / "SystemVaultKeychainBackend.swift", SERVER / "VaultRequestProcessor.swift",
                    SERVER / "VaultXPCService.swift", CORE / "AppVaultTransport.swift",
                    FIXTURES / "ServerMain.swift", FIXTURES / "ClientMain.swift", FIXTURES / "ClientSupport.swift"]
    def source_digest():
        digest = hashlib.sha256()
        for path in source_paths:
            digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes())
        return digest.hexdigest()
    compiled_sources = source_digest()
    directory = Path(tempfile.mkdtemp(prefix="agentswap-production-vault-fixture-", dir="/tmp"))
    directory.chmod(0o700)
    signing = directory / "release-signing"
    keychains = []
    completed = False
    private_keychain = directory / "synthetic-items.keychain-db"
    try:
        run(["/usr/bin/xcrun", "swiftc", "-suppress-warnings", ROOT / "scripts/release-signing.swift", "-o", signing])
        identities = []
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
            run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509", "-days", "1", "-sha256",
                 "-config", config, "-keyout", folder / "private.pem", "-out", folder / "certificate.pem"])
            certificate = folder / "certificate.cer"
            run(["/usr/bin/openssl", "x509", "-in", folder / "certificate.pem", "-outform", "DER", "-out", certificate])
            password = secrets.token_hex(32)
            run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", folder / "private.pem", "-in", folder / "certificate.pem",
                 "-out", folder / "identity.p12", "-passout", "stdin"], input=(password + "\n").encode())
            keychain = folder / "signing.keychain-db"
            keychains.append(keychain)
            envelope = json.dumps({"p12": base64.b64encode((folder / "identity.p12").read_bytes()).decode(), "password": password}).encode()
            run([signing, "create-keychain", keychain, certificate], input=envelope)
            identities.append((hashlib.sha1(certificate.read_bytes()).hexdigest().upper(), keychain))

        def sign(path, identifier, identity=0):
            fingerprint, keychain = identities[identity]
            requirement = f'=designated => identifier "{identifier}" and certificate leaf = H"{fingerprint}"'
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", fingerprint, "--keychain", keychain,
                 "--identifier", identifier, "--requirements", requirement, "--timestamp=none", path])

        def cdhash(path):
            text = run(["/usr/bin/codesign", "--display", "--verbose=4", path]).stderr.decode()
            return next(line.split("=", 1)[1] for line in text.splitlines() if line.startswith("CDHash="))

        modules = directory / "modules"
        modules.mkdir()
        protocol_object = modules / "VaultProtocol.o"
        common = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-suppress-warnings", "-parse-as-library"]
        run(common + ["-emit-module", "-emit-object", "-module-name", "AgentSwapVaultProtocol", PROTOCOL,
                      "-emit-module-path", modules / "AgentSwapVaultProtocol.swiftmodule", "-o", protocol_object])
        events = directory / "sdk-events.jsonl"
        application_requirement = f'identifier "{PARENT_ID}" and certificate leaf = H"{identities[0][0]}"'
        configuration = directory / "FixtureConfiguration.swift"
        configuration.write_text("enum FixtureConfiguration {\n" +
                                 " static let applicationRequirement = " + json.dumps(application_requirement) + "\n" +
                                 " static let keychainPath = " + json.dumps(str(private_keychain)) + "\n" +
                                 " static let keychainPassword = " + json.dumps(secrets.token_hex(32)) + "\n" +
                                 " static let eventPath = " + json.dumps(str(events)) + "\n}\n")
        helper = directory / "AgentSwapVaultService.xpc"
        helper_executable = helper / "Contents/MacOS/AgentSwapVaultService"
        helper_executable.parent.mkdir(parents=True)
        shutil.copyfile(SERVER / "Info.plist", helper / "Contents/Info.plist")
        run(common + ["-I", modules, "-module-name", "AgentSwapVaultServiceSecurityFixture",
                      SERVER / "SystemVaultKeychainBackend.swift", SERVER / "VaultRequestProcessor.swift", SERVER / "VaultXPCService.swift",
                      FIXTURES / "ServerMain.swift", configuration, protocol_object, "-o", helper_executable])
        sign(helper, HELPER_ID)
        helper_hash = cdhash(helper)
        peer_requirement = f'identifier "{HELPER_ID}" and certificate leaf = H"{identities[0][0]}" and cdhash H"{helper_hash}"'
        parent_binaries = []
        for generation in (1, 2):
            executable = directory / ("client-" + str(generation))
            defines = ["-DFIXTURE_PARENT_B"] if generation == 2 else []
            run(common + defines + ["-I", modules, "-module-name", "AgentSwapVaultClientSecurityFixture",
                                    CORE / "AppVaultTransport.swift", FIXTURES / "ClientSupport.swift", FIXTURES / "ClientMain.swift",
                                    protocol_object, "-o", executable])
            parent_binaries.append(executable)

        applications = {}
        for label, identity, generation in (("parent-a", 0, 1), ("parent-b", 0, 2), ("wrong-certificate", 1, 1), ("ad-hoc", None, 1)):
            app = directory / (label + ".app")
            executable = app / "Contents/MacOS/FixtureClient"
            executable.parent.mkdir(parents=True)
            shutil.copyfile(parent_binaries[generation - 1], executable)
            executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": PARENT_ID, "CFBundleExecutable": "FixtureClient",
                                                                   "CFBundleVersion": str(generation), "CFBundlePackageType": "APPL", "LSUIElement": True}))
            nested = app / "Contents/XPCServices/AgentSwapVaultService.xpc"
            nested.parent.mkdir()
            shutil.copytree(helper, nested)
            if identity is None:
                run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", PARENT_ID, app])
            else:
                sign(app, PARENT_ID, identity)
            assert cdhash(nested) == helper_hash, "Parent signing changed the frozen helper."
            applications[label] = (app, executable)
        assert cdhash(applications["parent-a"][0]) != cdhash(applications["parent-b"][0]), "Two parents share a cdhash."

        def rows():
            return [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []

        def startup_rows():
            path = Path(str(events) + ".startup")
            return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

        def case(label, parent, mode, *, rejection=False, expected_backend=None, requirement=peer_requirement,
                 expected_session_match=True):
            initial = len(rows())
            initial_startup = len(startup_rows())
            result = run([applications[parent][1], requirement, mode], timeout=135 if mode == "large" else 20, success=not rejection)
            if rejection:
                assert result.returncode != 0, label + " unexpectedly accepted"
            else:
                outcome = json.loads(result.stdout)
                assert outcome["passed"], label
            delta = rows()[initial:]
            if expected_backend is not None:
                assert len(delta) == expected_backend, (label, "unexpected backend calls", len(delta))
            if not rejection:
                # Session IDs are OS audit-session metadata, never credential/account
                # values. Match the exact helper PID that served this case rather
                # than borrowing an earlier helper's row after a relaunch.
                assert outcome["securitySessionStatus"] == 0 and outcome["securitySessionID"] != 0, label
                observed_startup = startup_rows()
                helpers = {row["helper"] for row in delta}
                if not helpers:
                    helpers = {row["pid"] for row in observed_startup[initial_startup:]
                               if row["stage"] == "security-session"}
                assert helpers, (label, "no helper security-session evidence")
                helper_graphic_access = []
                for helper in helpers:
                    sessions = [row for row in observed_startup if row["stage"] == "security-session" and row["pid"] == helper]
                    assert sessions and sessions[-1]["status"] == 0 and sessions[-1]["securitySessionID"] != 0, label
                    same = sessions[-1]["securitySessionID"] == outcome["securitySessionID"]
                    assert same == expected_session_match, (label, "helper audit session does not satisfy the expected join policy")
                    # AuthSession.h defines sessionHasGraphicAccess as 0x0010.
                    # Record capability as a boolean; do not assume the CI caller
                    # itself belongs to a graphical login session.
                    helper_graphic_access.append(bool(sessions[-1]["securitySessionAttributes"] & 0x0010))
                print(json.dumps({"audit_session_case": label, "helper_matches_parent": expected_session_match,
                                  "session_get_info_succeeded": True,
                                  "parent_has_graphic_access": bool(outcome["securitySessionAttributes"] & 0x0010),
                                  "all_helpers_have_graphic_access": all(helper_graphic_access)}), flush=True)
            print("Production " + label + ": passed (backend calls=" + str(len(delta)) + ")", flush=True)
            return delta

        case("three-service initial write/read", "parent-a", "seed")
        continued = case("changed-parent three-service read/update", "parent-b", "continue")
        assert {row["service"] for row in continued} == {"vault", "recovery", "desktop"}
        for parent in ("wrong-certificate", "ad-hoc"):
            case(parent + " denied before backend", parent, "seed", rejection=True, expected_backend=0)
        case("execute before ping", "parent-a", "no-ping", expected_backend=0)
        case("unowned service", "parent-a", "invalid-service", expected_backend=0)
        case("malformed account", "parent-a", "invalid-account", expected_backend=0)
        case("wrong helper requirement", "parent-a", "seed", rejection=True, expected_backend=0,
             requirement=peer_requirement.replace(identities[0][0], identities[1][0]))
        large = case("128 MiB recovery SDK write/read/delete", "parent-b", "large")
        assert any(row["operation"] == "write" and row["size"] == 128 * 1024 * 1024 for row in large)

        # A signed copy with the sole session policy changed provides a negative
        # control. Complete authentication, then reject an unowned service before
        # the SDK backend: this never tries to decrypt an item owned by the normal
        # helper's different code hash and cannot open an authorization prompt.
        false_app = directory / "separate-session-control.app"
        shutil.copytree(applications["parent-a"][0], false_app)
        false_helper = false_app / "Contents/XPCServices/AgentSwapVaultService.xpc"
        false_info_path = false_helper / "Contents/Info.plist"
        false_info = plistlib.loads(false_info_path.read_bytes())
        false_info["XPCService"]["JoinExistingSession"] = False
        false_info_path.write_bytes(plistlib.dumps(false_info))
        sign(false_helper, HELPER_ID)
        false_requirement = peer_requirement.replace(helper_hash, cdhash(false_helper))
        sign(false_app, PARENT_ID)
        applications["separate-session-control"] = (false_app, false_app / "Contents/MacOS/FixtureClient")
        case("JoinExistingSession=false negative control", "separate-session-control", "invalid-service",
             expected_backend=0, requirement=false_requirement, expected_session_match=False)
        assert source_digest() == compiled_sources, "Production fixture sources changed while the hook was running."
        print(json.dumps({"suite": "Production session/server/SDK", "passed": True, "cases": 10,
                          "joined_audit_sessions_verified": True, "separate_session_negative_control": True,
                          "payload_bytes": 128 * 1024 * 1024, "source_sha256": compiled_sources, "elapsed_seconds": round(time.monotonic() - started, 2)}), flush=True)
        completed = True
    finally:
        if not completed and 'events' in locals():
            startup = Path(str(events) + '.startup')
            try:
                if startup.exists(): print('Production helper startup: ' + startup.read_text().strip(), flush=True)
            except Exception:
                print('Production startup diagnostic unavailable; continuing cleanup.', flush=True)
        def delete_owned_keychain(keychain):
            if keychain.exists():
                if not signing.is_file(): raise RuntimeError('Synthetic signing helper is unavailable')
                result=run([signing, "delete-keychain", keychain], timeout=15, success=False)
                if result.returncode or keychain.exists(): raise RuntimeError('Security did not delete the synthetic Keychain')
        cleanup_fixture(directory=directory,keychains=[private_keychain]+keychains,before_metadata=before,
                        stop_processes=stop_owned_processes,delete_keychain=delete_owned_keychain,
                        metadata=metadata,scope='Production session/server/SDK')


if __name__ == "__main__":
    main()
