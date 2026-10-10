#!/usr/bin/env python3
"""Focused regression tests for the checked-in protocol schemas/examples."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import validate_protocol  # noqa: E402


class ProtocolSchemaTests(unittest.TestCase):
    def test_checked_in_examples_validate(self) -> None:
        self.assertEqual(validate_protocol.main(), 0)

    def test_tombstone_requires_at_least_thirty_days(self) -> None:
        tombstone = {
            "resourceType": "task",
            "resourceId": "task_1",
            "deletedAt": "2026-10-10T10:00:00Z",
            "retentionUntil": "2026-10-20T10:00:00Z",
            "revision": 1,
            "etag": '"task_1-1"',
            "providerRefs": [],
        }
        validator = validate_protocol.validator_for(ROOT / "schemas/tombstone.schema.json")
        tombstone["retentionUntil"] = "2026-11-09T10:00:00Z"
        self.assertTrue(list(validator.iter_errors(tombstone)) == [])

    def test_completed_task_requires_completed_at(self) -> None:
        task = json.loads((ROOT / "examples/tasks-page.json").read_text())["items"][0]
        invalid = copy.deepcopy(task)
        invalid["status"] = "completed"
        invalid["completedAt"] = None
        validator = validate_protocol.validator_for(ROOT / "schemas/task.schema.json")
        self.assertTrue(list(validator.iter_errors(invalid)))

    def test_task_create_defaults_to_open_when_status_is_omitted(self) -> None:
        task = {"listId": "list_home", "title": "Buy milk"}
        validator = validate_protocol.validator_for(ROOT / "schemas/task-input.schema.json")
        self.assertEqual(list(validator.iter_errors(task)), [])

    def test_update_requires_a_compare_and_swap_precondition(self) -> None:
        operation = {
            "operationId": "update_1",
            "op": "update",
            "resourceType": "task",
            "resourceId": "task_1",
            "fields": {"title": "new title"},
        }
        validator = validate_protocol.validator_for(ROOT / "schemas/mutation.schema.json")
        self.assertTrue(list(validator.iter_errors(operation)))

    def test_null_compare_and_swap_precondition_is_not_a_precondition(self) -> None:
        operation = {
            "operationId": "update_1",
            "op": "update",
            "resourceType": "task",
            "resourceId": "task_1",
            "fields": {"title": "new title"},
            "expectedEtag": None,
        }
        validator = validate_protocol.validator_for(ROOT / "schemas/mutation.schema.json")
        self.assertTrue(list(validator.iter_errors(operation)))


if __name__ == "__main__":
    unittest.main()
