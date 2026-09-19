"""Contract tests: every parser of the release-notes header, fed the notes
build.yml actually renders.

The header "... for TrueNAS SCALE <version> (<train>)" drives install.sh's
train guard and stable-channel preview lock, check-kernel-coverage.py's
train scope and preview exclusion, promote.yml's body-based preview check,
and gen-supported-versions.py's version/train keys. k-tags carry no TrueNAS
version, so for new releases the header is the only place those checks can
read one. The shared fixture writes the header by hand; these tests render
the real heredoc from build.yml (substituting envsubst's own variable list)
so a reword breaks CI instead of silently disabling those checks."""
import json
import re
import subprocess
import textwrap
import unittest
from pathlib import Path

from release_fixtures import marker, release
from test_gen_supported_versions import gsv
from test_kernel_coverage import run_coverage
from test_promote_ranking import ranking_snippet
from test_release_selection import run_selection

BUILD_YML = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "build.yml"

K91 = "6.12.91-production+truenas"
K99 = "6.12.99-production+truenas"


def rendered_notes(version, train, kver, driver="4.21.0", run="1"):
    """The release body build.yml's Render release notes step produces."""
    lines = BUILD_YML.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if "<<'RELEASE_NOTES'" in line)
    end = next(i for i in range(start + 1, len(lines))
               if lines[i].strip() == "RELEASE_NOTES")
    # envsubst only replaces the variables it is given; mirror that list.
    names = re.findall(r"\$\{(\w+)\}", lines[start].split("<<")[0])
    values = {"TRUENAS_VERSION": version, "TRAIN_NAME": train,
              "HAILO_DRIVER": driver, "REAL_KVER": kver,
              "RUNNER_IMAGE": "ubuntu-22.04", "BUILD_SHA": "0" * 40,
              "REPO": "owner/repo", "RUN_NUMBER": run,
              "SHORT_KVER": kver.split("-")[0]}
    body = textwrap.dedent("\n".join(lines[start + 1:end]))
    for name in names:
        body = body.replace("${" + name + "}", values[name])
    return body


def rendered_release(tag, version, train, kver, prerelease=False):
    return dict(release(tag, prerelease=prerelease),
                body=rendered_notes(version, train, kver))


class Fixture(unittest.TestCase):
    def test_fixture_header_is_the_rendered_header(self):
        # Every fixture-based test in this suite inherits the header from
        # release_fixtures.release(); pin it to the template.
        rendered = rendered_notes("25.10.9", "Goldeye", K99).splitlines()[0]
        fixture = release("t", "25.10.9", "Goldeye", K99)["body"].splitlines()[0]
        self.assertEqual(fixture, rendered)


class InstallSelection(unittest.TestCase):
    def test_same_train_release_is_served(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9", "Goldeye", K99)
        p = run_selection([rel], "25.10.8", K99)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "k6.12.99-hailo4.21.0-r1")

    def test_train_guard_reads_the_header(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.04.9", "Fangtooth", K99)
        p = run_selection([rel], "25.10.8", K99)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("different TrueNAS train", p.stderr)

    def test_stable_preview_lock_reads_the_header(self):
        # Same train, so only the preview lock can refuse it; the prerelease
        # flag is (mis)published false, so only the header can tell.
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9-RC.1", "Goldeye", K99)
        p = run_selection([rel], "25.10.8", K99)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("different TrueNAS train", p.stderr)


class Coverage(unittest.TestCase):
    def test_same_train_release_covers(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9", "Goldeye", K99)
        self.assertEqual(run_coverage([rel], kver=K99, version="25.10.10"),
                         "promoted k6.12.99-hailo4.21.0-r1")

    def test_train_scope_reads_the_header(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.04.9", "Fangtooth", K99)
        self.assertEqual(run_coverage([rel], kver=K99, version="25.10.10"), "")

    def test_preview_exclusion_reads_the_header(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9-RC.1", "Goldeye", K99)
        self.assertEqual(run_coverage([rel], kver=K99, version="25.10.10"), "")


PROMOTE_DRIVER = """
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
console.log(JSON.stringify({
  bodyVer: bodyVerOf(input.release),
  preview: previewRelease(input.release),
  makeLatest: decideMakeLatest(input.release, input.others).makeLatest,
}));
"""


def promote(rel, others=()):
    p = subprocess.run(["node", "-e", ranking_snippet() + PROMOTE_DRIVER],
                       input=json.dumps({"release": rel, "others": list(others)}),
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise AssertionError(f"node failed: {p.stderr}")
    return json.loads(p.stdout)


class PromoteRanking(unittest.TestCase):
    def test_body_version_and_preview_read_the_header(self):
        res = promote(rendered_release("k6.18.23-hailo4.21.0-r1", "26.0.0-BETA.3",
                                       "Halfmoon", "6.18.23-production+truenas"))
        self.assertEqual(res["bodyVer"], "26.0.0-BETA.3")
        self.assertTrue(res["preview"])

    def test_mispublished_ktag_preview_cannot_hold_latest(self):
        # A newer-kernel k-tag preview published as a full release would
        # outrank the stable build if the header were not recognized.
        stable = rendered_release("k6.12.91-hailo4.21.0-r2", "25.10.4", "Goldeye", K91)
        preview = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9-RC.1", "Goldeye", K99)
        self.assertEqual(promote(stable, [preview])["makeLatest"], "true")


class SignOffChain(unittest.TestCase):
    """The issue build.yml opens, closed through promote.yml, yields notes
    the installer's selection accepts, for that build's train only. Each
    stage runs the real code (build.yml's and promote.yml's github-script
    under node, the selection snippet from install.sh), so a marker format
    change in any one of them breaks CI instead of silently approving
    nothing, or everything."""

    def chain(self, tag, version, train_name, kver, preview):
        from test_issue_template import render_issue
        from test_promote import apply, close
        iss = render_issue(tag, version, train_name, kver, preview=preview)
        iss = dict(iss, number=1, labels=[{"name": n} for n in iss["labels"]])
        rel = dict(rendered_release(tag, version, train_name, kver, prerelease=True),
                   id=1, created_at="2026-01-01T00:00:00Z")
        rels = [rel]
        before = run_selection(rels, version, kver)
        out = close(iss, rels)
        self.assertEqual(len(out["updates"]), 1, out)
        return before, apply(rels, out["updates"][0])

    def test_preview_sign_off_approves_train_26_only(self):
        k = "6.18.42-production+truenas"
        before, rels = self.chain("k6.18.42-hailo4.21.0-r47", "26.0.0-BETA.3",
                                  "Halfmoon", k, preview=True)
        self.assertNotEqual(before.returncode, 0)
        self.assertTrue(rels[0]["prerelease"])
        self.assertIn(f"\n\n{marker('26')}\n", rels[0]["body"])
        p = run_selection(rels, "26.0.0-BETA.3", k)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r47", p.stderr)
        p = run_selection(rels, "26.0.0-BETA.4", k)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r47", p.stderr)

    def test_stable_sign_off_promotes_and_approves_25_10(self):
        before, rels = self.chain("k6.12.105-hailo4.21.0-r46", "25.10.7",
                                  "Goldeye", "6.12.105-production+truenas", preview=False)
        self.assertNotEqual(before.returncode, 0)
        self.assertFalse(rels[0]["prerelease"])
        self.assertIn(marker("25.10"), rels[0]["body"])
        p = run_selection(rels, "25.10.8", "6.12.105-production+truenas")
        self.assertEqual(p.stdout, "k6.12.105-hailo4.21.0-r46", p.stderr)
        # The coverage gate agrees for the next version on that kernel.
        self.assertEqual(run_coverage(rels, kver="6.12.105-production+truenas",
                                      version="25.10.8"),
                         "promoted k6.12.105-hailo4.21.0-r46")


class SupportedVersionsTable(unittest.TestCase):
    def test_version_and_train_read_the_header(self):
        rel = rendered_release("k6.12.99-hailo4.21.0-r1", "25.10.9", "Goldeye", K99)
        parsed = gsv.parse_releases([rel])
        self.assertIn("25.10.9", parsed)
        entry = parsed["25.10.9"][0]
        self.assertEqual(entry["train"], "Goldeye")
        self.assertEqual(entry["kver"], K99)
        self.assertEqual(entry["driver"], "HailoRT 4.21.0")

    def test_preview_channel_reads_the_header(self):
        rel = rendered_release("k6.18.23-hailo4.21.0-r1", "26.0.0-BETA.3",
                               "Halfmoon", "6.18.23-production+truenas", prerelease=True)
        stable, preview = gsv.served_releases(gsv.parse_releases([rel]))
        self.assertEqual(stable, {})
        self.assertEqual(list(preview), ["26.0.0-BETA.3"])


if __name__ == "__main__":
    unittest.main()
