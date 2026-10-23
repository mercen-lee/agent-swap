#!/usr/bin/env python3
"""Exercise signed XPC peers using disposable identities and isolated storage.

No installed app, login Keychain credential, native session, or security UI is used.
"""
import argparse
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True

FIXTURES = Path(__file__).resolve().parent / "fixtures/vault-service"
sys.path.insert(0, str(FIXTURES))

def load(name):
    spec = importlib.util.spec_from_file_location(name, FIXTURES / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generic-only", action="store_true", help="Run the OS IPC identity and path-swap proof only.")
    parser.add_argument("--production-only", action="store_true", help="Run the actual production server/session fixture only.")
    args = parser.parse_args()
    if args.generic_only and args.production_only:
        parser.error("Choose at most one suite filter.")
    load("cleanup_tests").main()
    if not args.production_only:
        load("ipc_security").main()
    if not args.generic_only:
        load("production_security").main()

if __name__ == "__main__":
    main()
