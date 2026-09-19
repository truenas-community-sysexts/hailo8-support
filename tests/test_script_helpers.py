"""Unit tests for the helpers install.sh and restore.sh share.

Both scripts must run piped from curl, where there is no sibling file to
source, so the shared helper is inlined in each. These tests keep the two
copies identical and check neither script loads code from elsewhere."""
import re
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def function_text(script, name):
    lines = (SCRIPTS / script).read_text().splitlines()
    start = lines.index(f"{name}() {{")
    end = lines.index("}", start)
    return "\n".join(lines[start:end + 1])


class SharedHelpers(unittest.TestCase):
    def test_init_script_lookup_copies_are_identical(self):
        # install.sh uses the lookup to update an existing registration and
        # restore.sh uses it to find the entry to delete; if the two ever
        # matched different entries, a restore could leave the PREINIT
        # registration the installer created behind.
        self.assertEqual(
            function_text("install.sh", "hailo_init_script_lookup"),
            function_text("restore.sh", "hailo_init_script_lookup"))

    def test_scripts_source_nothing(self):
        # A sourced sibling is missing under curl | bash, and a fetched one
        # depends on whatever the Latest release ships (the Latest at the
        # time of the kernel-keyed migration shipped no hailo-lib.sh, so
        # every install died before doing anything).
        for script in ("install.sh", "restore.sh", "uninstall.sh"):
            text = (SCRIPTS / script).read_text()
            self.assertIsNone(
                re.search(r"^\s*(source|\.)\s", text, re.MULTILINE),
                f"{script} sources another file")
            self.assertNotIn("hailo-lib.sh", text, script)


if __name__ == "__main__":
    unittest.main()
