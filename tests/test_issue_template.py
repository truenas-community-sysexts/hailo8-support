"""Unit tests for the hardware-test issue build.yml opens for each build.

A human follows the issue body by hand, so every command in it must work as
written. The github-script block is extracted from build.yml and run under
node with a mocked GitHub client, exactly the code the workflow executes;
the rendered body is then checked against install.sh's flags, the assets
the release step uploads, and the markers promote.yml parses."""
import json
import os
import re
import subprocess
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_YML = ROOT / ".github" / "workflows" / "build.yml"
INSTALL_SH = ROOT / "scripts" / "install.sh"

STEP_NAME = "- name: Create hardware-test issue for auto-build"


def step_lines():
    lines = BUILD_YML.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == STEP_NAME)
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) <= indent),
               len(lines))
    return lines[start:end]


def issue_script():
    lines = step_lines()
    at = next(i for i, line in enumerate(lines) if line.strip() == "script: |")
    return textwrap.dedent("\n".join(lines[at + 1:]))


HARNESS = """
console.log = (...a) => process.stderr.write(a.join(' ') + '\\n');
const created = [];
const github = { rest: { issues: {
  createLabel: async () => ({}),
  listForRepo: async () => ({ data: [] }),
  create: async (args) => { created.push(args); },
} } };
const context = { repo: { owner: process.env.OWNER, repo: process.env.REPO } };
(async () => {
%s
})().then(() => process.stdout.write(JSON.stringify(created[0])),
          (e) => { process.stderr.write(String(e)); process.exit(1); });
"""


def render_issue(tag, version, train, kver, driver="4.21.0", preview=False,
                 owner="truenas-community-sysexts", repo="hailo8-support"):
    """The issues.create() arguments build.yml's step produces."""
    env = {**os.environ,
           "RELEASE_TAG": tag, "TRUENAS_VERSION": version, "TRAIN_NAME": train,
           "REAL_KVER": kver, "HAILO_DRIVER": driver,
           "IS_PREVIEW": "true" if preview else "false",
           "OWNER": owner, "REPO": repo}
    p = subprocess.run(["node", "-e", HARNESS % issue_script()],
                       capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise AssertionError(f"node failed: {p.stderr}")
    return json.loads(p.stdout)


def release_assets():
    """Basenames of the files the release step uploads."""
    text = BUILD_YML.read_text()
    block = text[text.index("body_path: release-notes.md"):]
    block = block[block.index("files: |") + len("files: |"):block.index("draft: true")]
    return {Path(line.strip()).name for line in block.splitlines() if line.strip()}


def install_flags():
    """Options install.sh's argument parser accepts."""
    return set(re.findall(r"^\s+(--[a-z-]+)(?:=\*)?\)", INSTALL_SH.read_text(), re.MULTILINE))


STABLE = dict(tag="k6.12.105-hailo4.21.0-r50", version="25.10.7", train="Goldeye",
              kver="6.12.105-production+truenas")
PREVIEW = dict(tag="k6.18.42-hailo4.21.0-r51", version="26.0.0-BETA.3", train="Halfmoon",
               kver="6.18.42-production+truenas", preview=True)


class Markers(unittest.TestCase):
    # promote.yml's patterns, verbatim.
    TAG_RE = re.compile(r"<!--\s*release-tag:\s*(\S+?)\s*-->")
    PREVIEW_RE = re.compile(r"<!--\s*preview-build:\s*(\S+?)\s*-->")

    def test_stable_markers(self):
        issue = render_issue(**STABLE)
        self.assertIn(f"<!-- release-tag: {STABLE['tag']} -->", issue["body"])
        self.assertIn("<!-- preview-build: false -->", issue["body"])
        self.assertEqual(self.TAG_RE.search(issue["body"]).group(1), STABLE["tag"])
        self.assertEqual(self.PREVIEW_RE.search(issue["body"]).group(1), "false")
        self.assertEqual(issue["labels"], ["hardware-test"])
        self.assertIn(STABLE["tag"], issue["title"])

    def test_preview_markers(self):
        issue = render_issue(**PREVIEW)
        self.assertEqual(self.TAG_RE.search(issue["body"]).group(1), PREVIEW["tag"])
        self.assertEqual(self.PREVIEW_RE.search(issue["body"]).group(1), "true")
        self.assertEqual(issue["labels"], ["preview-hardware-test"])
        self.assertIn(PREVIEW["tag"], issue["title"])

    def test_release_tag_env_matches_the_release_step(self):
        # The issue must name the tag the release step actually created.
        text = BUILD_YML.read_text()
        tag_name = re.search(r"^\s+tag_name: (.+)$", text, re.MULTILINE).group(1)
        env_tag = next(line.split(":", 1)[1].strip() for line in step_lines()
                       if line.strip().startswith("RELEASE_TAG:"))
        self.assertEqual(env_tag, tag_name)


class Commands(unittest.TestCase):
    def test_downloads_are_release_assets(self):
        body = render_issue(**STABLE)["body"]
        loop = re.search(r"^for f in (.+?); do curl .*\$BASE/\$f", body, re.MULTILINE)
        self.assertIsNotNone(loop, body)
        files = set(loop.group(1).split())
        self.assertIn("install.sh", files)
        self.assertIn("hailo.raw", files)
        self.assertLessEqual(files, release_assets())
        self.assertIn(f"BASE=https://github.com/truenas-community-sysexts/hailo8-support"
                      f"/releases/download/{STABLE['tag']}", body)

    def test_install_flags_exist(self):
        flags = install_flags()
        for params in (STABLE, PREVIEW):
            body = render_issue(**params)["body"]
            used = set(re.findall(r"(--[a-z][a-z-]*)", body))
            # Flags of commands other than install.sh.
            used -= {"--no-pager"}
            self.assertTrue(used, body)
            self.assertLessEqual(used, flags)

    def test_local_raw_install_passes_both_firmware_flags(self):
        body = render_issue(**STABLE)["body"]
        install = body[body.index("sudo bash install.sh ./hailo.raw"):]
        install = install[:install.index("```")]
        self.assertIn("--firmware-version=4.21.0", install)
        self.assertIn('--expected-firmware-sha="$(cat firmware.sha256)"', install)

    def test_kernel_precheck_names_the_target_kernel(self):
        for params in (STABLE, PREVIEW):
            body = render_issue(**params)["body"]
            self.assertRegex(body, rf"(?m)^uname -r +# must print {re.escape(params['kver'])}$")

    def test_verify_steps_explain_known_noise(self):
        # Installing over a build for another kernel: the previous boot's
        # PREINIT mismatch error shows as 1 fail until the step 4 reboot.
        # hailortcli cannot write the root-owned hailort.log the installer
        # left behind. Both notes must appear in both channels.
        for params in (STABLE, PREVIEW):
            body = render_issue(**params)["body"]
            step3 = body[body.index("### 3. Verify"):body.index("### 4. Reboot and re-verify")]
            step4 = body[body.index("### 4. Reboot and re-verify"):body.index("### 5. Report")]
            self.assertIn("Upgrading over an earlier build for a different kernel", step3)
            self.assertIn("`--check` here also shows 1 fail, `PREINIT logged an error this boot` "
                          "with a `Kernel version mismatch` message", step3)
            self.assertIn("clears after the reboot in step 4, where 0 fail is required", step3)
            self.assertIn('"No hailo-preinit entries this boot"', step3)
            for step in (step3, step4):
                self.assertIn("hailortcli fw-control identify", step)
                self.assertIn("`Cannot create log file hailort.log`", step)
        self.assertIn("PREINIT logged an error this boot", INSTALL_SH.read_text())
        self.assertIn("Kernel version mismatch",
                      (ROOT / "scripts" / "hailo-preinit.sh").read_text())

    def test_install_step_explains_same_kernel_insmod_skip(self):
        # Reinstalling on the running kernel with hailo_pci loaded: install.sh
        # skips insmod (which would fail with File exists) and says the new
        # module loads at the next reboot. The line quoted must be what
        # install.sh prints, and the old insmod noise must be gone.
        text = INSTALL_SH.read_text()
        for params in (STABLE, PREVIEW):
            body = render_issue(**params)["body"]
            step2 = body[body.index("### 2. Install this build"):body.index("### 3. Verify")]
            self.assertIn("Reinstalling on the same kernel while `hailo_pci` is loaded", step2)
            self.assertIn("this build's module loads at the reboot in step 4", step2)
            self.assertIn("If the earlier build had a different HailoRT version", step2)
            self.assertNotIn("File exists", step2)
            self.assertNotIn("WARNING: insmod", step2)
            quoted = re.findall(r"`(hailo_pci already loaded[^`]*)`", step2)
            self.assertEqual(len(quoted), 1, step2)
            for q in quoted:
                self.assertIn(q, text)

    def test_verify_step_explains_boot_pool_leftover(self):
        # An upgrade from the boot-pool-copy flow leaves the old copy under
        # /usr, which --check lists as informational. The line quoted must be
        # what install.sh prints.
        text = INSTALL_SH.read_text()
        for params in (STABLE, PREVIEW):
            body = render_issue(**params)["body"]
            step3 = body[body.index("### 3. Verify"):body.index("### 4. Reboot and re-verify")]
            self.assertIn("Upgrading from a release that copied the image to the boot pool", step3)
            self.assertIn("neither a warning nor a failure", step3)
            quoted = re.findall(r"`(Unused boot-pool copy [^`]+)`", step3)
            self.assertEqual(len(quoted), 1, step3)
            for q in quoted:
                self.assertIn(q, text)

    def test_sign_off_matches_the_channel(self):
        self.assertIn("promotes", render_issue(**STABLE)["body"])
        preview = render_issue(**PREVIEW)["body"]
        self.assertIn("never promoted", preview)
        self.assertNotIn("promotes", preview)


if __name__ == "__main__":
    unittest.main()
