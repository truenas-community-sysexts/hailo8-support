#!/usr/bin/env python3
"""Maintain .github/kernel-map.json: TrueNAS version -> kernel (uname -r).

A sysext build is keyed to the exact kernel string, and many TrueNAS point
releases ship the same kernel. This script records which version ships which
kernel by reading each release's rootfs.mtree manifest on
download.truenas.com (a small text file; no ISO download involved).

The kernel of a published release never changes, so the JSON file doubles as
a cache: only versions not already mapped are fetched. Versions whose mtree
is missing (it happens: 25.10.4.1 shipped without one) are recorded under
"unresolved" and retried on the next run.

Preview (BETA/RC) versions are not covered here: iso.sys.truenas.net
publishes no mtree. Their kernel comes from this repo's own release notes
via gen-supported-versions.py.

Usage:
    gen-kernel-map.py [.github/kernel-map.json]
"""
import json
import re
import sys
import urllib.request

# Trains are discovered from the download.truenas.com root listing, so a
# train rollover needs no edit here. Scope is 25.04 onward (org discussion
# #9): older trains list no in-scope versions and are skipped.
ROOT = "https://download.truenas.com/"
BASE = ROOT + "TrueNAS-SCALE-{train}/"
MIN_VERSION = (25, 4)
# Trailing slash optional: the top-level index links some trains without one.
TRAIN_DIR_RE = re.compile(r'href="\.?/?TrueNAS-SCALE-([A-Za-z]+)[/"]')
VERSION_DIR_RE = re.compile(r'href="\.?/?(\d+(?:\.\d+){1,4})/')
KVER_RE = re.compile(r"usr/lib/modules/([0-9][^/\s]*production[^/\s]*)")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "sysext-kernel-map"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def discover_trains(fetch=fetch):
    """Train names listed on download.truenas.com, e.g. ['Fangtooth',
    'Goldeye']."""
    html = fetch(ROOT)
    return sorted(set(TRAIN_DIR_RE.findall(html)))


def in_scope(version):
    return tuple(int(p) for p in version.split(".")[:2]) >= MIN_VERSION


def list_versions(train, fetch=fetch):
    """In-scope version directories listed for a train, e.g. ['25.10.0']."""
    html = fetch(BASE.format(train=train))
    return sorted(v for v in set(VERSION_DIR_RE.findall(html)) if in_scope(v))


def resolve_kernel(train, version, fetch=fetch):
    """Kernel string for one version, or None if mtree is missing or has no
    kernel path."""
    try:
        mtree = fetch(BASE.format(train=train) + version + "/rootfs.mtree")
    except Exception as e:
        print(f"  {train} {version}: no rootfs.mtree ({e})", file=sys.stderr)
        return None
    m = KVER_RE.search(mtree)
    if not m:
        print(f"  {train} {version}: rootfs.mtree has no kernel path", file=sys.stderr)
    return m.group(1) if m else None


def update_map(data, fetch=fetch):
    """Add kernels for any versions not yet mapped. Mutates and returns data."""
    trains = data.setdefault("trains", {})
    unresolved = data.setdefault("unresolved", {})
    try:
        names = discover_trains(fetch=fetch)
    except Exception as e:
        print(f"WARNING: could not list trains ({e}); using cached trains",
              file=sys.stderr)
        names = sorted(trains)
    if not names:
        # An empty listing (format change, maintenance page) must not freeze
        # the map silently; fall back like the fetch-failure path.
        print("WARNING: no trains found in the root listing; using cached "
              "trains", file=sys.stderr)
        names = sorted(trains)
    for train in names:
        try:
            versions = list_versions(train, fetch=fetch)
        except Exception as e:
            # Keep the cached entries usable when the listing is unreachable.
            print(f"WARNING: could not list {train} versions ({e}); "
                  "keeping cached entries", file=sys.stderr)
            continue
        if not versions and train not in trains:
            continue  # pre-25.04 train, out of scope
        known = trains.setdefault(train, {})
        missing = []
        for version in versions:
            if version in known:
                continue
            kver = resolve_kernel(train, version, fetch=fetch)
            if kver:
                print(f"  {train} {version} -> {kver}", file=sys.stderr)
                known[version] = kver
            else:
                missing.append(version)
        if missing:
            unresolved[train] = missing
        else:
            unresolved.pop(train, None)
    return data


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ".github/kernel-map.json"
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    before = json.dumps(data, sort_keys=True)
    update_map(data)
    if json.dumps(data, sort_keys=True) == before:
        print(f"{path}: kernel map unchanged")
        return
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{path}: kernel map updated")


if __name__ == "__main__":
    main()
