# Contributing

## Before opening a pull request

1. Read [`docs/architecture.md`](docs/architecture.md), [`docs/protocol.md`](docs/protocol.md), and the relevant ADRs.
2. Keep changes in the narrowest module. Domain code must not import adapters, HTTP, or storage implementations.
3. Add tests for success, malformed input, retries, conflicts, deletion/replay, and the relevant provider capability boundary.
4. Validate contracts and OpenAPI locally:

   ```sh
   ./scripts/validate-contracts.sh
   ./scripts/openapi.sh lint
   swift test --parallel
   ```

5. Do not commit `.build`, credentials, tokens, provider exports, or generated documentation unless the change explicitly updates a checked-in artifact.

## Code and API rules

- Use Swift 6 strict concurrency where the package target enables it. Public values crossing actors/tasks must be `Sendable`.
- Treat provider IDs, cursors, positions, ETags, and revisions as opaque strings.
- Never use names or fuzzy matching to infer identity. Persist explicit mappings.
- Never resolve conflicts using wall-clock ordering or last-write-wins.
- Preserve field-loss and transformation warnings; do not silently drop values.
- Keep authentication/account authorization above provider translation and below route handlers; never put tokens in URLs or logs.
- Update JSON Schema, OpenAPI, examples, and `docs/protocol.md` together when the wire contract changes.

## Commit messages

Use Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `build:`, `ci:`). Explain compatibility, migration, and security consequences in the body when applicable.
