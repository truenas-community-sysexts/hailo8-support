"""Unit tests for the release-selection logic embedded in scripts/install.sh.

get.sh, scripts/install.sh and scripts/uninstall.sh each carry a verbatim
copy of the shared block between the BEGIN/END approved-release sentinels
(all three are self-contained curl|bash scripts). The Python between the
BEGIN/END release-selection sentinels is extracted verbatim and run as a
subprocess with a canned GitHub releases JSON on stdin, exactly how the
scripts run it; the shell functions run under bash with stubbed commands."""
import functools
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from release_fixtures import release

ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = ROOT / "scripts" / "install.sh"
UNINSTALL_SH = ROOT / "scripts" / "uninstall.sh"
GET_SH = ROOT / "get.sh"
BUILD_YML = ROOT / ".github" / "workflows" / "build.yml"
REPO = "truenas-community-sysexts/hailo8-support"


def between(path, begin, end):
    text = path.read_text()
    return text[text.index(begin):text.index(end)]


def shared_block(path):
    return between(path, "# BEGIN approved-release", "# END approved-release")


def selection_snippet():
    return between(INSTALL_SH, "# BEGIN release-selection", "# END release-selection")


def run_block(commands, env=None):
    """Run the shared block from install.sh, then `commands`, under bash."""
    script = f"REPO={REPO}\n{shared_block(INSTALL_SH)}\n{commands}\n"
    return subprocess.run(["bash", "-c", script], capture_output=True,
                          text=True, env=dict(os.environ, **(env or {})))


@functools.lru_cache(maxsize=None)
def train_key(version):
    """truenas_train_key's answer, or None when it has none."""
    p = run_block(f'truenas_train_key "{version}"')
    return p.stdout.strip() if p.returncode == 0 else None


def run_selection_raw(text, version, kver, purpose="install", train=None):
    return subprocess.run(
        ["python3", "-c", selection_snippet()],
        input=text, capture_output=True, text=True,
        env={"VERSION": version, "KVER": kver,
             "TRAIN": train if train is not None else (train_key(version) or ""),
             "PURPOSE": purpose, "REPO": REPO, "PATH": "/usr/bin:/bin"})


def run_selection(releases, version, kver, purpose="install", train=None):
    return run_selection_raw(json.dumps(releases), version, kver, purpose, train)


RELEASES = [
    release("v25.10.3-hailo4.21.0-r39", "25.10.3",
            kver="6.12.33-production+truenas"),
    release("v25.10.4-hailo4.21.0-r37", "25.10.4",
            kver="6.12.91-production+truenas"),
    release("v25.10.5-hailo4.21.0-r40", "25.10.5",
            kver="6.12.93-production+truenas", prerelease=True),
    # A preview build signed off on train 26: it stays a prerelease, and
    # only its verified-train line approves it.
    release("v26.0.0-BETA.2-hailo4.21.0-r38", "26.0.0-BETA.2",
            kver="6.18.23-production+truenas", prerelease=True, trains=["26"]),
    release("v25.04.1-hailo4.20.0-r5", "25.04.1"),
]


class KernelMatch(unittest.TestCase):
    def test_unbuilt_point_release_matches_by_kernel(self):
        p = run_selection(RELEASES, "25.10.2", "6.12.33-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.3-hailo4.21.0-r39")

    def test_stable_box_never_gets_prerelease(self):
        p = run_selection(RELEASES, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No stable release found", p.stderr)

    def test_stable_box_refuses_beta_tag_even_when_not_prerelease(self):
        # The prerelease flag can be mispublished (a manual edit, say). The
        # tag is the second lock on the stable channel.
        rels = [release("v26.0.0-RC.1-hailo4.21.0-r44", "26.0.0-RC.1",
                        kver="6.12.93-production+truenas", prerelease=False)]
        p = run_selection(rels, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)

    def test_stable_box_refuses_ktagged_preview_via_body_header(self):
        # Kernel-keyed tags carry no BETA marker, so the second lock must
        # read the notes header instead of the tag.
        rels = [release("k6.12.93-hailo4.21.0-r44", "26.0.0-RC.1",
                        kver="6.12.93-production+truenas", prerelease=False)]
        p = run_selection(rels, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)

    def test_preview_box_gets_approved_prerelease(self):
        p = run_selection(RELEASES, "26.0.0-BETA.2", "6.18.23-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v26.0.0-BETA.2-hailo4.21.0-r38")

    def test_ktag_matches_when_body_row_is_lost(self):
        # check-releases' coverage gate counts a k-tag as covering its kernel
        # even when the body lost the Target kernel row; the installer must
        # agree, or the gate skips builds for a kernel the installer then
        # refuses to serve.
        rel = dict(release("k6.12.91-hailo4.21.0-r50", "25.10.4"),
                   body="")
        p = run_selection([rel], "25.10.4", "6.12.91-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "k6.12.91-hailo4.21.0-r50")

    def test_ktag_fallback_never_matches_a_different_short_kernel(self):
        rel = dict(release("k6.12.9-hailo4.21.0-r50", "25.10.4"), body="")
        p = run_selection([rel], "25.10.4", "6.12.91-production+truenas")
        self.assertNotEqual(p.returncode, 0)

    def test_body_row_overrides_ktag_on_mismatch(self):
        # A mispublished release whose body advertises a different kernel
        # than its tag must not be served: the body row is written from
        # REAL_KVER at build time and stays authoritative.
        rel = release("k6.12.91-hailo4.21.0-r50", "25.10.3",
                      kver="6.12.33-production+truenas")
        p = run_selection([rel], "25.10.4", "6.12.91-production+truenas")
        self.assertNotEqual(p.returncode, 0)

    def test_version_fallback_for_legacy_release(self):
        p = run_selection(RELEASES, "25.04.1", "6.12.15-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.04.1-hailo4.20.0-r5")
        self.assertIn("matched by TrueNAS version", p.stderr)

    def test_fallback_never_picks_wrong_advertised_kernel(self):
        # A release advertising a DIFFERENT kernel must not win on version
        # prefix: wrong modules cannot load.
        rels = [release("v25.10.9-hailo4.21.0-r50", "25.10.9",
                        kver="6.12.91-production+truenas")]
        p = run_selection(rels, "25.10.9", "6.12.99-production+truenas")
        self.assertNotEqual(p.returncode, 0)

    def test_no_match_lists_available_releases(self):
        p = run_selection(RELEASES, "25.10.9", "6.12.99-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("v25.10.4-hailo4.21.0-r37", p.stderr)
        self.assertIn("6.12.91-production+truenas", p.stderr)

    def test_no_match_shows_pending_prerelease_for_this_kernel(self):
        # A stable build awaiting hardware-test promotion is an expected
        # state; hiding it sends the user off to rebuild or file a duplicate.
        p = run_selection(RELEASES, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("v25.10.5-hailo4.21.0-r40", p.stderr)
        self.assertIn("awaiting hardware-test", p.stderr)
        self.assertIn("(prerelease)", p.stderr)

    def test_no_match_pending_hint_excludes_preview_builds(self):
        # A preview (BETA/RC) build is never promoted, so a stable box whose
        # kernel matches only a preview prerelease must not be promised an
        # install "once promoted". pending_builds() in
        # gen-supported-versions.py applies the same exclusion.
        rels = [release("v26.0.0-BETA.2-hailo4.21.0-r38", "26.0.0-BETA.2",
                        kver="6.12.93-production+truenas", prerelease=True)]
        p = run_selection(rels, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("awaiting hardware-test", p.stderr)

    def test_draft_ignored(self):
        rels = RELEASES + [release("v25.10.9-hailo4.21.0-r99", "25.10.9",
                                   kver="6.12.99-production+truenas",
                                   draft=True)]
        p = run_selection(rels, "25.10.9", "6.12.99-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("v25.10.9-hailo4.21.0-r99", p.stderr)


class TrainGuard(unittest.TestCase):
    # Hailo divergence from coral: the sysext ships userspace (libhailort,
    # hailortcli) built against a train's base system, so a kernel match from
    # another train must never be served.
    def test_same_train_other_version_matches(self):
        rels = [release("v25.10.3.1-hailo4.21.0-r41", "25.10.3.1",
                        kver="6.12.33-production+truenas")]
        p = run_selection(rels, "25.10.2", "6.12.33-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.3.1-hailo4.21.0-r41")

    def test_cross_train_kernel_match_refused(self):
        rels = [release("v25.04.2-hailo4.21.0-r42", "25.04.2",
                        kver="6.12.33-production+truenas")]
        p = run_selection(rels, "25.10.2", "6.12.33-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("v25.04.2-hailo4.21.0-r42", p.stderr)
        self.assertIn("different TrueNAS train", p.stderr)

    def test_release_without_header_passes_guard(self):
        rel = release("v25.10.3-hailo4.21.0-r43", "25.10.3",
                      kver="6.12.33-production+truenas")
        rel["body"] = ("| Field | Value |\n| --- | --- |\n"
                       "| Target kernel | `6.12.33-production+truenas` |\n")
        p = run_selection([rel], "25.10.2", "6.12.33-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.3-hailo4.21.0-r43")


class Pagination(unittest.TestCase):
    def test_concatenated_pages_are_merged(self):
        page1 = [release("v25.10.4-hailo4.21.0-r37", "25.10.4",
                         kver="6.12.91-production+truenas")]
        page2 = [release("v25.04.1-hailo4.20.0-r5", "25.04.1")]
        text = json.dumps(page1) + "\n" + json.dumps(page2) + "\n"
        p = run_selection_raw(text, "25.04.1", "6.12.15-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.04.1-hailo4.20.0-r5")

    def test_api_error_object_on_any_page_is_reported(self):
        text = json.dumps([]) + "\n" + json.dumps(
            {"message": "API rate limit exceeded for 1.2.3.4"}) + "\n"
        p = run_selection_raw(text, "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("rate limit", p.stderr)

    def test_empty_input_is_a_parse_error(self):
        p = run_selection_raw("", "25.10.5", "6.12.93-production+truenas")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Failed to parse", p.stderr)


class TemplateContract(unittest.TestCase):
    def test_regex_matches_the_actual_build_yml_notes_row(self):
        # The Target kernel row is the installer's primary match key. This
        # test feeds the selection logic a body built from the very template
        # line build.yml renders, so rewording the notes breaks CI instead of
        # silently reverting every new release to the legacy fallback.
        rows = [line for line in BUILD_YML.read_text().splitlines()
                if "Target kernel" in line]
        self.assertEqual(len(rows), 1, rows)
        body = rows[0].strip().replace("${REAL_KVER}",
                                       "6.12.99-production+truenas")
        rel = dict(release("v25.10.9-hailo4.21.0-r1", "25.10.9"), body=body)
        p = run_selection([rel], "25.10.9", "6.12.99-production+truenas")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.9-hailo4.21.0-r1")


K42 = "6.18.42-production+truenas"
K105 = "6.12.105-production+truenas"
BETA3 = ("26.0.0-BETA.3", K42)
STABLE7 = ("25.10.7", K105)


def beta3(tag, **kw):
    return release(tag, "26.0.0-BETA.3", "Halfmoon", kver=K42, prerelease=True, **kw)


def stable7(tag, **kw):
    return release(tag, "25.10.7", "Goldeye", kver=K105, **kw)


class Approval(unittest.TestCase):
    # Nothing unapproved is installed, on stable or preview boxes. Approved:
    # a verified-train line for the box's train, or a full release with no
    # line at all (promoted before per-train sign-off).

    def test_marker_for_the_train_is_approved(self):
        rels = [beta3("k6.18.42-hailo4.21.0-r47", trains=["26"])]
        p = run_selection(rels, *BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r47")

    def test_marker_for_another_train_only_is_rejected(self):
        rels = [stable7("k6.12.105-hailo4.21.0-r46", prerelease=True, trains=["26"])]
        p = run_selection(rels, *STABLE7)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def test_full_release_marked_for_another_train_only_is_rejected(self):
        # A marker narrows a full release to the trains it names: it is no
        # longer grandfathered for every train.
        rels = [stable7("k6.12.105-hailo4.21.0-r46", trains=["25.04"])]
        p = run_selection(rels, *STABLE7)
        self.assertNotEqual(p.returncode, 0)

    def test_grandfathered_full_release_is_approved(self):
        rels = [stable7("v25.10.7-hailo4.21.0-r43")]
        p = run_selection(rels, *STABLE7)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.7-hailo4.21.0-r43")

    def test_prerelease_without_marker_is_rejected_on_a_stable_box(self):
        rels = [stable7("k6.12.105-hailo4.21.0-r46", prerelease=True)]
        p = run_selection(rels, *STABLE7)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def test_prerelease_without_marker_is_rejected_on_a_preview_box(self):
        # The owner-decided change: a beta box no longer installs an
        # unverified preview build straight away.
        rels = [beta3("k6.18.42-hailo4.21.0-r47")]
        p = run_selection(rels, *BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("No preview (beta) release found", p.stderr)

    def test_preview_with_marker_is_approved(self):
        rels = [beta3("k6.18.42-hailo4.21.0-r47", trains=["26"]),
                beta3("k6.18.42-hailo4.21.0-r48", published="2026-02-01T00:00:00Z")]
        p = run_selection(rels, *BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        # r48 is newer but unapproved: the newest APPROVED build wins.
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r47")

    def test_stable_box_refuses_preview_build_even_with_its_trains_marker(self):
        # A future 26.x stable box on the same kernel as a signed-off beta
        # build: the stable channel still never serves a beta build.
        rels = [beta3("k6.18.42-hailo4.21.0-r47", trains=["26"])]
        p = run_selection(rels, "26.0.0", K42)
        self.assertNotEqual(p.returncode, 0)

    def test_newest_approved_release_wins(self):
        rels = [stable7("k6.12.105-hailo4.21.0-r46", trains=["25.10"],
                        published="2026-03-01T00:00:00Z"),
                stable7("v25.10.7-hailo4.21.0-r43", published="2026-02-01T00:00:00Z"),
                stable7("k6.12.105-hailo4.21.0-r49", prerelease=True,
                        published="2026-04-01T00:00:00Z")]
        p = run_selection(rels, *STABLE7)
        self.assertEqual(p.stdout, "k6.12.105-hailo4.21.0-r46")

    def test_marker_must_start_a_line(self):
        # A changelog line quoting a marker (a PR title, say) is not an
        # approval: promote.yml writes the marker on a line of its own.
        rel = beta3("k6.18.42-hailo4.21.0-r47")
        rel["body"] += "\n## Changelog\n* ci: add <!-- verified-train: 26 --> by @x\n"
        p = run_selection([rel], *BETA3)
        self.assertNotEqual(p.returncode, 0)

    def test_marker_spacing_and_crlf_are_tolerated(self):
        rel = beta3("k6.18.42-hailo4.21.0-r47")
        rel["body"] = rel["body"].replace("\n", "\r\n") + "\r\n<!--verified-train:26-->\r\n"
        p = run_selection([rel], *BETA3)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r47")

    def test_marker_does_not_match_a_longer_train_key(self):
        rels = [stable7("k6.12.105-hailo4.21.0-r46", prerelease=True, trains=["25.1"])]
        p = run_selection(rels, *STABLE7)
        self.assertNotEqual(p.returncode, 0)


class KernelStaysPrimary(unittest.TestCase):
    def test_approved_release_for_another_kernel_is_rejected(self):
        rels = [release("k6.18.23-hailo4.21.0-r38", "26.0.0-BETA.2", "Halfmoon",
                        kver="6.18.23-production+truenas", prerelease=True,
                        trains=["26"])]
        p = run_selection(rels, *BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def test_grandfathered_release_for_another_kernel_is_rejected(self):
        rels = [release("v25.10.5-hailo4.21.0-r40", "25.10.5", kver="6.12.95-production+truenas")]
        p = run_selection(rels, *STABLE7)
        self.assertNotEqual(p.returncode, 0)


class TrainGuardKey(unittest.TestCase):
    # The guard keeps its shape; only its train key changed: all of 26.x is
    # one train, so 26.0 and 26.1 no longer split.

    def test_26_0_and_26_1_are_the_same_train(self):
        rels = [release("k6.18.42-hailo4.21.0-r60", "26.1.0", "Halfmoon", kver=K42,
                        trains=["26"])]
        p = run_selection(rels, "26.0.0", K42)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r60")
        self.assertNotIn("different TrueNAS train", p.stderr)

    def test_beta_and_final_of_26_are_the_same_train(self):
        rels = [release("k6.18.42-hailo4.21.0-r60", "26.0.1", "Halfmoon", kver=K42,
                        trains=["26"])]
        p = run_selection(rels, *BETA3)
        self.assertEqual(p.stdout, "k6.18.42-hailo4.21.0-r60")

    def test_25_10_and_26_are_different_trains(self):
        # Grandfathered (approved for every train) and on the box's kernel:
        # only the train guard can refuse it.
        rels = [release("k6.18.42-hailo4.21.0-r61", "25.10.9", "Goldeye", kver=K42)]
        p = run_selection(rels, "26.0.0", K42)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("different TrueNAS train", p.stderr)
        p = run_selection([release("k6.18.42-hailo4.21.0-r61", "26.0.0", "Halfmoon",
                                   kver=K42)], "25.10.9", K42)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("different TrueNAS train", p.stderr)

    def test_25_04_and_25_10_stay_different_trains(self):
        rels = [release("v25.04.2-hailo4.21.0-r42", "25.04.2", kver=K105)]
        p = run_selection(rels, *STABLE7)
        self.assertIn("different TrueNAS train", p.stderr)


class NoCandidate(unittest.TestCase):
    def test_message_names_the_waiting_hardware_test(self):
        rels = [beta3("k6.18.42-hailo4.21.0-r47"),
                stable7("v25.10.5-hailo4.21.0-r40")]
        p = run_selection(rels, *BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("No preview (beta) release found for kernel " + K42, p.stderr)
        self.assertIn("approved for TrueNAS train 26", p.stderr)
        self.assertIn("awaiting hardware-test sign-off for train 26", p.stderr)
        self.assertIn(f"k6.18.42-hailo4.21.0-r47: https://github.com/{REPO}/issues?q="
                      "is%3Aissue+label%3Apreview-hardware-test+in%3Atitle"
                      "+%22k6.18.42-hailo4.21.0-r47%22", p.stderr)

    def test_stable_build_points_at_the_stable_label(self):
        p = run_selection([stable7("k6.12.105-hailo4.21.0-r46", prerelease=True)], *STABLE7)
        self.assertIn("label%3Ahardware-test+", p.stderr)
        self.assertNotIn("preview-hardware-test", p.stderr)

    def test_other_kernels_builds_are_not_named_as_waiting(self):
        p = run_selection([beta3("k6.18.42-hailo4.21.0-r47")],
                          "26.0.0-BETA.4", "6.18.50-production+truenas")
        self.assertNotIn("awaiting hardware-test", p.stderr)
        self.assertIn("k6.18.42-hailo4.21.0-r47", p.stderr)  # the release list

    def test_release_list_shows_approved_trains(self):
        p = run_selection([beta3("k6.18.42-hailo4.21.0-r47", trains=["26"])], *STABLE7)
        self.assertIn("k6.18.42-hailo4.21.0-r47 (" + K42 + ") (prerelease) "
                      "(approved for train 26)", p.stderr)


class ScriptsPurpose(unittest.TestCase):
    # Uninstall, --check and --help run only the release's scripts: the
    # build for this kernel when there is an approved one, else the newest
    # approved release BUILT FOR THIS TRAIN (notes header), whatever its
    # kernel. Never another train's release, even a grandfathered one: its
    # scripts target that train's install layout. Never an unapproved one.

    def test_prefers_the_build_for_this_kernel(self):
        rels = [stable7("v25.10.7-hailo4.21.0-r43", published="2026-01-01T00:00:00Z"),
                release("v25.10.5-hailo4.21.0-r40", "25.10.5",
                        kver="6.12.95-production+truenas", published="2026-02-01T00:00:00Z")]
        p = run_selection(rels, *STABLE7, purpose="scripts")
        self.assertEqual(p.stdout, "v25.10.7-hailo4.21.0-r43")

    def test_26_box_with_only_grandfathered_25_10_releases_refuses(self):
        # truenas1 before the grandfather markers: r40's --check probed the
        # old boot-pool copy and its restore.sh toggles /usr readonly.
        rels = [beta3("k6.18.42-hailo4.21.0-r47", published="2026-03-01T00:00:00Z"),
                release("v25.10.5-hailo4.21.0-r40", "25.10.5",
                        kver="6.12.95-production+truenas", published="2026-02-01T00:00:00Z"),
                release("v25.10.4-hailo4.21.0-r37", "25.10.4",
                        kver="6.12.91-production+truenas", published="2026-01-01T00:00:00Z")]
        p = run_selection(rels, *BETA3, purpose="scripts")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("awaiting hardware-test sign-off for train 26", p.stderr)
        self.assertIn("k6.18.42-hailo4.21.0-r47: https://github.com/", p.stderr)
        self.assertIn("use only a release built for train 26", p.stderr)
        self.assertIn("--release=TAG", p.stderr)
        self.assertNotIn("different TrueNAS train", p.stderr)

    def test_26_box_uses_a_26_approved_release_on_another_kernel(self):
        rels = [beta3("k6.18.42-hailo4.21.0-r47", published="2026-04-01T00:00:00Z"),
                release("v25.10.5-hailo4.21.0-r40", "25.10.5",
                        kver="6.12.95-production+truenas", published="2026-03-01T00:00:00Z"),
                release("v26.0.0-BETA.2-hailo4.21.0-r38", "26.0.0-BETA.2", "Halfmoon",
                        kver="6.18.23-production+truenas", prerelease=True, trains=["26"],
                        published="2026-02-01T00:00:00Z")]
        p = run_selection(rels, *BETA3, purpose="scripts")
        self.assertEqual(p.returncode, 0, p.stderr)
        # r40 is newer and grandfathered, but built for 25.10.
        self.assertEqual(p.stdout, "v26.0.0-BETA.2-hailo4.21.0-r38")

    def test_25_10_box_on_an_untested_kernel_is_unchanged(self):
        rels = [release("v25.10.5-hailo4.21.0-r40", "25.10.5",
                        kver="6.12.95-production+truenas", published="2026-02-01T00:00:00Z"),
                release("v25.10.4-hailo4.21.0-r37", "25.10.4",
                        kver="6.12.91-production+truenas", published="2026-01-01T00:00:00Z"),
                release("v25.04.2-hailo4.21.0-r41", "25.04.2", "Fangtooth",
                        kver="6.12.15-production+truenas", published="2026-03-01T00:00:00Z")]
        p = run_selection(rels, "25.10.9", "6.12.200-production+truenas", purpose="scripts")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v25.10.5-hailo4.21.0-r40")

    def test_release_without_a_notes_header_is_no_fallback(self):
        # same_train lets a header-less release through for a kernel match;
        # the scripts fallback needs the header to name this train.
        rel = release("k6.12.95-hailo4.21.0-r40", kver="6.12.95-production+truenas")
        rel["body"] = "| Target kernel | `6.12.95-production+truenas` |\n"
        p = run_selection([rel], *STABLE7, purpose="scripts")
        self.assertNotEqual(p.returncode, 0)

    def test_never_an_unapproved_release(self):
        p = run_selection([beta3("k6.18.42-hailo4.21.0-r47")], *BETA3, purpose="scripts")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def test_install_purpose_never_falls_back_to_another_kernel(self):
        rels = [stable7("v25.10.5-hailo4.21.0-r40")]
        p = run_selection(rels, *BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("--release=TAG", p.stderr)


class TrainKey(unittest.TestCase):
    CASES = {
        "25.10.7": "25.10", "25.10.4": "25.10", "25.04.2.6": "25.04",
        "25.10-RC.1": "25.10", "25.10.0-BETA.1": "25.10",
        "26.0.0-BETA.3": "26", "26.0.0-RC.1": "26", "26.0.0": "26",
        "26.1.0": "26", "26.1.2": "26", "27.0.0-RC.1": "27",
        "": None, "abc": None, "25": None, "25.": None, "x25.10": None,
        "26-BETA": None,
    }

    def test_bash_train_key(self):
        for version, want in self.CASES.items():
            self.assertEqual(train_key(version), want, version)

    def test_selection_train_key_matches_bash(self):
        # The selection keys the notes header with train_key and the box
        # with truenas_train_key: the two must agree or the guard misfires.
        src = re.search(r"^def train_key\(v\):\n(?:    .*\n)+", selection_snippet(), re.M).group(0)
        ns = {"re": re}
        exec(src, ns)
        for version, want in self.CASES.items():
            self.assertEqual(ns["train_key"](version) or None, want, version)


class SharedCopies(unittest.TestCase):
    def test_block_is_identical_in_get_sh_install_sh_and_uninstall_sh(self):
        block = shared_block(INSTALL_SH)
        self.assertEqual(shared_block(GET_SH), block)
        self.assertEqual(shared_block(UNINSTALL_SH), block)


class FetchAndSelect(unittest.TestCase):
    STUBS = """
midclt() {{ echo '{{"version": "{version}"}}'; }}
uname() {{ echo '{kver}'; }}
"""

    def test_fetch_loop_reads_every_page(self):
        # The shell loop asks for the next page only after a full one, and
        # the selection sees the releases of every page.
        with tempfile.TemporaryDirectory() as d:
            pages = [[stable7(f"k6.12.105-hailo4.21.0-r{n}", prerelease=True)
                      for n in range(200, 100, -1)],
                     [stable7("v25.10.7-hailo4.21.0-r43")]]
            for i, page in enumerate(pages, 1):
                Path(d, f"page{i}.json").write_text(json.dumps(page))
            stub = f"""
curl() {{
    local url="${{*: -1}}" n
    n="${{url##*page=}}"
    echo "$n" >> "{d}/calls"
    cat "{d}/page$n.json" 2>/dev/null || echo '[]'
}}
""" + self.STUBS.format(version="25.10.7", kver=K105) + "approved_release_tag install"
            p = run_block(stub)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), "v25.10.7-hailo4.21.0-r43")
            self.assertEqual(Path(d, "calls").read_text().split(), ["1", "2"])
            self.assertIn(f"Detected TrueNAS version: 25.10.7 (train 25.10, kernel: {K105})",
                          p.stderr)
            self.assertIn("Found release: v25.10.7-hailo4.21.0-r43", p.stderr)

    def test_api_failure_is_an_error_not_a_fallback(self):
        p = run_block("curl() { return 7; }\n"
                      + self.STUBS.format(version="26.0.0-BETA.3", kver=K42)
                      + "approved_release_tag install")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("Failed to query GitHub releases", p.stderr)

    def test_unreadable_version_is_an_error(self):
        p = run_block("midclt() { return 1; }\nsleep() { :; }\n"
                      "approved_release_tag install")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Failed to detect TrueNAS version", p.stderr)


class SnippetBashSafety(unittest.TestCase):
    def test_snippet_survives_double_quote_expansion(self):
        # The snippet lives inside a double-quoted bash string; bash rewrites
        # $..., backticks, and backslash-before-special before Python ever
        # runs. The extraction test runs the raw text, so any such character
        # would make production execute different code than the tests.
        snip = selection_snippet()
        self.assertNotIn("$", snip)
        self.assertNotIn('"', snip)
        self.assertNotIn(chr(96), snip)  # backtick
        for i, ch in enumerate(snip):
            if ch == "\\":
                self.assertNotIn(snip[i + 1], "$\"\\\n" + chr(96),
                                 f"bash-active backslash escape at offset {i}")


if __name__ == "__main__":
    unittest.main()
