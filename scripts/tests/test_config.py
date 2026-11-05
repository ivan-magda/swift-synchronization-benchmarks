from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from runner.config import REPOSITORY, ConfigError, load_local_config


class ConfigTests(unittest.TestCase):
    def test_load_config_and_missing_keys_without_leaking_private_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            document = {
                "teamID": "PRIVATE_TEAM",
                "bundleID": "example.bench",
                "phones": {
                    "phone": {"udid": "PRIVATE_UDID", "model": "iPhone1,1"}
                },
            }
            path.write_text(json.dumps(document))
            config = load_local_config(path)
            self.assertEqual(
                (
                    config.team_id,
                    config.bundle_id,
                    config.phones["phone"].key,
                    config.phones["phone"].model,
                ),
                ("PRIVATE_TEAM", "example.bench", "phone", "iPhone1,1"),
            )
            self.assertEqual(REPOSITORY, Path(__file__).resolve().parents[2])

            for key in ("teamID", "bundleID", "phones"):
                invalid = dict(document)
                invalid.pop(key)
                path.write_text(json.dumps(invalid))
                with self.assertRaisesRegex(ConfigError, key) as error:
                    load_local_config(path)
                self.assertNotIn("PRIVATE", str(error.exception))
                self.assertNotIn(directory, str(error.exception))

    def test_phone_key_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(
                json.dumps(
                    {
                        "teamID": "private",
                        "bundleID": "example.bench",
                        "phones": {"../escape": {"udid": "private", "model": "model"}},
                    }
                )
            )
            with self.assertRaisesRegex(ConfigError, "phones"):
                load_local_config(path)
