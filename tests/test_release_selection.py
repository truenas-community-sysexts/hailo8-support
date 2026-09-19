"""Unit tests for the release-selection logic embedded in scripts/install.sh.

The Python between the BEGIN/END release-selection sentinels is extracted
verbatim and run as a subprocess with a canned GitHub releases JSON on
stdin, exactly how install.sh runs it."""
import json
import subprocess
import unittest
from pathlib import Path

from release_fixtures import release

INSTALL_SH = Path(__file__).resolve().parents[1] / "scripts" / "install.sh"
BUILD_YML = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "build.yml"


def selection_snippet():
    text = INSTALL_SH.read_text()
    begin = text.index("# BEGIN release-selection")
    end = text.index("# END release-selection")
    return text[begin:end]


def run_selection_raw(text, version, kver):
    return subprocess.run(
        ["python3", "-c", selection_snippet()],
        input=text, capture_output=True, text=True,
        env={"VERSION": version, "KVER": kver, "PATH": "/usr/bin:/bin"})


def run_selection(releases, version, kver):
    return run_selection_raw(json.dumps(releases), version, kver)


RELEASES = [
    release("v25.10.3-hailo4.21.0-r39", "25.10.3",
            kver="6.12.33-production+truenas"),
    release("v25.10.4-hailo4.21.0-r37", "25.10.4",
            kver="6.12.91-production+truenas"),
    release("v25.10.5-hailo4.21.0-r40", "25.10.5",
            kver="6.12.93-production+truenas", prerelease=True),
    release("v26.0.0-BETA.2-hailo4.21.0-r38", "26.0.0-BETA.2",
            kver="6.18.23-production+truenas", prerelease=True),
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
        # The prerelease flag can be mispublished (build.yml's mark_latest
        # dispatch path sets it false with no tag guard). The tag is the
        # second lock on the stable channel.
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

    def test_preview_box_gets_prerelease(self):
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
