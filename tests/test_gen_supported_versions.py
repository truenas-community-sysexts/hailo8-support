"""Offline unit tests for .github/scripts/gen-supported-versions.py."""
import importlib.util
import json
import unittest
from pathlib import Path

from release_fixtures import release

SCRIPT = Path(__file__).resolve().parents[1] / ".github" / "scripts" / "gen-supported-versions.py"
spec = importlib.util.spec_from_file_location("gen_supported_versions", SCRIPT)
gsv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gsv)


KERNEL_MAP = {"trains": {"Goldeye": {
    "25.10.0": "6.12.33-production+truenas",
    "25.10.1": "6.12.33-production+truenas",
    "25.10.2": "6.12.33-production+truenas",
    "25.10.3": "6.12.33-production+truenas",
    "25.10.3.1": "6.12.33-production+truenas",
    "25.10.4": "6.12.91-production+truenas",
}}}


def rows_for(releases, kernel_map=KERNEL_MAP):
    parsed = gsv.parse_releases(releases)
    gsv.resolve_ktag_kernels(parsed, kernel_map)
    stable, preview = gsv.served_releases(parsed)
    return gsv.build_rows(stable, preview, kernel_map,
                          gsv.kernel_winners(parsed),
                          gsv.pending_builds(parsed))


class KernelRows(unittest.TestCase):
    def test_release_covers_whole_kernel_range(self):
        rows = rows_for([release("v25.10.3-hailo4.21.0-r39", "25.10.3",
                                 "Goldeye", "6.12.33-production+truenas")])
        row = [r for r in rows if r["kver"] == "6.12.33-production+truenas"][0]
        self.assertEqual(row["versions"], "25.10.0 - 25.10.3.1")
        self.assertEqual(row["tag"], "v25.10.3-hailo4.21.0-r39")
        self.assertEqual(row["driver"], "HailoRT 4.21.0")

    def test_unbuilt_kernel_gets_row(self):
        rows = rows_for([])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["tag"], "")
        self.assertEqual(row["versions"], "25.10.4")

    def test_unpromoted_stable_build_not_served(self):
        rows = rows_for([release("v25.10.4-hailo4.21.0-r40", "25.10.4",
                                 "Goldeye", "6.12.91-production+truenas",
                                 prerelease=True)])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["tag"], "")

    def test_unpromoted_stable_build_listed_as_pending(self):
        # The installer's error message tells the user a build exists and is
        # awaiting hardware-test promotion; the table must say the same, not
        # "not built yet".
        rows = rows_for([release("v25.10.4-hailo4.21.0-r40", "25.10.4",
                                 "Goldeye", "6.12.91-production+truenas",
                                 prerelease=True)])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["pending_tag"], "v25.10.4-hailo4.21.0-r40")

    def test_preview_build_is_not_pending_for_stable_kernel(self):
        # A BETA/RC build is the preview channel, never a stable build
        # awaiting promotion, so it must not fill a stable kernel's pending
        # slot even if a body ever recorded a stable kernel.
        rows = rows_for([release("v26.0.0-BETA.2-hailo4.21.0-r38",
                                 "26.0.0-BETA.2", "Halfmoon",
                                 "6.12.91-production+truenas",
                                 prerelease=True)])
        row = [r for r in rows if r["channel"] == "Stable"
               and r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["pending_tag"], "")

    def test_mispublished_preview_never_wins_stable_kernel_row(self):
        # A BETA/RC build published with prerelease=false (the mispublish
        # install.sh's preview locks defend against) must not become a stable
        # kernel row's release: install.sh never serves a preview build to
        # stable boxes, whatever kernel its body records.
        rows = rows_for([release("v26.0.0-BETA.2-hailo4.21.0-r38",
                                 "26.0.0-BETA.2", "Halfmoon",
                                 "6.12.91-production+truenas",
                                 prerelease=False)])
        row = [r for r in rows if r["channel"] == "Stable"
               and r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["tag"], "")

    def test_promoted_ktag_with_lost_body_fills_its_kernel_row(self):
        # install.sh serves a promoted k-tagged release by tag even when the
        # body lost its Target kernel row; the table must say the same
        # instead of "not built yet". The kernel map recovers the full
        # kernel string from the tag's short form.
        rel = dict(release("k6.12.91-hailo4.21.0-r50"), body="")
        rows = rows_for([rel])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["tag"], "k6.12.91-hailo4.21.0-r50")

    def test_unpromoted_ktag_with_lost_body_stays_off_the_table(self):
        # With the body gone an unpromoted k-tag cannot be told apart from a
        # preview build, so it must not fill the kernel row or its pending
        # slot (check-kernel-coverage.py applies the same rule).
        rel = dict(release("k6.12.91-hailo4.21.0-r50", prerelease=True),
                   body="")
        rows = rows_for([rel])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"][0]
        self.assertEqual(row["tag"], "")
        self.assertEqual(row["pending_tag"], "")

    def test_cross_train_release_does_not_fill_other_trains_kernel_row(self):
        # install.sh's train guard refuses cross-train matches, so a kernel
        # row only names releases from its own train.
        two_train_map = {"trains": {
            "Fangtooth": {"25.04.9": "6.12.91-production+truenas"},
            "Goldeye": {"25.10.4": "6.12.91-production+truenas"},
        }}
        rows = rows_for([release("v25.10.4-hailo4.21.0-r40", "25.10.4",
                                 "Goldeye", "6.12.91-production+truenas")],
                        kernel_map=two_train_map)
        ft = [r for r in rows if r["versions"] == "25.04.9"][0]
        gd = [r for r in rows if r["versions"] == "25.10.4"][0]
        self.assertEqual(gd["tag"], "v25.10.4-hailo4.21.0-r40")
        self.assertEqual(ft["tag"], "")

    def test_lost_body_ktag_fills_any_trains_row(self):
        # No header train passes the guard everywhere, same as install.sh.
        two_train_map = {"trains": {
            "Fangtooth": {"25.04.9": "6.12.91-production+truenas"},
            "Goldeye": {"25.10.4": "6.12.91-production+truenas"},
        }}
        rel = dict(release("k6.12.91-hailo4.21.0-r50"), body="")
        rows = rows_for([rel], kernel_map=two_train_map)
        for versions in ("25.04.9", "25.10.4"):
            row = [r for r in rows if r["versions"] == versions][0]
            self.assertEqual(row["tag"], "k6.12.91-hailo4.21.0-r50")

    def test_newest_kernel_row_first(self):
        rows = rows_for([])
        self.assertEqual(rows[0]["kver"], "6.12.91-production+truenas")

    def test_preview_release_row(self):
        rows = rows_for([release("v26.0.0-BETA.2-hailo4.21.0-r38",
                                 "26.0.0-BETA.2", "Halfmoon",
                                 "6.18.23-production+truenas", prerelease=True)])
        pr = [r for r in rows if r["channel"] == "Preview (beta)"]
        self.assertEqual(len(pr), 1)
        self.assertEqual(pr[0]["versions"], "26.0.0-BETA.2")
        self.assertEqual(pr[0]["tag"], "v26.0.0-BETA.2-hailo4.21.0-r38")

    def test_release_outside_map_keeps_own_row(self):
        rows = rows_for([release("v25.04.1-hailo4.20.0-r5", "25.04.1",
                                 "Fangtooth", "6.12.15-production+truenas")])
        own = [r for r in rows if r["versions"] == "25.04.1"]
        self.assertEqual(len(own), 1)

    def test_empty_map_still_lists_releases(self):
        rows = rows_for([release("v25.10.3-hailo4.21.0-r39", "25.10.3",
                                 "Goldeye", "6.12.33-production+truenas")],
                        kernel_map={})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["versions"], "25.10.3")

    def test_kernel_row_names_installer_winner_across_versions(self):
        # install.sh serves the newest promoted release advertising the
        # kernel, whichever version produced it; the row must name that
        # release, not the row versions' own build.
        rows = rows_for([
            release("v25.10.4-hailo4.21.0-r37", "25.10.4", "Goldeye",
                    "6.12.91-production+truenas",
                    published="2026-01-01T00:00:00Z"),
            release("v25.10.9-hailo4.21.0-r45", "25.10.9", "Goldeye",
                    "6.12.91-production+truenas",
                    published="2026-02-01T00:00:00Z"),
        ])
        row = [r for r in rows if r["kver"] == "6.12.91-production+truenas"
               and r["versions"] == "25.10.4"][0]
        self.assertEqual(row["tag"], "v25.10.9-hailo4.21.0-r45")

    def test_unmapped_version_row_names_installer_winner(self):
        rows = rows_for([
            release("v25.10.9-hailo4.21.0-r37", "25.10.9", "Goldeye",
                    "6.12.91-production+truenas",
                    published="2026-01-01T00:00:00Z"),
            release("v25.10.4-hailo4.21.0-r45", "25.10.4", "Goldeye",
                    "6.12.91-production+truenas",
                    published="2026-02-01T00:00:00Z"),
        ])
        own = [r for r in rows if r["versions"] == "25.10.9"][0]
        self.assertEqual(own["tag"], "v25.10.4-hailo4.21.0-r45")

    def test_legacy_release_keeps_own_row_not_kernel_row(self):
        # A promoted release without a Target kernel row is only installable
        # on its exact version via the fallback; it must not fill a kernel
        # row it cannot serve.
        rows = rows_for([release("v25.10.3-hailo4.21.0-r2", "25.10.3",
                                 "Goldeye", None)])
        kernel_row = [r for r in rows
                      if r["kver"] == "6.12.33-production+truenas"][0]
        self.assertEqual(kernel_row["tag"], "")
        own = [r for r in rows if r["versions"] == "25.10.3" and not r["kver"]]
        self.assertEqual(len(own), 1)
        self.assertEqual(own[0]["tag"], "v25.10.3-hailo4.21.0-r2")


class RenderTable(unittest.TestCase):
    def test_not_built_yet_cell(self):
        lines = gsv.render_table(rows_for([]))
        self.assertTrue(any("_not built yet_" in line for line in lines))

    def test_pending_build_cell_names_release_not_not_built(self):
        lines = gsv.render_table(rows_for(
            [release("v25.10.4-hailo4.21.0-r40", "25.10.4", "Goldeye",
                     "6.12.91-production+truenas", prerelease=True)]))
        line = [ln for ln in lines if "6.12.91" in ln][0]
        self.assertIn("v25.10.4-hailo4.21.0-r40", line)
        self.assertIn("awaiting hardware-test promotion", line)
        self.assertNotIn("not built yet", line)

    def test_version_range_helper(self):
        self.assertEqual(gsv.version_range(["25.10.0"]), "25.10.0")
        self.assertEqual(gsv.version_range(["25.10.3.1", "25.10.0", "25.10.2"]),
                         "25.10.0 - 25.10.3.1")


class ReadReleases(unittest.TestCase):
    def test_concatenated_pages_are_merged(self):
        text = json.dumps([{"a": 1}]) + "\n" + json.dumps([{"b": 2}]) + "\n"
        self.assertEqual(gsv.read_releases(text), [{"a": 1}, {"b": 2}])

    def test_api_error_object_aborts(self):
        with self.assertRaises(SystemExit):
            gsv.read_releases(json.dumps({"message": "rate limited"}))


if __name__ == "__main__":
    unittest.main()
