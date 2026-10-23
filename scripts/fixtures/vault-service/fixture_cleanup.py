"""Owned-resource teardown shared by the signed fixtures; no global restoration."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


class CleanupFailure(RuntimeError):
    def __init__(self, errors, report):
        super().__init__("Synthetic fixture cleanup failed: " + "; ".join(errors))
        self.errors = errors
        self.report = report


def stop_owned_processes(directory):
    prefix = str(Path(directory).resolve()) + "/"

    def active():
        result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,uid=,stat=,comm="],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=True)
        pids = []
        for line in result.stdout.decode().splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) == 4 and int(parts[1]) == os.getuid() and not parts[2].startswith("Z") and str(Path(parts[3]).resolve()).startswith(prefix):
                pids.append(int(parts[0]))
        return pids

    failures = []
    for pid in active():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            failures.append(pid)
    for _ in range(40):
        if not active():
            if failures:
                raise RuntimeError("A synthetic process stop failed.")
            return
        time.sleep(0.05)
    raise RuntimeError("Synthetic fixture processes did not stop.")


def cleanup_fixture(*, directory, keychains, before_metadata, stop_processes,
                    delete_keychain, metadata, scope, remove_tree=shutil.rmtree,
                    emit=print):
    """Try every owned resource and always audit metadata, even after failures.

    On a failed Security deletion or metadata audit, retain the private workspace:
    unlinking a still-registered Keychain database can strand its registration.
    No previous global search/default list is ever written back.
    """
    directory = Path(directory)
    errors = []

    def attempt(label, operation):
        try:
            return operation()
        except Exception as error:
            # Keep diagnostics bounded and exclude subprocess output/arguments.
            errors.append(label + " (" + type(error).__name__ + ")")
            return None

    attempt("stop owned processes", lambda: stop_processes(directory))
    for keychain in dict.fromkeys(map(Path, keychains)):
        attempt("delete owned Keychain " + keychain.name, lambda keychain=keychain: delete_keychain(keychain))

    checked = attempt("audit metadata before directory removal", metadata)
    if checked is not None and checked != before_metadata:
        errors.append("Keychain metadata changed; no global restoration attempted")
    if not errors:
        attempt("remove private fixture directory", lambda: remove_tree(directory))

    # Even directory-removal failure must not bypass the final metadata audit.
    after = attempt("audit final metadata", metadata)
    if after is not None and after != before_metadata and not any("metadata changed" in error for error in errors):
        errors.append("Keychain metadata changed; no global restoration attempted")
    report = {
        "scope": scope,
        "private_fixture_directory_removed": not directory.exists(),
        "keychain_search_list_unchanged": after is not None and after[0] == before_metadata[0],
        "default_keychain_unchanged": after is not None and after[1] == before_metadata[1],
        "cleanup_errors": errors,
    }
    if errors and directory.exists():
        report["preserved_private_fixture_directory"] = str(directory)
    emit(json.dumps(report))
    if errors:
        raise CleanupFailure(errors, report)
    return report
