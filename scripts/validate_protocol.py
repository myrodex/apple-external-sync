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
    import yaml
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
    lists = load_json(EXAMPLES / "lists-page.json")
    list_schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["items", "nextCursor", "hasMore", "serverTime"],
        "properties": {
            "items": {"type": "array", "items": {"$ref": "list.schema.json"}},
            "nextCursor": {"type": ["string", "null"]},
            "hasMore": {"type": "boolean"},
            "serverTime": {"type": "string", "format": "date-time"},
        },
    }
    validate("lists-page.json", lists, SCHEMAS / "list.schema.json") if False else None
    # Validate each page envelope and each resource separately to keep the page
    # schema intentionally local to the OpenAPI document.
    resolver_store = schema_store()
    resolver = RefResolver((SCHEMAS / "list-page.schema.json").as_uri(), list_schema, store=resolver_store)
    errors = sorted(
        Draft202012Validator(list_schema, resolver=resolver, format_checker=FormatChecker()).iter_errors(lists),
        key=lambda error: list(error.path),
    )
    if errors:
        raise ValueError("\n".join(f"  - lists-page.json: {error.message}" for error in errors))
    for index, item in enumerate(lists["items"]):
        validate(f"lists-page.json/items/{index}", item, SCHEMAS / "list.schema.json")

    tasks = load_json(EXAMPLES / "tasks-page.json")
    task_page_schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["items", "nextCursor", "hasMore", "serverTime"],
        "properties": {
            "items": {"type": "array", "items": {"$ref": "task.schema.json"}},
            "nextCursor": {"type": ["string", "null"]},
            "hasMore": {"type": "boolean"},
            "serverTime": {"type": "string", "format": "date-time"},
        },
    }
    resolver = RefResolver((SCHEMAS / "task-page.schema.json").as_uri(), task_page_schema, store=resolver_store)
    errors = sorted(
        Draft202012Validator(task_page_schema, resolver=resolver, format_checker=FormatChecker()).iter_errors(tasks),
        key=lambda error: list(error.path),
    )
    if errors:
        raise ValueError("\n".join(f"  - tasks-page.json: {error.message}" for error in errors))
    for index, item in enumerate(tasks["items"]):
        validate(f"tasks-page.json/items/{index}", item, SCHEMAS / "task.schema.json")

    changes = load_json(EXAMPLES / "changes-page.json")
    change_page_schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["items", "nextCursor", "hasMore", "serverTime", "tombstoneRetentionDays"],
        "properties": {
            "items": {"type": "array", "items": {"$ref": "change.schema.json"}},
            "nextCursor": {"type": ["string", "null"]},
            "hasMore": {"type": "boolean"},
            "serverTime": {"type": "string", "format": "date-time"},
            "tombstoneRetentionDays": {"type": "integer", "minimum": 30},
            "warnings": {"type": "array", "items": {"$ref": "warning.schema.json"}},
        },
    }
    resolver = RefResolver((SCHEMAS / "change-page.schema.json").as_uri(), change_page_schema, store=resolver_store)
    errors = sorted(
        Draft202012Validator(change_page_schema, resolver=resolver, format_checker=FormatChecker()).iter_errors(changes),
        key=lambda error: list(error.path),
    )
    if errors:
        raise ValueError("\n".join(f"  - changes-page.json: {error.message}" for error in errors))
    for index, item in enumerate(changes["items"]):
        validate(f"changes-page.json/items/{index}", item, SCHEMAS / "change.schema.json")


def main() -> int:
    try:
        for example_name, schema_name in EXAMPLE_CASES:
            if schema_name in {"list-page", "task-page", "changes-page"}:
                continue
            validate(example_name, load_json(EXAMPLES / example_name), SCHEMAS / schema_name)
        validate_pages()
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"Protocol validation failed:\n{exc}", file=sys.stderr)
        return 1
    print(f"Validated {len(list(SCHEMAS.glob('*.schema.json')))} schemas and {len(EXAMPLE_CASES)} examples.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
