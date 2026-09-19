"""Unit tests for the Latest-ranking logic embedded in promote.yml.

The JavaScript between the BEGIN/END promote-ranking sentinels is extracted
verbatim (dedented from its YAML indentation) and run under node with a
canned release list, exactly the code the workflow executes."""
import json
import subprocess
import unittest
from pathlib import Path

from release_fixtures import release

PROMOTE_YML = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "promote.yml"


def ranking_snippet():
    text = PROMOTE_YML.read_text()
    begin_mark = "// BEGIN promote-ranking"
    begin = text.rindex("\n", 0, text.index(begin_mark)) + 1
    end = text.index("// END promote-ranking")
    indent = text.index(begin_mark) - begin
    block = text[begin:end]
    return "\n".join(line[indent:] for line in block.splitlines())


DRIVER = """
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const res = decideMakeLatest(input.release, input.others);
console.log(JSON.stringify(res));
"""


def decide(rel, others):
    p = subprocess.run(["node", "-e", ranking_snippet() + DRIVER],
                       input=json.dumps({"release": rel, "others": others}),
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise AssertionError(f"node failed: {p.stderr}")
    return json.loads(p.stdout)


K33 = "6.12.33-production+truenas"
K91 = "6.12.91-production+truenas"


class KernelRanking(unittest.TestCase):
    def test_newer_kernel_takes_latest(self):
        res = decide(release("v25.10.4-hailo4.21.0-r3", "25.10.4", kver=K91),
                     [release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "true")

    def test_older_kernel_never_regresses_latest(self):
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("v25.10.4-hailo4.21.0-r3", "25.10.4", kver=K91)])
        self.assertEqual(res["makeLatest"], "false")

    def test_ktag_ranks_by_encoded_kernel(self):
        res = decide(release("k6.12.91-hailo4.21.0-r9", "25.10.4", kver=K91),
                     [release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "true")

    def test_prerelease_others_cannot_hold_latest(self):
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("v25.10.4-hailo4.21.0-r3", "25.10.4", kver=K91,
                              prerelease=True)])
        self.assertEqual(res["makeLatest"], "true")


class SameKernelTiebreak(unittest.TestCase):
    # A driver bump rebuilds every kernel, leaving two releases per kernel;
    # promoting the older one must not steal Latest (the install one-liner
    # pulls from releases/latest/download/).

    def test_older_version_on_same_kernel_does_not_take_latest(self):
        # The regression scyto simulated: the older version has the HIGHER
        # run number (it was rebuilt later), so the version must rank first.
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("v25.10.3.1-hailo4.21.0-r1", "25.10.3.1",
                              kver=K33)])
        self.assertEqual(res["makeLatest"], "false")

    def test_newer_version_on_same_kernel_takes_latest(self):
        res = decide(release("v25.10.3.1-hailo4.21.0-r1", "25.10.3.1", kver=K33),
                     [release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "true")

    def test_vtag_does_not_displace_newer_ktag_build_on_same_kernel(self):
        # k-tags carry no TrueNAS version; the run number breaks the tie.
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("k6.12.33-hailo4.21.0-r12", "25.10.3.1",
                              kver=K33)])
        self.assertEqual(res["makeLatest"], "false")

    def test_ktag_displaces_older_vtag_build_on_same_kernel(self):
        res = decide(release("k6.12.33-hailo4.21.0-r12", "25.10.3.1", kver=K33),
                     [release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "true")

    def test_same_version_newer_run_takes_latest(self):
        res = decide(release("v25.10.3-hailo4.21.0-r9", "25.10.3", kver=K33),
                     [release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "true")

    def test_same_version_older_run_does_not_take_latest(self):
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("v25.10.3-hailo4.21.0-r9", "25.10.3", kver=K33)])
        self.assertEqual(res["makeLatest"], "false")


class LegacyRanking(unittest.TestCase):
    def test_old_ktag_does_not_displace_newer_kernel_unknown_latest(self):
        # A k-tag carries no TrueNAS version and a release whose body lost
        # its Target kernel row ranks by version only: no shared dimension.
        # Publication date decides, so promoting an OLD k-tag build cannot
        # steal Latest from a newer release with a damaged body.
        res = decide(release("k6.12.33-hailo4.21.0-r12", "25.10.3",
                             kver=K33, published="2026-01-10T00:00:00Z"),
                     [release("v25.10.4-hailo4.21.0-r3", "25.10.4",
                              published="2026-02-01T00:00:00Z")])
        self.assertEqual(res["makeLatest"], "false")

    def test_new_ktag_still_displaces_older_kernel_unknown_release(self):
        res = decide(release("k6.12.91-hailo4.21.0-r9", "25.10.4",
                             kver=K91, published="2026-02-01T00:00:00Z"),
                     [release("v25.04.1-hailo4.20.0-r5", "25.04.1",
                              published="2025-05-01T00:00:00Z")])
        self.assertEqual(res["makeLatest"], "true")

    def test_known_kernel_outranks_legacy_body(self):
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3", kver=K33),
                     [release("v25.10.4-hailo4.21.0-r3", "25.10.4")])
        self.assertEqual(res["makeLatest"], "true")

    def test_two_legacy_releases_compare_by_version(self):
        res = decide(release("v25.10.3-hailo4.21.0-r7", "25.10.3"),
                     [release("v25.10.4-hailo4.21.0-r3", "25.10.4")])
        self.assertEqual(res["makeLatest"], "false")


if __name__ == "__main__":
    unittest.main()
