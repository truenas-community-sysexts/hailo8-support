"""Shared release fixture mirroring the body build.yml's notes template renders.

Both parsers of the release-notes format (install.sh's release selection and
gen-supported-versions.py) test against this one builder, so a template change
breaks both suites instead of silently orphaning one fixture.

`trains` appends one verified-train line per train, in the form promote.yml
writes when a hardware test on that train signs the build off;
test_notes_contract.py holds the fixture to what promote.yml actually writes.
"""


def marker(train):
    return f"<!-- verified-train: {train} -->"


def release(tag, version="", train="Goldeye", kver=None, prerelease=False,
            draft=False, published="2026-01-01T00:00:00Z", trains=()):
    body = (f"## Hailo-8 Sysext for TrueNAS SCALE {version} ({train})\n"
            "| Field | Value |\n| --- | --- |\n"
            "| HailoRT driver | `4.21.0` |\n")
    if kver:
        body += f"| Target kernel | `{kver}` |\n"
    for t in trains:
        body += f"\n\n{marker(t)}\n"
    return {"tag_name": tag, "body": body, "prerelease": prerelease,
            "draft": draft, "html_url": f"https://example.test/{tag}",
            "published_at": published}
