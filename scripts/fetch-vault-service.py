#!/usr/bin/env python3
"""Fetch or verify the exact, frozen AgentSwap XPC vault service (public data only)."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile


BUNDLE = "AgentSwapVaultService.xpc"
EXECUTABLE = "AgentSwapVaultService"
IDENTIFIER = "net.mercen.agentswap.vault"
FILES = {"Contents/Info.plist", f"Contents/MacOS/{EXECUTABLE}", "Contents/_CodeSignature/CodeResources"}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_FILE = 32 * 1024 * 1024
ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def command(arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True)
    if result.returncode:
        message = f"public verification failed: {Path(arguments[0]).name}"
        # These operations inspect public code only. Keep bounded diagnostics for
        # packaging failures without turning this into a generic secret logger.
        public = ((str(arguments[0]) == "/usr/bin/codesign" and
                   ("--verify" in arguments or "--display" in arguments) and
                   "--sign" not in arguments and "-s" not in arguments) or
                  str(arguments[0]) == "/usr/bin/lipo" and "-archs" in arguments or
                  str(arguments[0]) == "/usr/bin/xcrun" and "vtool" in arguments)
        if public:
            detail = result.stderr[:8192].decode("utf-8", errors="replace")
            detail = "".join(char for char in detail if char.isprintable() or char in "\n\t").strip()[:2048]
            if detail:
                message += ": " + detail
        raise ValueError(message)
    return result


def regular_bytes(path, maximum):
    require(path.is_file() and not path.is_symlink(), "expected a regular file")
    require(path.stat().st_size <= maximum, "file exceeds its size limit")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, "file exceeds its size limit")
    return data


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON keys are forbidden")
        result[key] = value
    return result


def load_manifest(path, certificate):
    pin = json.loads(regular_bytes(path, 1024 * 1024), object_pairs_hook=unique_keys)
    require(isinstance(pin, dict) and type(pin.get("schemaVersion")) is int and pin["schemaVersion"] == 1 and type(pin.get("protocolVersion")) is int and pin["protocolVersion"] == 1, "unsupported vault artifact schema or protocol")
    require(pin.get("bundleName") == BUNDLE and pin.get("executable") == EXECUTABLE and pin.get("bundleIdentifier") == IDENTIFIER, "unexpected vault service identity")
    require(isinstance(pin.get("sourceCommit"), str) and re.fullmatch(r"[0-9a-f]{40}", pin["sourceCommit"]), "invalid source commit")
    require(isinstance(pin.get("runID"), str) and re.fullmatch(r"[1-9][0-9]*", pin["runID"]), "invalid build run ID")
    der = regular_bytes(certificate, 64 * 1024)
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    expected_requirement = f'identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'
    require(pin.get("certificateSHA1") == fingerprint and pin.get("designatedRequirement") == expected_requirement, "certificate or designated requirement differs from the source pin")
    require(isinstance(pin.get("executableSHA256"), str) and re.fullmatch(r"[0-9a-f]{64}", pin["executableSHA256"]), "invalid executable digest")
    archive = pin.get("archive")
    require(isinstance(archive, dict), "missing archive pin")
    require(archive.get("name") == f'AgentSwapVaultService-{pin["sourceCommit"]}-universal.zip', "unexpected archive filename")
    require(isinstance(archive.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]), "invalid archive digest")
    require(type(archive.get("size")) is int and 0 < archive["size"] <= MAX_ARCHIVE, "invalid archive size")
    architectures = pin.get("architectures")
    require(isinstance(architectures, dict) and set(architectures) == {"arm64", "x86_64"}, "unexpected architecture inventory")
    for value in architectures.values():
        require(isinstance(value, dict) and isinstance(value.get("cdhash"), str) and re.fullmatch(r"[0-9a-f]{40}", value["cdhash"]), "invalid architecture cdhash")
        require(value.get("minimumOS") == "14.0", "unexpected helper minimum macOS")
    files = pin.get("files")
    require(isinstance(files, dict) and set(files) == FILES, "unexpected bundle file inventory")
    for name, value in files.items():
        require(isinstance(value, dict) and isinstance(value.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]), "invalid file digest")
        require(type(value.get("size")) is int and 0 < value["size"] <= MAX_FILE, "invalid file size")
        require(value.get("mode") == (0o755 if name.startswith("Contents/MacOS/") else 0o644), "unexpected file permissions")
    require(sum(value["size"] for value in files.values()) <= MAX_ARCHIVE, "expanded bundle exceeds its size limit")
    require(pin["executableSHA256"] == files[f"Contents/MacOS/{EXECUTABLE}"]["sha256"], "executable pins disagree")
    return pin


def swift_tokens(source):
    """Read literal pin declarations without executing Swift or accepting comments."""
    tokens = []
    position = 0
    while position < len(source):
        if source[position].isspace():
            position += 1
        elif source.startswith("//", position):
            end = source.find("\n", position)
            position = len(source) if end < 0 else end + 1
        elif source.startswith("/*", position):
            depth = 1
            position += 2
            while depth and position < len(source):
                if source.startswith("/*", position):
                    depth += 1
                    position += 2
                elif source.startswith("*/", position):
                    depth -= 1
                    position += 2
                else:
                    position += 1
            require(depth == 0, "unterminated Swift comment")
        elif source.startswith('"""', position):
            end = source.find('"""', position + 3)
            require(end >= 0, "unterminated Swift multiline string")
            tokens.append(("string", source[position + 3:end]))
            position = end + 3
        elif source[position] == '"':
            start = position + 1
            position = start
            while position < len(source) and source[position] != '"':
                position += 2 if source[position] == "\\" else 1
            require(position < len(source), "unterminated Swift string")
            tokens.append(("string", source[start:position]))
            position += 1
        else:
            word = re.match(r"[A-Za-z_][A-Za-z_0-9]*|[0-9]+", source[position:])
            if word:
                tokens.append(word.group())
                position += len(word.group())
            else:
                tokens.append(source[position])
                position += 1
    return tokens


def swift_enum(tokens, name):
    starts = [index + 3 for index in range(len(tokens) - 2) if tokens[index:index + 3] == ["enum", name, "{"]]
    require(len(starts) == 1, f"one {name} declaration is required")
    start = starts[0]
    depth = 1
    for index in range(start, len(tokens)):
        if tokens[index] == "{":
            depth += 1
        elif tokens[index] == "}":
            depth -= 1
            if depth == 0:
                return tokens[start:index]
    raise ValueError(f"unterminated {name} declaration")


def verify_source_pin(source_path, pin, certificate, wire_source=None):
    # The intentionally narrow grammar fails closed when the initializer changes.
    # It accepts the reviewed literal form only, never a computed/default identity.
    source_path, certificate = Path(source_path), Path(certificate)
    body = swift_enum(swift_tokens(regular_bytes(source_path, 1024 * 1024).decode("utf-8")), "FrozenVaultServiceRelease")
    position = 0

    def consume(*expected):
        nonlocal position
        require(body[position:position + len(expected)] == list(expected), "runtime pin must use the reviewed literal initializer")
        position += len(expected)

    def string_literal(count):
        nonlocal position
        require(position < len(body) and isinstance(body[position], tuple) and body[position][0] == "string", "runtime pin requires literal hash strings")
        value = body[position][1]
        require(re.fullmatch(r"[0-9a-f]{" + str(count) + r"}", value), "runtime pin contains an invalid hash")
        position += 1
        return value

    consume("static", "let", "identity", ":", "VaultServiceIdentity", "?", "=", "try", "?", ".", "init", "(", "executableSHA256", ":")
    executable = string_literal(64)
    consume(",", "cdHashes", ":", "[")
    first = string_literal(40)
    consume(",")
    second = string_literal(40)
    if body[position:position + 1] == [","]:
        position += 1
    consume("]")
    if body[position:position + 1] == [","]:
        position += 1
    consume(")")
    require(position == len(body), "runtime pin contains additional declarations or expressions")
    require(executable == pin["executableSHA256"], "runtime executable SHA-256 differs from the manifest")
    expected_cdhashes = [pin["architectures"][arch]["cdhash"] for arch in ("arm64", "x86_64")]
    require(sorted([first, second]) == sorted(expected_cdhashes), "runtime cdhashes differ from the manifest")

    wire_source = Path(wire_source) if wire_source else ROOT / "AgentSwapCore/Sources/AgentSwapVaultProtocol/VaultProtocol.swift"
    wire = swift_enum(swift_tokens(regular_bytes(wire_source, 1024 * 1024).decode("utf-8")), "AgentSwapVaultWire")
    prefix = ["public", "static", "let", "certificateSHA1", "="]
    declarations = [index for index in range(len(wire) - len(prefix)) if wire[index:index + len(prefix)] == prefix]
    require(len(declarations) == 1, "one wire certificate pin declaration is required")
    index = declarations[0] + len(prefix)
    require(isinstance(wire[index], tuple) and wire[index][0] == "string" and
            (index + 1 == len(wire) or wire[index + 1] == "public"), "wire certificate pin must be a standalone literal")
    fingerprint = hashlib.sha1(regular_bytes(certificate, 64 * 1024)).hexdigest().upper()
    require(wire[index][1] == fingerprint == pin["certificateSHA1"], "wire certificate, public DER and manifest pins differ")


def verify_files(bundle, pin):
    require(bundle.is_dir() and not bundle.is_symlink(), "vault bundle must be a directory")
    seen = set()
    for path in bundle.rglob("*"):
        require(not path.is_symlink(), "symlinks are forbidden in the vault bundle")
        if path.is_dir():
            require(path.relative_to(bundle).as_posix() in {"Contents", "Contents/MacOS", "Contents/_CodeSignature"}, "unexpected bundle directory")
            continue
        name = path.relative_to(bundle).as_posix()
        require(name in FILES, "unexpected bundle file")
        data = regular_bytes(path, MAX_FILE)
        value = pin["files"][name]
        require(len(data) == value["size"] and sha256(data) == value["sha256"], "bundle differs from the frozen file manifest")
        require(stat.S_IMODE(path.stat().st_mode) == value["mode"], "bundle file permissions differ from the manifest")
        seen.add(name)
    require(seen == FILES, "incomplete vault bundle")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(isinstance(info, dict), "unexpected XPC bundle metadata")
    settings = info.get("XPCService")
    # A new XPC security session cannot stand in for the caller's login session.
    # Identity testing also rejects integers, which compare equal to Python bools.
    require(isinstance(settings, dict) and settings.get("JoinExistingSession") is True,
            "XPC service must explicitly join the caller's security session")
    expected = {"CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": EXECUTABLE,
                "CFBundleName": "AgentSwap Vault", "CFBundleShortVersionString": "1.0",
                "CFBundlePackageType": "XPC!", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0", "XPCService": {"ServiceType": "Application", "RunLoopType": "dispatch_main", "JoinExistingSession": True}}
    require(info == expected, "unexpected XPC bundle metadata")


def verify_designated_requirement(actual, expected):
    # codesign prints certificate/CDHash literals in lowercase. Normalize only
    # hex literal spelling: identifiers, operators, and extra clauses stay exact.
    def normalize(value):
        return re.sub(r'H"([0-9a-fA-F]{40})"', lambda match: 'H"' + match.group(1).lower() + '"', value)

    require(normalize(actual) == normalize("designated => " + expected), "embedded helper requirement differs from the pin")


def verify_bundle(bundle, pin, certificate):
    verify_files(bundle, pin)
    requirement = pin["designatedRequirement"]
    # codesign interprets a bare requirement as a filename. A leading '=' selects
    # literal requirement source, independently of the embedded DR display format.
    command(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R", "=" + requirement, bundle])
    actual = command(["/usr/bin/codesign", "--display", "--requirements", "-", bundle]).stdout.decode().strip()
    verify_designated_requirement(actual, requirement)
    entitlements = command(["/usr/bin/codesign", "--display", "--entitlements", ":-", bundle]).stdout
    require(not entitlements.strip() or plistlib.loads(entitlements) == {}, "the vault service must have no entitlements")
    with tempfile.TemporaryDirectory(prefix="agentswap-vault-public-cert-") as temporary:
        prefix = Path(temporary) / "certificate"
        command(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), bundle])
        require((Path(str(prefix) + "0")).read_bytes() == regular_bytes(certificate, 64 * 1024), "helper signing certificate differs from the public DER pin")
    binary = bundle / "Contents/MacOS" / EXECUTABLE
    require(set(command(["/usr/bin/lipo", "-archs", binary]).stdout.decode().split()) == {"arm64", "x86_64"}, "helper must contain exactly arm64 and x86_64")
    for arch in ("arm64", "x86_64"):
        signing = command(["/usr/bin/codesign", "--display", "--verbose=4", "--arch", arch, bundle]).stderr.decode()
        cdhash = re.search(r"^CDHash=([0-9a-f]{40})$", signing, re.MULTILINE)
        flags = re.search(r"\bflags=(0x[0-9a-f]+)", signing)
        require(cdhash is not None and cdhash.group(1) == pin["architectures"][arch]["cdhash"], "helper cdhash changed")
        require(flags is not None and int(flags.group(1), 16) & 0x10002 == 0x10000, "helper must use Hardened Runtime and a certificate signature")
        build = command(["/usr/bin/xcrun", "vtool", "-arch", arch, "-show-build", binary]).stdout.decode()
        minimum = re.search(r"\bminos\s+([0-9.]+)", build)
        require(minimum is not None and minimum.group(1) in {"14.0", "14.0.0"}, "helper requires an unexpected macOS version")


def extract_archive(archive, destination, pin):
    data = regular_bytes(archive, MAX_ARCHIVE)
    require(len(data) == pin["archive"]["size"] and sha256(data) == pin["archive"]["sha256"], "archive differs from the committed pin")
    require(not destination.exists() and not destination.is_symlink(), "extraction destination already exists")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        expected = {BUNDLE + "/" + name for name in FILES}
        require(len(entries) == len(expected) and {entry.filename for entry in entries} == expected, "unexpected or duplicate ZIP entries")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename, "unsafe ZIP path")
            require(not entry.is_dir() and stat.S_ISREG(entry.external_attr >> 16), "ZIP entries must be regular files")
            require(not (entry.flag_bits & 1) and entry.compress_type in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}, "unsupported ZIP encoding")
            name = "/".join(path.parts[1:])
            value = pin["files"][name]
            require(entry.file_size == value["size"] and stat.S_IMODE(entry.external_attr >> 16) == value["mode"], "ZIP member metadata differs from the pin")
        destination.mkdir(mode=0o755)
        for entry in entries:
            name = "/".join(PurePosixPath(entry.filename).parts[1:])
            value = pin["files"][name]
            payload = source.read(entry)
            require(len(payload) == value["size"] and sha256(payload) == value["sha256"], "ZIP member content differs from the pin")
            target = destination / name
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(payload)
            target.chmod(value["mode"])


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == "https", "non-HTTPS redirect refused")
        return super().redirect_request(request, fp, code, message, headers, newurl)


def download(pin, destination):
    url = pin["archive"].get("url", "")
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == "https" and parsed.netloc == "github.com" and not parsed.query and not parsed.fragment, "a public GitHub release asset URL is required")
    require(re.fullmatch(r"/mercen-lee/agent-swap/releases/download/[^/]+/" + re.escape(pin["archive"]["name"]), parsed.path), "unexpected public asset URL")
    opener = urllib.request.build_opener(HTTPSRedirects())
    request = urllib.request.Request(url, headers={"User-Agent": "AgentSwap-vault-artifact-verifier/1"})
    with opener.open(request, timeout=60) as response, destination.open("xb") as output:
        total = 0
        while chunk := response.read(64 * 1024):
            total += len(chunk)
            require(total <= pin["archive"]["size"], "download exceeds the pinned archive size")
            output.write(chunk)
    require(total == pin["archive"]["size"], "incomplete vault archive download")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", type=Path, required=True)
    parser.add_argument("--certificate", type=Path, default=ROOT / "scripts/signing/release-certificate.cer")
    targets = parser.add_mutually_exclusive_group(required=True)
    targets.add_argument("--destination", type=Path)
    targets.add_argument("--verify-bundle", type=Path)
    targets.add_argument("--verify-source-pin", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    pin = load_manifest(args.pin, args.certificate)
    if args.verify_source_pin:
        require(args.archive is None, "--archive requires --destination")
        verify_source_pin(args.verify_source_pin, pin, args.certificate)
        print("Frozen vault service: runtime source, wire certificate and manifest pins match.")
        return
    if args.verify_bundle:
        require(args.archive is None, "--archive requires --destination")
        verify_bundle(args.verify_bundle, pin, args.certificate)
    else:
        destination = args.destination
        require(destination.name == BUNDLE and not destination.exists() and not destination.is_symlink(), "a new AgentSwapVaultService.xpc destination is required")
        parent = destination.parent.resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="agentswap-frozen-vault-", dir=parent) as temporary:
            temporary = Path(temporary)
            archive = args.archive
            if archive is None:
                archive = temporary / pin["archive"]["name"]
                download(pin, archive)
            staged = temporary / BUNDLE
            extract_archive(archive, staged, pin)
            verify_bundle(staged, pin, args.certificate)
            # copytree creates the destination exclusively. Never replace an
            # existing service, and verify again after the final copy.
            shutil.copytree(staged, parent / BUNDLE, symlinks=False)
            verify_bundle(parent / BUNDLE, pin, args.certificate)
    print("Frozen vault service: public hash, signature, architecture and file checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Vault artifact verification: {error}", file=sys.stderr)
        sys.exit(1)
