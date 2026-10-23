# Vault service security fixture

Run `./scripts/test-vault-service-security.sh` with Xcode selected. The optional
`--generic-only` and `--production-only` flags select one suite. Run Keychain
metadata-auditing suites sequentially so another test's disposable Keychain does
not race the before/after comparison.

The hook creates two disposable self-signed identities in private temporary
Keychains. It never imports the release identity, reads a login-Keychain item,
launches an installed app, accesses a provider's native store, or enables UI.
Passwords/private keys stay in the mode-0700 temporary workspace or stdin and are
deleted after successful teardown. If a Security deletion, process stop,
filesystem removal, or metadata audit fails, all remaining owned cleanup actions
and both metadata audits are still attempted. The hook fails and retains its
private workspace instead of unlinking a possibly registered Keychain database.
It reports that retained path and never restores an old global search/default
list over external changes. Pure filesystem/mock fault tests cover these paths.
Only synthetic helper/parent processes under that workspace
may be stopped. Default-Keychain and search-list metadata must match at cleanup.

## What the suites prove

- `ipc_security.py` and `IPCSecurityFixture.m`: 16 real signed-process cases use
  public macOS 13+ XPC code-requirement APIs. Different parent code hashes with
  the same identifier/certificate succeed. Wrong signer/ad-hoc callers fail;
  unsigned code is rejected either by the kernel (as observed on arm64) or
  by XPC before its anonymous delegate/exported methods (permitted on Intel). Wrong helper identities,
  nonce/version mismatch, and an authenticated helper's death followed by a
  wrong-signer/wrong-hash replacement never deliver a credential payload. The
  replacement broker must actually launch before the old anonymous channel's
  execute attempt. Broker messages contain only a request for an endpoint.
- `production_security.py` compiles the unchanged production protocol, server,
  request processor, SDK backend, and `AppVaultTransport.swift` into signed
  fixtures. `ClientSupport.swift` supplies only unrelated types/cancellation
  declarations; the actual `XPCVaultSessionFactory`, connection session, and
  waiter execute unchanged. The server injects a compiled ephemeral application
  requirement and an isolated Keychain. The identical helper reads/updates exact
  bytes across two differently signed parent generations without UI. All three
  owned services and existing recovery-key grammars are covered. A 128 MiB
  recovery value is written, read back exactly, and deleted through the actual
  SDK backend and direct `Data` RPC transport.

The production suite also requires zero backend calls for an unauthorized caller,
execute before ping, malformed account, unowned service, and wrong helper pin.
Its event log contains only synthetic operation names, service kinds, byte sizes,
and process IDs. It contains no payloads or account values.

The end-to-end fixture directly exercises the production session factory rather
than weakening `VaultServiceIdentity`'s release certificate pin.
`AuthenticatedAppVaultTransport.perform` is covered by Core's injected-session
regressions. These suites do not prove real-user migration approval, an installed
release's frozen-artifact identity, or operation on every supported macOS version
and CPU architecture. Packaging/release validation must verify those separately.

Apple documents endpoint-created connections as non-rediscoverable; listener
exit makes them invalid instead of looking up a replacement named service:
<https://developer.apple.com/documentation/xpc/xpc_connection_create_from_endpoint(_:)>
