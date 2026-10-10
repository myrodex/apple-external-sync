# OpenAPI and contract tooling

The source of truth is [`openapi/reminders-sync.yaml`](../openapi/reminders-sync.yaml), with reusable Draft 2020-12 schemas in [`schemas/`](../schemas/). Route descriptions reference those schemas; do not duplicate a resource schema in the OpenAPI file just to make a generated client compile.

## Validate

Install Python dependencies in an isolated environment, then run:

```sh
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
./scripts/validate_protocol.sh
```

`validate_protocol.py` resolves local schema references without network access, validates all checked-in examples, and tests key invariants (tombstone retention, completed-task timestamps, and mutation preconditions). `openapi.sh lint` runs Redocly's OpenAPI 3.1 linter. CI runs both checks.

## Bundle for publishing

Use a bundle only for tools that cannot resolve relative references. The bundle is generated output and should not be committed:

```sh
./scripts/openapi.sh bundle openapi/dist/reminders-sync.bundle.yaml
```

## Generate a Swift client (optional)

Client generation is intentionally not part of the Swift package graph. Generate into a scratch or application-owned directory after reviewing the diff:

```sh
./scripts/openapi.sh generate-swift /tmp/reminders-sync-swift-client
```

This uses OpenAPI Generator's `swift6` target and the bundled spec. Generated clients must not own domain models, persistence, credentials, or merge rules; adapt generated transport models at the `SyncContracts` boundary. Do not commit generated output unless a target explicitly adopts it and adds focused tests.

## Updating the contract

1. Update the relevant schema and/or `openapi/reminders-sync.yaml`.
2. Update `docs/protocol.md` and examples when semantics change.
3. Add a regression test in `Tests/test_protocol.py` for every newly enforced invariant.
4. Run schema validation, OpenAPI linting, and Swift tests. Review generated/bundled output for accidental secret or personal-data inclusion.
5. Mention protocol version or migration impact in the commit/PR description. Wire changes that affect existing clients require an explicit compatibility decision.
