"""Run promote.yml's github-script under node with a stub GitHub client.

Each test closes a hardware-test issue against a canned release list and
checks the release update and issue comment the workflow would make: a
sign-off appends the verified-train marker for the build's train (read from
its notes header), a stable build is also promoted as before (Andre's
cmpRank decides Latest), and a preview build only gets the marker."""
import copy
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from release_fixtures import marker, release
from workflow_script import run_script, step_script

PROMOTE_YML = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "promote.yml"

HARNESS = """
const state = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = { updates: [], comments: [], generated: [], compared: [] };
console.log = (...a) => process.stderr.write(a.join(' ') + '\\n');
const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });
const github = {
  rest: {
    repos: {
      getReleaseByTag: async ({ tag }) => {
        const r = state.releases.find((x) => x.tag_name === tag);
        if (!r) throw notFound();
        return { data: r };
      },
      listReleases: async () => ({ data: state.releases }),
      generateReleaseNotes: async (args) => {
        out.generated.push(args);
        return { data: { body: "## What's Changed\\n* fix: a change by @someone" } };
      },
      compareCommitsWithBasehead: async (args) => {
        out.compared.push(args.basehead);
        return { data: { commits: [{ sha: 'abcdef1234567', commit: { message: 'fix: a change\\n\\nmore' } }] } };
      },
      updateRelease: async (args) => { out.updates.push(args); },
    },
    issues: { createComment: async (args) => { out.comments.push(args.body); } },
  },
};
const context = { repo: { owner: 'truenas-community-sysexts', repo: 'hailo8-support' },
                  payload: { issue: state.issue } };
const core = { info: () => {}, warning: () => {} };
(async () => {
%s
})().then(() => process.stdout.write(JSON.stringify(out)),
          (e) => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""

K105 = "6.12.105-production+truenas"
K42 = "6.18.42-production+truenas"


def rel(tag, version, kver, n, prerelease=True, trains=(), train_name="Goldeye"):
    """A release as the API returns it: the fixture plus id and created_at."""
    published = (datetime(2026, 1, 1) + timedelta(hours=n)).strftime("%Y-%m-%dT%H:%M:%SZ")
    r = release(tag, version, train_name, kver=kver, prerelease=prerelease,
                published=published, trains=trains)
    return dict(r, id=n, created_at=published)


def stable(n, **kw):
    return rel(f"k6.12.105-hailo4.21.0-r{n}", "25.10.7", K105, n, **kw)


def beta(n, **kw):
    return rel(f"k6.18.42-hailo4.21.0-r{n}", "26.0.0-BETA.3", K42, n,
               train_name="Halfmoon", **kw)


def issue(tag, preview=None, labels=("hardware-test",), number=1):
    """A hardware-test issue with the markers build.yml writes. preview=None
    leaves out the preview-build marker, as issues from before it did."""
    body = f"**Release:** {tag}\n<!-- release-tag: {tag} -->\n"
    if preview is not None:
        body += f"<!-- preview-build: {'true' if preview else 'false'} -->\n"
    return {"number": number, "title": f"Hardware test: {tag}", "body": body,
            "labels": [{"name": n} for n in labels]}


def stable_issue(tag, **kw):
    return issue(tag, preview=False, **kw)


def preview_issue(tag, **kw):
    return issue(tag, preview=True, labels=("preview-hardware-test",), **kw)


def promote_script():
    return step_script("promote.yml", "Record the sign-off on the release this issue gates")


def close(iss, releases):
    return run_script(HARNESS, promote_script(), {"issue": iss, "releases": releases})


def apply(releases, update):
    """The release list after the workflow's updateRelease call."""
    rels = copy.deepcopy(releases)
    for r in rels:
        if r["id"] == update["release_id"]:
            r["prerelease"] = update.get("prerelease", r["prerelease"])
            r["body"] = update.get("body", r["body"])
    return rels


class StableSignOff(unittest.TestCase):
    def test_promotes_and_adds_the_marker_in_one_update(self):
        rels = [stable(46), stable(44, prerelease=False)]
        out = close(stable_issue(rels[0]["tag_name"]), rels)
        self.assertEqual(len(out["updates"]), 1, out)
        up = out["updates"][0]
        self.assertIs(up["prerelease"], False)
        self.assertEqual(up["make_latest"], "true")
        self.assertTrue(up["body"].startswith(rels[0]["body"]))
        self.assertEqual(up["body"].count("## Changelog"), 1)
        # The marker goes after the changelog, on a line of its own.
        self.assertTrue(up["body"].endswith(f"\n\n{marker('25.10')}\n"), up["body"])
        self.assertEqual(up["body"].count(marker("25.10")), 1)
        self.assertIn("promoted", out["comments"][0])
        self.assertIn("approved it for TrueNAS train `25.10`", out["comments"][0])

    def test_cmp_rank_keeps_latest_on_a_newer_kernel(self):
        newer = rel("k6.12.110-hailo4.21.0-r50", "25.10.8",
                    "6.12.110-production+truenas", 50, prerelease=False)
        rels = [stable(46), newer]
        out = close(stable_issue(rels[0]["tag_name"]), rels)
        up = out["updates"][0]
        self.assertEqual(up["make_latest"], "false")
        self.assertIn(marker("25.10"), up["body"])
        self.assertIn("Latest stays on the newer `kernel 6.12.110`", out["comments"][0])

    def test_marker_is_added_once(self):
        rels = [stable(46), stable(44, prerelease=False)]
        first = close(stable_issue(rels[0]["tag_name"]), rels)
        rels = apply(rels, first["updates"][0])
        again = close(stable_issue(rels[0]["tag_name"], number=2), rels)
        self.assertEqual(again["updates"], [])
        self.assertIn("already approved for TrueNAS train `25.10`", again["comments"][0])

    def test_grandfathered_full_release_is_left_alone(self):
        # A marker on a marker-less full release would narrow "every train"
        # down to this one.
        rels = [stable(44, prerelease=False)]
        out = close(stable_issue(rels[0]["tag_name"]), rels)
        self.assertEqual(out["updates"], [])
        self.assertIn("already promoted", out["comments"][0])

    def test_full_release_approved_elsewhere_only_gains_the_marker(self):
        rels = [stable(46, prerelease=False, trains=["25.04"])]
        out = close(stable_issue(rels[0]["tag_name"]), rels)
        self.assertEqual(len(out["updates"]), 1)
        up = out["updates"][0]
        self.assertNotIn("prerelease", up)
        self.assertNotIn("make_latest", up)
        self.assertEqual(up["body"], rels[0]["body"] + f"\n\n{marker('25.10')}\n")
        self.assertEqual(out["generated"], [])

    def test_legacy_issue_without_preview_marker_still_promotes(self):
        rels = [rel("v25.10.6-hailo4.21.0-r41", "25.10.6",
                    "6.12.99-production+truenas", 41)]
        out = close(issue(rels[0]["tag_name"]), rels)
        up = out["updates"][0]
        self.assertIs(up["prerelease"], False)
        self.assertIn(marker("25.10"), up["body"])

    def test_changelog_starts_at_the_previous_promoted_release(self):
        rels = [stable(46), stable(45), beta(44, prerelease=False),
                stable(43, prerelease=False)]
        out = close(stable_issue(rels[0]["tag_name"]), rels)
        self.assertEqual(out["compared"], [f"{rels[3]['tag_name']}...{rels[0]['tag_name']}"])

    def test_missing_release_is_reported(self):
        out = close(stable_issue("k6.12.105-hailo4.21.0-r99"), [stable(44)])
        self.assertEqual(out["updates"], [])
        self.assertIn("No release found for tag `k6.12.105-hailo4.21.0-r99`",
                      out["comments"][0])

    def test_release_without_a_header_version_changes_nothing(self):
        r = dict(stable(46), body="| Target kernel | `" + K105 + "` |\n")
        out = close(stable_issue(r["tag_name"]), [r])
        self.assertEqual(out["updates"], [])
        self.assertIn("name no TrueNAS version", out["comments"][0])


class PreviewSignOff(unittest.TestCase):
    def test_adds_the_marker_only(self):
        rels = [beta(47), stable(44, prerelease=False)]
        out = close(preview_issue(rels[0]["tag_name"]), rels)
        self.assertEqual(len(out["updates"]), 1, out)
        up = out["updates"][0]
        # Body only: it stays a prerelease, and Latest is not touched.
        self.assertEqual(set(up), {"owner", "repo", "release_id", "body"})
        self.assertEqual(up["body"], rels[0]["body"] + f"\n\n{marker('26')}\n")
        self.assertEqual(out["generated"], [])
        self.assertIn("approved it for TrueNAS train `26`", out["comments"][0])
        self.assertIn("never promoted to Latest", out["comments"][0])

    def test_is_idempotent(self):
        rels = [beta(47)]
        first = close(preview_issue(rels[0]["tag_name"]), rels)
        rels = apply(rels, first["updates"][0])
        again = close(preview_issue(rels[0]["tag_name"], number=2), rels)
        self.assertEqual(again["updates"], [])
        self.assertIn("already approved for TrueNAS train `26`", again["comments"][0])

    def test_a_preview_build_is_never_promoted_whatever_the_label(self):
        # Mislabeled hardware-test issue: the preview-build marker, the tag
        # or the notes header still keeps it a prerelease.
        cases = [
            (beta(47), issue("k6.18.42-hailo4.21.0-r47", preview=True)),
            (beta(47), issue("k6.18.42-hailo4.21.0-r47")),  # header only
            (rel("v26.0.0-BETA.3-hailo4.21.0-r42", "26.0.0-BETA.3", K42, 42,
                 train_name="Halfmoon"),
             issue("v26.0.0-BETA.3-hailo4.21.0-r42")),
        ]
        for r, iss in cases:
            out = close(iss, [r])
            self.assertEqual(len(out["updates"]), 1, out)
            self.assertNotIn("prerelease", out["updates"][0])
            self.assertIn(marker("26"), out["updates"][0]["body"])

    def test_train_is_the_major_from_26_on(self):
        r = rel("k6.18.60-hailo4.21.0-r70", "26.1.0-RC.1", "6.18.60-production+truenas",
                70, train_name="Halfmoon")
        out = close(preview_issue(r["tag_name"]), [r])
        body = out["updates"][0]["body"]
        self.assertTrue(body.endswith(f"\n\n{marker('26')}\n"), body)
        self.assertNotIn("verified-train: 26.1", body)


class Trigger(unittest.TestCase):
    def test_job_runs_for_both_labels_on_completed_only(self):
        text = PROMOTE_YML.read_text()
        cond = text[text.index("    if: >-"):text.index("    runs-on:")]
        self.assertIn("'hardware-test'", cond)
        self.assertIn("'preview-hardware-test'", cond)
        self.assertIn("github.event.issue.state_reason == 'completed'", cond)


class TrainKeyParity(unittest.TestCase):
    def test_train_key_matches_the_installer(self):
        from test_promote_ranking import ranking_snippet
        from test_release_selection import TrainKey
        import json
        import subprocess
        driver = ("const vs = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
                  "console.log(JSON.stringify(vs.map(trainKey)));")
        versions = list(TrainKey.CASES)
        p = subprocess.run(["node", "-e", ranking_snippet() + driver],
                           input=json.dumps(versions), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        got = dict(zip(versions, json.loads(p.stdout)))
        for version, want in TrainKey.CASES.items():
            self.assertEqual(got[version] or None, want, version)


if __name__ == "__main__":
    unittest.main()
