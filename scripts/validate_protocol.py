#!/usr/bin/env python3
"""Validate the Reminders-first sync JSON Schemas and checked-in examples.

Install test dependencies in a virtual environment with:
    python3 -m venv .venv
    .venv/bin/pip install -r scripts/requirements.txt

The OpenAPI document itself is linted with Redocly by validate_protocol.sh.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urljoin

try:
    from jsonschema import Draft202012Validator, FormatChecker, RefResolver
except ImportError as exc:  # pragma: no cover - exercised only without dev deps
    print(
        "Missing validator dependencies. Run: "
        "python3 -m pip install -r scripts/requirements.txt",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc

ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = ROOT / "schemas"
EXAMPLES = ROOT / "examples"

EXAMPLE_CASES: tuple[tuple[str, str], ...] = (
    ("capabilities.json", "capabilities.schema.json"),
    ("lists-page.json", "list-page"),
    ("tasks-page.json", "task-page"),
    ("changes-page.json", "changes-page"),
    ("mutation-batch.json", "mutation-batch.schema.json"),
    ("mutation-batch-response.json", "mutation-batch-response.schema.json"),
    ("idempotency-mismatch.json", "error.schema.json"),
)


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def schema_store() -> dict[str, object]:
    """Make local filename references resolve without network access."""
    store: dict[str, object] = {}
    for path in SCHEMAS.glob("*.schema.json"):
        schema = load_json(path)
        file_uri = path.as_uri()
        store[file_uri] = schema
        store[path.name] = schema
        store[urljoin(file_uri, path.name)] = schema
    return store


def validator_for(path: Path) -> Draft202012Validator:
    schema = load_json(path)
    resolver = RefResolver(path.as_uri(), schema, store=schema_store())
    return Draft202012Validator(schema, resolver=resolver, format_checker=FormatChecker())


def validate(name: str, instance: object, schema_path: Path) -> None:
    validator = validator_for(schema_path)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if errors:
        joined = "\n".join(
            f"  - {name} at {'/'.join(map(str, error.path)) or '<root>'}: {error.message}"
            for error in errors
        )
        raise ValueError(joined)


def validate_pages() -> None:
    """Validate snapshot/change envelopes from their checked-in schemas."""
    page_cases = (
        ("lists-page.json", "list-page.schema.json", "items", "list.schema.json"),
        ("tasks-page.json", "task-page.schema.json", "items", "task.schema.json"),
        ("changes-page.json", "changes-page.schema.json", "items", "change.schema.json"),
    )
    for example_name, page_schema_name, items_key, item_schema_name in page_cases:
        page = load_json(EXAMPLES / example_name)
        validate(example_name, page, SCHEMAS / page_schema_name)
        for index, item in enumerate(page[items_key]):
            validate(f"{example_name}/{items_key}/{index}", item, SCHEMAS / item_schema_name)


def main() -> int:
    try:
        schema_paths = sorted(SCHEMAS.glob("*.schema.json"))
        for schema_path in schema_paths:
            Draft202012Validator.check_schema(load_json(schema_path))
        for example_name, schema_name in EXAMPLE_CASES:
            if schema_name in {"list-page", "task-page", "changes-page"}:
                continue
            validate(example_name, load_json(EXAMPLES / example_name), SCHEMAS / schema_name)
        validate_pages()
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"Protocol validation failed:\n{exc}", file=sys.stderr)
        return 1
    print(f"Validated {len(schema_paths)} schemas and {len(EXAMPLE_CASES)} examples.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
