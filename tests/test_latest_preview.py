"""Unit tests for .github/scripts/latest-preview.py.

check-releases.yml uses the script to move the preview build to a newer
TrueNAS BETA/RC, including one that iX published under a new channel
directory (TrueNAS-26-BETA/ to TrueNAS-27-RC/ when 26 was renamed 27).
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = (Path(__file__).resolve().parents[1]
          / ".github" / "scripts" / "latest-preview.py")
CHECK_RELEASES = (Path(__file__).resolve().parents[1]
                  / ".github" / "workflows" / "check-releases.yml")

BETA_URL = "https://iso.sys.truenas.net/TrueNAS-26-BETA/"
RC_URL = "https://iso.sys.truenas.net/TrueNAS-27-RC/"


def root_entry(channel, version, iso=True):
    """The hrefs the root index shows for one release directory."""
    lines = [f'<a href="{channel}/{version}">',
             f'<a href="{channel}/{version}/rootfs.mtree">']
    if iso:
        lines.append(f'<a href="{channel}/{version}/TrueNAS-{version}.iso">')
        lines.append(
            f'<a href="{channel}/{version}/TrueNAS-{version}.iso.sha256">')
    return "\n".join(lines)


ROOT = "\n".join([
    '<a href="TrueNAS-26-BETA">',
    root_entry("TrueNAS-26-BETA", "26.0.0-BETA.2"),
    root_entry("TrueNAS-26-BETA", "26.0.0-BETA.3"),
    '<a href="TrueNAS-26-Nightlies/TrueNAS-26.0.0-MASTER+20260505-020136.iso">',
    '<a href="TrueNAS-27-RC">',
    root_entry("TrueNAS-27-RC", "27.0.0-RC.1"),
    '<a href="TrueNAS-27-Nightlies/TrueNAS-27.0.0-MASTER+20261006-020144.iso">',
])

CHANNEL_26 = "\n".join([
    '<a href="/TrueNAS-26-BETA/">',
    '<a href="./26.0.0-BETA.2/?wrap=1">',
    '<a href="./26.0.0-BETA.3/?wrap=1">',
    '<a href="./26.0.0-BETA.1/?wrap=1">',
    '<a href="../">',
])


class LatestPreview(unittest.TestCase):
    def run_script(self, root=None, channel=None, channel_url=BETA_URL,
                   current="26.0.0-BETA.3"):
        with tempfile.TemporaryDirectory() as tmp:
            args = ["python3", str(SCRIPT), "--channel-url", channel_url,
                    "--current", current]
            for flag, text in (("--root-listing", root),
                               ("--channel-listing", channel)):
                if text is None:
                    continue
                path = Path(tmp) / flag.strip("-")
                path.write_text(text)
                args += [flag, str(path)]
            p = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return dict(line.split("=", 1) for line in p.stdout.splitlines())

    def test_follows_a_new_channel_directory(self):
        out = self.run_script(root=ROOT, channel=CHANNEL_26)
        self.assertEqual(out, {"version": "27.0.0-RC.1",
                               "channel_url": RC_URL, "higher": "true"})

    def test_channel_listing_alone_still_works(self):
        out = self.run_script(root=None, channel=CHANNEL_26,
                              current="26.0.0-BETA.2")
        self.assertEqual(out, {"version": "26.0.0-BETA.3",
                               "channel_url": BETA_URL, "higher": "true"})

    def test_unreadable_root_listing_is_ignored(self):
        p = subprocess.run(
            ["python3", str(SCRIPT), "--channel-url", BETA_URL,
             "--root-listing", "/nonexistent/root.html",
             "--current", "26.0.0-BETA.3"],
            capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (0, ""))

    def test_tracked_version_is_not_higher(self):
        out = self.run_script(root=ROOT, channel_url=RC_URL,
                              current="27.0.0-RC.1")
        self.assertEqual(out["version"], "27.0.0-RC.1")
        self.assertEqual(out["higher"], "false")

    def test_directory_without_its_iso_does_not_count(self):
        root = ROOT + "\n" + root_entry("TrueNAS-27-RC", "27.0.0-RC.2",
                                        iso=False)
        out = self.run_script(root=root, channel_url=RC_URL,
                              current="27.0.0-RC.1")
        self.assertEqual(out["version"], "27.0.0-RC.1")

    def test_another_versions_iso_does_not_count(self):
        root = ROOT + ('\n<a href="TrueNAS-27-RC/27.0.0-RC.2/'
                       'TrueNAS-27.0.0-RC.1.iso">')
        out = self.run_script(root=root, channel_url=RC_URL,
                              current="27.0.0-RC.1")
        self.assertEqual(out["version"], "27.0.0-RC.1")

    def test_nightlies_are_ignored(self):
        root = '<a href="TrueNAS-27-Nightlies/TrueNAS-27.0.0-MASTER+20261006-020144.iso">'
        self.assertEqual(self.run_script(root=root), {})

    def test_rc_sorts_above_beta_and_beta_numbers_numerically(self):
        root = "\n".join([root_entry("TrueNAS-27-BETA", "27.0.0-BETA.10"),
                          root_entry("TrueNAS-27-BETA", "27.0.0-BETA.9"),
                          root_entry("TrueNAS-27-RC", "27.0.0-RC.1")])
        self.assertEqual(self.run_script(root=root)["version"], "27.0.0-RC.1")
        root = "\n".join([root_entry("TrueNAS-27-BETA", "27.0.0-BETA.10"),
                          root_entry("TrueNAS-27-BETA", "27.0.0-BETA.9")])
        self.assertEqual(self.run_script(root=root)["version"],
                         "27.0.0-BETA.10")

    def test_next_majors_beta_beats_this_majors_rc(self):
        root = ROOT + "\n" + root_entry("TrueNAS-28-BETA", "28.0.0-BETA.1")
        out = self.run_script(root=root, channel_url=RC_URL,
                              current="27.0.0-RC.1")
        self.assertEqual(out["channel_url"],
                         "https://iso.sys.truenas.net/TrueNAS-28-BETA/")

    def test_tracked_channel_wins_a_tie(self):
        root = root_entry("TrueNAS-26-BETA", "26.0.0-BETA.3")
        out = self.run_script(root=root, channel=CHANNEL_26,
                              current="26.0.0-BETA.2")
        self.assertEqual(out["channel_url"], BETA_URL)

    def test_lower_listing_never_moves_backwards(self):
        out = self.run_script(root=root_entry("TrueNAS-26-BETA",
                                              "26.0.0-BETA.2"),
                              current="26.0.0-BETA.3")
        self.assertEqual(out["higher"], "false")

    def test_check_releases_reads_mains_tip(self):
        # A queued run must not re-detect what the run before it bumped.
        text = CHECK_RELEASES.read_text()
        checkout = text[text.index("uses: actions/checkout"):]
        checkout = checkout[:checkout.index("- name:")]
        self.assertIn("ref: main", checkout)

    def test_check_releases_writes_the_channel_url(self):
        text = CHECK_RELEASES.read_text()
        self.assertIn("latest-preview.py", text)
        self.assertIn("s['truenas_preview']['channel_url'] = "
                      "os.environ['NEW_PREVIEW_CHANNEL_URL']", text)


if __name__ == "__main__":
    unittest.main()
