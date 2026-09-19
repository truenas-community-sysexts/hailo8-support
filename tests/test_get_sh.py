"""End-to-end runs of get.sh and of uninstall.sh's curl|bash path, against
stub `midclt`, `uname` and `curl` commands on PATH.

The curl stub serves canned GitHub API pages and, for a release download,
writes a fake asset. A fake script prints which asset and release it is, the
arguments it got, the files beside it and the contents of any image it was
handed, so the tests see exactly what get.sh would run. The real installer
of this repo is also run on get.sh's argument form, to show it parses."""
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from release_fixtures import release

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install.sh"
UNINSTALL_SH = ROOT / "scripts" / "uninstall.sh"
REPO = "truenas-community-sysexts/hailo8-support"
FW_SHA = "2a" * 32

CURL_STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import hashlib, json, os, re, sys
    args = sys.argv[1:]
    url = next(a for a in args if a.startswith("https://"))
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write("curl " + url + "\\n")
    if "api.github.com" in url:
        page = int(re.search(r"[?&]page=(\\d+)", url).group(1))
        pages = json.load(open(os.environ["STUB_PAGES"]))
        print(json.dumps(pages[page - 1] if page <= len(pages) else []))
        sys.exit(0)
    if "/releases/download/" not in url:
        sys.exit(22)
    repo = url.split("https://github.com/")[1].split("/releases/download/")[0]
    tag, asset = url.split("/releases/download/")[1].split("/")
    if asset in os.environ.get("STUB_FAIL", "").split(","):
        sys.exit(22)
    image = f"hailo.raw of {repo} {tag}\\n"
    if asset == "hailo.raw":
        text = image
    elif asset == "hailo.raw.sha256":
        if os.environ.get("STUB_BADSUM"):
            image = "tampered\\n"
        text = hashlib.sha256(image.encode()).hexdigest() + "  hailo.raw\\n"
    elif asset == "firmware.sha256":
        text = os.environ.get("STUB_FW_SHA", "%s") + "\\n"
    elif asset.endswith(".sh"):
        text = ("#!/usr/bin/env bash\\n"
                f'echo "RAN {asset} from {tag} with: $*"\\n'
                'echo "REPO=$HAILO_REPO"\\n'
                'echo "BESIDE: $(cd "$(dirname "$0")" && ls | tr "\\\\n" " ")"\\n'
                'for a; do [ -f "$a" ] && echo "IMAGE: $(cat "$a")"; done\\n'
                'exit 0\\n')
    else:
        sys.exit(22)
    with open(args[args.index("-o") + 1], "w") as f:
        f.write(text)
    """) % FW_SHA

MIDCLT_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "midclt $*" >> "$STUB_LOG"
    [ -n "$STUB_VERSION" ] || exit 1
    echo "{\\"version\\": \\"$STUB_VERSION\\"}"
    """)

UNAME_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    [ "$1" = "-r" ] && { echo "$STUB_KVER"; exit 0; }
    exec /usr/bin/uname "$@"
    """)

SLEEP_STUB = "#!/usr/bin/env bash\nexit 0\n"

K42 = "6.18.42-production+truenas"
K95 = "6.12.95-production+truenas"
R47 = "k6.18.42-hailo4.21.0-r47"
R45 = "k6.18.42-hailo4.21.0-r45"
R40 = "v25.10.5-hailo4.21.0-r40"
R37 = "v25.10.4-hailo4.21.0-r37"


def releases(r47_trains=()):
    """Today's shape: two unapproved 26 preview builds, two grandfathered
    25.10 releases. r47_trains adds verified-train lines to r47."""
    return [
        release(R47, "26.0.0-BETA.3", "Halfmoon", kver=K42, prerelease=True,
                trains=r47_trains, published="2026-09-19T18:27:40Z"),
        release(R45, "26.0.0-BETA.3", "Halfmoon", kver=K42, prerelease=True,
                published="2026-09-19T00:40:28Z"),
        release(R40, "25.10.5", "Goldeye", kver=K95, published="2026-07-24T08:37:00Z"),
        release(R37, "25.10.4", "Goldeye", kver="6.12.91-production+truenas",
                published="2026-06-14T02:03:45Z"),
    ]


BETA3 = dict(version="26.0.0-BETA.3", kver=K42)
STABLE5 = dict(version="25.10.5", kver=K95)


class Stubbed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for name, text in (("curl", CURL_STUB), ("midclt", MIDCLT_STUB),
                           ("uname", UNAME_STUB), ("sleep", SLEEP_STUB)):
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        self.log = self.dir / "log"
        self.log.write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def env(self, version, kver, rels, **extra):
        pages = self.dir / "pages.json"
        pages.write_text(json.dumps([rels]))
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_LOG=str(self.log), STUB_PAGES=str(pages),
                   STUB_VERSION=version, STUB_KVER=kver, TMPDIR=str(self.dir))
        env.pop("HAILO_REPO", None)
        env.update(extra)
        return env

    def run_bash(self, args, version, kver, rels, stdin=None, cwd=None, **extra):
        return subprocess.run(["bash", *args], capture_output=True, text=True,
                              input=stdin, cwd=cwd,
                              env=self.env(version, kver, rels, **extra))

    def calls(self):
        return self.log.read_text().splitlines()

    def downloads(self):
        return [c.split("/releases/download/")[1] for c in self.calls()
                if "/releases/download/" in c]


class GetShBase(Stubbed):
    def get(self, *args, version=STABLE5["version"], kver=STABLE5["kver"],
            rels=None, **extra):
        return self.run_bash([str(GET_SH), *args], version, kver,
                             releases() if rels is None else rels, **extra)

    def ran(self, p):
        return p.stdout.splitlines()[0].rstrip() if p.stdout else ""


class Install(GetShBase):
    def assert_installed(self, p, tag, extra=""):
        self.assertEqual(p.returncode, 0, p.stderr)
        first = self.ran(p)
        prefix = f"RAN install.sh from {tag} with: "
        self.assertTrue(first.startswith(prefix + str(self.dir) + "/hailo-get."), first)
        self.assertTrue(first.endswith(f"/hailo.raw --firmware-version=4.21.0 "
                                       f"--expected-firmware-sha={FW_SHA}{extra}"), first)
        self.assertIn(f"IMAGE: hailo.raw of {REPO} {tag}", p.stdout)
        self.assertIn("hailo.raw: OK", p.stderr)
        self.assertEqual(self.downloads(), [f"{tag}/{a}" for a in
                                            ("install.sh", "hailo.raw",
                                             "hailo.raw.sha256", "firmware.sha256")])

    def test_stable_box_gets_the_grandfathered_build_for_its_kernel(self):
        p = self.get()
        self.assert_installed(p, R40)
        self.assertIn(f"Detected TrueNAS version: 25.10.5 (train 25.10, kernel: {K95})", p.stderr)
        self.assertIn(f"Found release: {R40}", p.stderr)

    def test_older_kernel_gets_its_own_build(self):
        p = self.get(version="25.10.4", kver="6.12.91-production+truenas")
        self.assert_installed(p, R37)

    def test_arguments_pass_through_after_the_image(self):
        p = self.get("--pool=fast", "--dry-run")
        self.assert_installed(p, R40, extra=" --pool=fast --dry-run")

    def test_beta_box_installs_nothing_unapproved(self):
        p = self.get(**BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.downloads(), [])
        self.assertIn(f"No preview (beta) release found for kernel {K42}", p.stderr)
        self.assertIn(f"{R47}: https://github.com/{REPO}/issues?q=", p.stderr)
        self.assertIn(f"{R45}: https://github.com/{REPO}/issues?q=", p.stderr)

    def test_beta_box_gets_the_newest_signed_off_build(self):
        p = self.get(rels=releases(r47_trains=["26"]), **BETA3)
        self.assert_installed(p, R47)

    def test_pinned_release_skips_selection(self):
        p = self.get(f"--release={R45}", **BETA3)
        self.assert_installed(p, R45)
        self.assertIn(f"Release {R45} (pinned with --release)", p.stderr)
        self.assertFalse(any(c.startswith("midclt") or "api.github.com" in c
                             for c in self.calls()), self.calls())

    def test_bad_checksum_stops_before_the_installer(self):
        p = self.get(STUB_BADSUM="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"checksum verification failed for hailo.raw from release {R40}",
                      p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_malformed_firmware_sha_stops(self):
        p = self.get(STUB_FW_SHA="not-a-sha")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"firmware.sha256 from release {R40} is not a 64-char hex sha256",
                      p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_tag_without_a_hailort_version_stops(self):
        p = self.get("--release=v1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("could not read the HailoRT version from release tag 'v1'", p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_failed_download_stops(self):
        p = self.get(STUB_FAIL="firmware.sha256")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"could not download firmware.sha256 from release {R40}", p.stderr)
        self.assertNotIn("RAN", p.stdout)

    def test_repo_flag_points_everything_at_the_fork(self):
        p = self.get("--repo=someone/fork")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("REPO=someone/fork", p.stdout)
        self.assertTrue(any("api.github.com/repos/someone/fork/releases" in c
                            for c in self.calls()))
        self.assertTrue(all("/someone/fork/releases/download/" in c
                            for c in self.calls() if "/releases/download/" in c))
        self.assertNotIn("--repo", self.ran(p))

    def test_default_repo_is_exported(self):
        self.assertIn(f"REPO={REPO}", self.get().stdout)

    def test_unreadable_truenas_version_is_an_error(self):
        p = self.get(version="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Failed to detect TrueNAS version", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_empty_release_flag_is_refused(self):
        self.assertEqual(self.get("--release=").returncode, 2)

    def test_temp_dir_is_removed(self):
        self.get()
        self.get("--uninstall")
        self.assertEqual(list(self.dir.glob("hailo-get.*")), [])


class ScriptsOnly(GetShBase):
    """Uninstall, --check, --help and the user's own image need only the
    release's scripts: the approved build for this kernel, or on an untested
    kernel the newest release approved for the train."""

    def test_check_runs_the_installers_probe_without_an_image(self):
        p = self.get("--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN install.sh from {R40} with: --check")
        self.assertEqual(self.downloads(), [f"{R40}/install.sh"])

    def test_check_on_an_untested_kernel_uses_newest_approved_for_the_train(self):
        p = self.get("--check", **BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN install.sh from {R40} with: --check")

    def test_help_is_passed_to_the_installer(self):
        p = self.get("--help")
        self.assertEqual(self.ran(p), f"RAN install.sh from {R40} with: --help")

    def test_uninstall_runs_the_releases_uninstaller_beside_its_restore(self):
        p = self.get("--uninstall", "--force", rels=releases(r47_trains=["26"]), **BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {R47} with: --force")
        self.assertIn("BESIDE: restore.sh uninstall.sh", p.stdout)
        self.assertEqual(self.downloads(), [f"{R47}/uninstall.sh", f"{R47}/restore.sh"])

    def test_uninstall_never_uses_an_unapproved_release(self):
        p = self.get("--uninstall", **BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {R40} with:")

    def test_pinned_uninstall(self):
        p = self.get("--uninstall", f"--release={R45}")
        self.assertEqual(self.ran(p), f"RAN uninstall.sh from {R45} with:")

    def test_users_own_image_is_left_alone(self):
        own = self.dir / "mine.raw"
        own.write_text("my image\n")
        p = self.get(str(own), "--firmware-version=4.21.0", f"--expected-firmware-sha={FW_SHA}")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ran(p), f"RAN install.sh from {R40} with: {own} "
                                      f"--firmware-version=4.21.0 --expected-firmware-sha={FW_SHA}")
        self.assertIn("IMAGE: my image", p.stdout)
        self.assertEqual(self.downloads(), [f"{R40}/install.sh"])


class UninstallStandalone(Stubbed):
    """uninstall.sh piped to bash has no restore.sh beside it: it fetches
    restore.sh from the release approved for the train."""

    def uninstall(self, version, kver, rels, **extra):
        # Run from an empty directory: $0 is "bash", so its "sibling"
        # restore.sh would be one in the current directory.
        cwd = self.dir / "cwd"
        cwd.mkdir(exist_ok=True)
        return self.run_bash(["-s", "--", "--force"], version, kver, rels,
                             stdin=UNINSTALL_SH.read_text(), cwd=cwd, **extra)

    def test_restore_comes_from_the_approved_release(self):
        p = self.uninstall(rels=releases(r47_trains=["26"]), **BETA3)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"RAN restore.sh from {R47} with: --force", p.stdout)
        self.assertEqual(self.downloads(), [f"{R47}/restore.sh"])
        self.assertNotIn("releases/latest", "\n".join(self.calls()))

    def test_no_approved_release_stops(self):
        rels = [release(R47, "26.0.0-BETA.3", "Halfmoon", kver=K42, prerelease=True)]
        p = self.uninstall(rels=rels, **BETA3)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.downloads(), [])

    def test_restore_download_failure_is_fatal(self):
        p = self.uninstall(rels=releases(), STUB_FAIL="restore.sh", **STABLE5)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(f"failed to download restore.sh from {REPO} release {R40}", p.stderr)
        self.assertNotIn("RAN", p.stdout)


@unittest.skipIf(os.geteuid() == 0, "install.sh stops at its root check only as non-root")
class RealInstallerParsesGetShArguments(unittest.TestCase):
    """install.sh parses every argument before its root check, so as a
    non-root user an accepted command line ends at that check (exit 1) and a
    rejected one at the parser (exit 2)."""

    def test_local_image_with_firmware_flags_and_user_flags(self):
        with tempfile.TemporaryDirectory() as d:
            image = Path(d, "hailo.raw")
            image.write_text("x")
            p = subprocess.run(["bash", str(INSTALL_SH), str(image),
                                "--firmware-version=4.21.0",
                                f"--expected-firmware-sha={FW_SHA}",
                                "--pool=fast", "--dry-run"],
                               capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn("must run as root", p.stderr)


if __name__ == "__main__":
    unittest.main()
