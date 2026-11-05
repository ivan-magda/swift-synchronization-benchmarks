from __future__ import annotations

import json
from pathlib import Path
import unittest


class FixturePrivacyTests(unittest.TestCase):
    def test_fixtures_have_no_identifiers(self):
        folder = Path(__file__).parent / 'fixtures'
        for path in folder.rglob('*'):
            if not path.is_file():
                continue
            text = path.read_text()
            self.assertNotRegex(
                text,
                r'(?i)ivan|/Users/|/home/|[0-9a-f]{8}-[0-9a-f]{16}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{40}',
            )
            if path.suffix == '.json':
                def inspect(value):
                    if isinstance(value, dict):
                        for key, item in value.items():
                            if key.lower() in (
                                'udid',
                                'identifier',
                                'deviceidentifier',
                                'serialnumber',
                                'ecid',
                                'name',
                                'potentialhostnames',
                                'arguments',
                            ):
                                self.assertRegex(
                                    str(item),
                                    r'^(?:UDID-|DEVICE-|SERIAL-|ECID-|NAME-|HOST-|ARG-)',
                                )
                            inspect(item)
                    elif isinstance(value, list):
                        for item in value:
                            inspect(item)

                inspect(json.loads(text))
