#!/usr/bin/env python3
"""Find the newest TrueNAS preview (BETA/RC) release on iso.sys.truenas.net.

check-releases.yml calls this to decide whether the preview build moves on.
Preview ISOs live in one directory per channel, and the directory changes as
a release moves through its stages: 26.0.0-BETA.3 was under TrueNAS-26-BETA/,
27.0.0-RC.1 (TrueNAS 26 renamed to 27) is under TrueNAS-27-RC/. Watching only
the tracked channel misses every such move, so this reads two listings:

  --root-listing     the server's root index. It names every published file
                     as CHANNEL/VERSION/FILE, so it shows all channels at
                     once. Only versions whose ISO is listed count.
  --channel-listing  the tracked channel's own listing (./VERSION/ hrefs),
                     which is what this check read before. It keeps working
                     if the root index ever goes away or changes shape.

Either file may be empty or missing (its fetch failed). The output is
key=value lines for $GITHUB_OUTPUT:

  version=27.0.0-RC.1
  channel_url=https://iso.sys.truenas.net/TrueNAS-27-RC/
  higher=true

higher is true when version sorts above --current. Nothing is printed when
neither listing holds a preview version.
"""
import argparse
import re
import sys
from urllib.parse import urlsplit

VERSION = r"\d+(?:\.\d+){1,3}-(?:BETA|RC)\.\d+"
# A channel directory: TrueNAS-26-BETA, TrueNAS-27-RC. Nightlies
# (TrueNAS-27-Nightlies, MASTER builds) never match.
CHANNEL = r"TrueNAS-\d+(?:\.\d+)?-(?:BETA|RC)"
# Root index href: TrueNAS-27-RC/27.0.0-RC.1/TrueNAS-27.0.0-RC.1.iso. The
# file must be the ISO of the same version, so a listed directory whose ISO
# has not been uploaded yet does not count.
ROOT_ISO_RE = re.compile(
    r"""href=["']/?(?P<channel>""" + CHANNEL + r""")/(?P<version>""" + VERSION
    + r""")/TrueNAS-(?P=version)\.iso["'?]""")
# Channel listing href: ./26.0.0-BETA.2/?wrap=1. The whole ./VERSION/
# segment must match, so a suffix of a longer version (26.0.0.1-BETA.1) is
# never taken on its own.
CHANNEL_DIR_RE = re.compile(r"\./(" + VERSION + r")/")


def sort_key(v):
    """Numeric base first, then channel rank (BETA < RC < final), then the
    pre-release number. The same ranking as gen-supported-versions.py's
    truenas_sort_key."""
    base, _, pre = v.partition("-")
    nums = [int(x) for x in base.split(".")]
    nums += [0] * (4 - len(nums))
    typ, _, num = pre.partition(".")
    rank = 3 if not pre else {"BETA": 0, "RC": 1}.get(typ.upper(), 2)
    return (nums, rank, int(num) if num.isdigit() else 0)


def root_of(url):
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}/"


def candidates(root_text, root_url, channel_text, channel_url):
    """(version, channel_url) for every preview version either listing shows."""
    found = set()
    for m in ROOT_ISO_RE.finditer(root_text):
        found.add((m.group("version"), f"{root_url}{m.group('channel')}/"))
    for m in CHANNEL_DIR_RE.finditer(channel_text):
        found.add((m.group(1), channel_url))
    return found


def latest(found, channel_url):
    """The highest version and the channel that lists it. When several
    channels list that version, the tracked one wins."""
    if not found:
        return None
    version = max((v for v, _ in found), key=sort_key)
    urls = sorted(c for v, c in found if v == version)
    return version, (channel_url if channel_url in urls else urls[0])


def read(path):
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--channel-url", required=True,
                    help="tracked truenas_preview.channel_url")
    ap.add_argument("--root-listing", default="")
    ap.add_argument("--channel-listing", default="")
    ap.add_argument("--current", default="",
                    help="tracked truenas_preview.version")
    args = ap.parse_args(argv)

    channel_url = args.channel_url
    if not channel_url.endswith("/"):
        channel_url += "/"
    found = candidates(read(args.root_listing), root_of(channel_url),
                       read(args.channel_listing), channel_url)
    best = latest(found, channel_url)
    if best is None:
        return 0
    version, url = best
    higher = (not args.current
              or sort_key(version) > sort_key(args.current))
    print(f"version={version}")
    print(f"channel_url={url}")
    print(f"higher={'true' if higher else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
