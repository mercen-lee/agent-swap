"""Teardown failure tests use fake files/registration only; no Security APIs."""
from pathlib import Path
import shutil
import tempfile
import unittest

from fixture_cleanup import CleanupFailure, cleanup_fixture


class FixtureCleanupTests(unittest.TestCase):
    def exercise(self, *, fail_stop=False, fail_delete=False, fail_remove=False,
                 fail_audit=False, changed_metadata=False):
        temporary = tempfile.TemporaryDirectory(prefix="agentswap-vault-cleanup-fault-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        first, second = directory / "first.keychain-db", directory / "second.keychain-db"
        for path in (first, second, directory / "synthetic-private-file"):
            path.write_bytes(b"synthetic fixture only; not a registered Keychain")
        registered = {first, second}  # In-memory registration model only.
        calls, reports = [], []
        before = (b"original search metadata", b"original default metadata")

        def stop(_):
            calls.append("stop")
            if fail_stop:
                raise RuntimeError("injected process-stop failure")

        def delete(path):
            calls.append("delete-" + path.name)
            if fail_delete and path == first:
                raise RuntimeError("injected Security deletion failure")
            registered.remove(path)
            path.unlink()

        def audit():
            calls.append("audit")
            if fail_audit:
                raise OSError("injected metadata failure")
            return (b"external metadata changed", before[1]) if changed_metadata else before

        def remove(path):
            calls.append("remove")
            self.assertFalse(registered, "A registered database must not be unlinked")
            if fail_remove:
                raise OSError("injected filesystem removal failure")
            shutil.rmtree(path)

        options = dict(directory=directory, keychains=[first, second], before_metadata=before,
                       stop_processes=stop, delete_keychain=delete, metadata=audit,
                       remove_tree=remove, emit=reports.append, scope="cleanup fault test")
        return directory, first, second, registered, calls, reports, options

    def test_success_deletes_owned_registrations_before_directory(self):
        directory, _, _, registered, calls, _, options = self.exercise()
        result = cleanup_fixture(**options)
        self.assertFalse(directory.exists())
        self.assertFalse(registered)
        self.assertEqual(calls, ["stop", "delete-first.keychain-db", "delete-second.keychain-db", "audit", "remove", "audit"])
        self.assertEqual(result["cleanup_errors"], [])
        self.assertTrue(result["keychain_search_list_unchanged"])
        self.assertTrue(result["default_keychain_unchanged"])

    def test_process_and_first_delete_failures_still_try_second_and_audits(self):
        directory, first, second, registered, calls, _, options = self.exercise(fail_stop=True, fail_delete=True)
        with self.assertRaises(CleanupFailure) as caught:
            cleanup_fixture(**options)
        self.assertEqual(registered, {first})
        self.assertTrue(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue(directory.exists())
        self.assertNotIn("remove", calls)
        self.assertEqual(calls.count("audit"), 2)
        self.assertEqual(len(caught.exception.errors), 2)
        self.assertEqual(caught.exception.report["preserved_private_fixture_directory"], str(directory))
        self.assertFalse(caught.exception.report["private_fixture_directory_removed"])

    def test_first_delete_failure_preserves_database_and_private_workspace(self):
        directory, first, second, _, calls, _, options = self.exercise(fail_delete=True)
        with self.assertRaises(CleanupFailure):
            cleanup_fixture(**options)
        self.assertTrue(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue((directory / "synthetic-private-file").exists())
        self.assertEqual(calls.count("audit"), 2)
        self.assertNotIn("remove", calls)

    def test_directory_removal_failure_still_audits_afterward(self):
        directory, _, _, registered, calls, _, options = self.exercise(fail_remove=True)
        with self.assertRaises(CleanupFailure) as caught:
            cleanup_fixture(**options)
        self.assertFalse(registered)
        self.assertTrue(directory.exists())
        self.assertEqual(calls[-2:], ["remove", "audit"])
        self.assertTrue(any("remove private" in error for error in caught.exception.errors))

    def test_metadata_failure_does_not_skip_owned_deletions_or_claim_success(self):
        directory, _, _, registered, calls, _, options = self.exercise(fail_audit=True)
        with self.assertRaises(CleanupFailure) as caught:
            cleanup_fixture(**options)
        self.assertFalse(registered)
        self.assertEqual(calls.count("audit"), 2)
        self.assertTrue(directory.exists())
        self.assertFalse(caught.exception.report["keychain_search_list_unchanged"])
        self.assertFalse(caught.exception.report["default_keychain_unchanged"])

    def test_external_metadata_change_is_reported_without_global_restoration(self):
        directory, _, _, registered, calls, _, options = self.exercise(changed_metadata=True)
        with self.assertRaises(CleanupFailure) as caught:
            cleanup_fixture(**options)
        self.assertFalse(registered)
        self.assertTrue(directory.exists())
        self.assertNotIn("remove", calls)
        self.assertFalse(caught.exception.report["keychain_search_list_unchanged"])
        self.assertTrue(caught.exception.report["default_keychain_unchanged"])
        self.assertTrue(any("no global restoration" in error for error in caught.exception.errors))


def main():
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(FixtureCleanupTests))
    if not result.wasSuccessful():
        raise RuntimeError("Fixture cleanup failure tests failed.")


if __name__ == "__main__":
    main()
