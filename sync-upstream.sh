#!/usr/bin/env bash
# Keep a local, untracked checkout of the upstream ka9q-radio source at the exact
# commit this repo builds.
#
#   ./sync-upstream.sh              # put upstream/ at the pinned UPSTREAM_REF
#   ./sync-upstream.sh --ref main   # ...at upstream tip instead
#   ./sync-upstream.sh --quiet      # only speak up if something is wrong
#
# The image build fetches upstream itself, inside the Dockerfile, shallow and
# discarded afterwards.  That is right for the build and useless for reading: the
# code that went into the running container is not on disk anywhere.  This puts it
# there -- same repo, same ref -- so you can grep it, diff two bumps
# (git -C upstream log <old>..<new>), and check whether patches/ still applies.
#
# upstream/ is gitignored and never committed.  This repo stays a thin overlay on
# a pinned commit; UPSTREAM_REF is the source of truth, and the checkout is a
# local convenience that can be deleted and re-made at any time.
#
# The clone is full, not shallow, because history is the point: without it you
# cannot see what changed between two pins.
set -euo pipefail

cd "$(dirname "$0")"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/ka9q/ka9q-radio.git}"
UPSTREAM_DIR="${UPSTREAM_DIR:-upstream}"
REF=""
QUIET=0

usage() {
    sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)      REF="$2"; shift ;;
        --ref=*)    REF="${1#*=}" ;;
        --quiet|-q) QUIET=1 ;;
        -h|--help)  usage 0 ;;
        *)          echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -n "$REF" ] || REF=$(cat UPSTREAM_REF)

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

if [ ! -d "$UPSTREAM_DIR/.git" ]; then
    say "Cloning $UPSTREAM_REPO into $UPSTREAM_DIR/ (full history, one time)..."
    git clone -q "$UPSTREAM_REPO" "$UPSTREAM_DIR"
fi

# Never clobber local work.  This is a reference checkout, but people do end up
# editing it -- trying a patch, adding a printf -- and silently resetting that is
# worse than being out of date, which at least says so.
if [ -n "$(git -C "$UPSTREAM_DIR" status --porcelain)" ]; then
    echo "$UPSTREAM_DIR/ has uncommitted changes; leaving it alone." >&2
    echo "  currently at: $(git -C "$UPSTREAM_DIR" rev-parse --short HEAD)" >&2
    echo "  wanted:       $REF" >&2
    echo "  stash or discard them, then re-run to sync." >&2
    exit 1
fi

CURRENT=$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || echo "")

# A full SHA already in the object store needs no network: that is the pinned,
# unchanging case, and re-fetching it on every build would break offline builds
# for nothing.  Anything else -- a branch, a tag, a short SHA -- must be fetched,
# because a name that resolves locally is only as fresh as the last fetch, and
# `--ref main` silently building yesterday's tip is exactly the failure this
# script exists to prevent.
NEED_FETCH=1
case "$REF" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
        if [ "${#REF}" -eq 40 ] &&
           git -C "$UPSTREAM_DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null 2>&1; then
            NEED_FETCH=0
        fi
        ;;
esac

if [ "$NEED_FETCH" -eq 1 ]; then
    say "Fetching $REF from upstream..."
    git -C "$UPSTREAM_DIR" fetch -q --tags --prune origin || {
        echo "fetch failed; $UPSTREAM_DIR/ left at ${CURRENT:-nothing}" >&2
        exit 1
    }
fi

# Prefer origin/<ref> over a same-named local branch: the local one is a leftover
# from `git clone` that nothing updates, so resolving to it is how a stale build
# happens.  Falls through to the ref itself for SHAs and tags.
TARGET="$REF"
if git -C "$UPSTREAM_DIR" rev-parse -q --verify "origin/$REF^{commit}" >/dev/null 2>&1; then
    TARGET="origin/$REF"
elif ! git -C "$UPSTREAM_DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null 2>&1; then
    echo "upstream has no commit $REF" >&2
    exit 1
fi

# Detached on purpose: nothing here is ours to commit to, and a detached HEAD
# makes that obvious the moment you run git status in the directory.
git -C "$UPSTREAM_DIR" checkout -q --detach "$TARGET"

SHA=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
SUBJECT=$(git -C "$UPSTREAM_DIR" log -1 --format=%s)
DATE=$(git -C "$UPSTREAM_DIR" log -1 --format=%cs)

if [ "$SHA" = "$CURRENT" ]; then
    say "$UPSTREAM_DIR/ already at $SHA"
else
    say "$UPSTREAM_DIR/ now at $SHA"
fi
say "  $DATE  $SUBJECT"
