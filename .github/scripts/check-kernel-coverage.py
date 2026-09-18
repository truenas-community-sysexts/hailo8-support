#!/usr/bin/env python3
"""Decide whether an existing release already covers a kernel.

Called by check-releases.yml when a new TrueNAS stable version appears.
Reads the repo's releases on stdin (gh api --paginate: one JSON array per
page, concatenated) and reports what covers the kernel in $NEW_KERNEL for
the driver in $CURRENT_DRIVER, scoped to $NEW_VERSION's TrueNAS train:

    promoted <tag>   served by install.sh's stable channel: no build needed,
                     the tracked version may advance.
    pending <tag>    unpromoted stable build awaiting hardware test: no
                     duplicate build, but the tracked version must NOT
                     advance (that consumes the one-shot version-changed
                     event, so deleting the build after a failed hardware
                     test would leave the kernel with no rebuild path).
    (nothing)        no coverage: build.

Preview (BETA/RC) builds never count: they never promote, so the stable
channel never serves them. A k-tag whose body lost the Target kernel row
counts only once promoted: unpromoted, it cannot be told apart from a
preview build, and the safe default is to build.

Rollout guard: coverage is only reported while the Latest release is
kernel-keyed ($LATEST_TAG starts with "k"). The one-line installer runs the
install.sh attached to Latest, and until a k-tagged build is promoted that
is the pre-migration installer, which matches exact TrueNAS versions only:
skipping a build would leave the new version with nothing it can serve. An
empty $LATEST_TAG (the lookup failed) counts as not kernel-keyed, so the
safe default is to build.

Matching rules mirror install.sh's release-selection snippet;
tests/test_kernel_coverage.py holds both to the shared fixtures.
"""
import json
import os
import re
import sys


def main():
    # gh api --paginate emits one JSON array per page, concatenated.
    decoder = json.JSONDecoder()
    text = sys.stdin.read()
    data = []
    pos = 0
    while pos < len(text):
        if text[pos].isspace():
            pos += 1
            continue
        doc, pos = decoder.raw_decode(text, pos)
        if isinstance(doc, list):
            data.extend(doc)

    kver = os.environ['NEW_KERNEL']
    short = kver.split('-')[0]
    driver = os.environ['CURRENT_DRIVER']
    version = os.environ.get('NEW_VERSION', '')
    latest = os.environ.get('LATEST_TAG', '')
    ker_re = re.compile(r'Target kernel\s*\|\s*`([^`]+)`')
    hdr_re = re.compile(r'for TrueNAS SCALE (\S+)')
    pre_re = re.compile(r'-(BETA|RC)', re.IGNORECASE)

    def train_key(v):
        return '.'.join(v.partition('-')[0].split('.')[:2])

    found = None
    pending = None
    for r in data:
        if r.get('draft'):
            continue
        tag = r.get('tag_name', '')
        body = r.get('body') or ''
        hdr = hdr_re.search(body)
        if pre_re.search(tag) or (hdr and pre_re.search(hdr.group(1))):
            continue
        # Mirror install.sh's same_train guard: a cross-train release is
        # never served, so it must not count as coverage. No header passes.
        if version and hdr and train_key(hdr.group(1)) != train_key(version):
            continue
        # Only builds of the current driver count: a driver bump must
        # rebuild every kernel (the dispatch condition handles that).
        if f'hailo{driver}-' not in tag:
            continue
        m = ker_re.search(body)
        tk = m.group(1) if m else ''
        promoted = not r.get('prerelease')
        # Body row is the primary key; the k-tag fallback needs promoted
        # (see module docstring).
        if tk == kver or (not tk and promoted
                          and tag.startswith(f'k{short}-hailo')):
            if promoted:
                found = ('promoted', tag)
                break
            if pending is None:
                pending = tag
    if found is None and pending:
        found = ('pending', pending)
    if found is None:
        return
    kind, tag = found
    # Rollout guard (see module docstring).
    if not latest.startswith('k'):
        print(f'NOTE: {tag} covers kernel {kver}, but the Latest'
              f' release ({latest or "lookup failed"}) is not kernel-keyed, so'
              ' the one-line installer cannot serve this version by kernel;'
              ' building.', file=sys.stderr)
        return
    print(f'{kind} {tag}')


if __name__ == '__main__':
    main()
