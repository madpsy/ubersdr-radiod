#!/usr/bin/env bash
# Build the UberSDR radiod container from upstream ka9q-radio.
#
#   ./build.sh                        # both arches, pinned upstream, stays in cache
#   ./build.sh --amd64                # this arch only, loaded into the local docker
#   ./build.sh --ref main             # track upstream tip instead of the pin
#   ./build.sh --update               # move the pin to upstream tip, then build
#   ./build.sh --no-sync              # skip refreshing the local upstream/ checkout
#   ./build.sh --tag testing --push   # push madpsy/ka9q-radio:testing
#   ./build.sh --latest --push        # push :$(cat VERSION) AND move :latest to it
#
# Images publish to madpsy/ka9q-radio, the same repository the old fork used, so
# deployments pick a finished build up from :latest without editing compose on
# every instance.  That repository still holds fork-built images, so "latest" is
# opt-in: without --latest the tag is never written or moved, and a --tag testing
# push cannot disturb what running instances pull.
#
# --latest always publishes the VERSION file's number alongside it, so :latest is
# never a digest nobody can name: whatever it points at is also pullable as a
# fixed version, which is what a rollback needs.  Bump VERSION in the same commit
# as the change it ships.  Re-pushing an already published version is refused
# unless you pass --force-version.
#
# Moving :latest switches every instance to the upstream-based image on their
# next pull.  To roll back, retag the last fork build:
#   docker buildx imagetools create -t madpsy/ka9q-radio:latest madpsy/ka9q-radio:0.8.3
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-madpsy/ka9q-radio}"
PLATFORM="linux/amd64,linux/arm64"
TAGS=()
WANT_LATEST=0
FORCE_VERSION=0
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/ka9q/ka9q-radio.git}"
REF=""
PUSH=0
LOAD=0
NO_CACHE=""
UPDATE=0
SYNC=1

# Print the header comment block, stopping at the first line that is not a comment.
usage() {
    sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --amd64)     PLATFORM="linux/amd64"; LOAD=1 ;;
        --arm64)     PLATFORM="linux/arm64" ;;
        --ref)       REF="$2"; shift ;;
        --ref=*)     REF="${1#*=}" ;;
        --update)    UPDATE=1 ;;
        --push)      PUSH=1 ;;
        --no-cache)  NO_CACHE="--no-cache" ;;
        --no-sync)   SYNC=0 ;;
        --tag)       TAGS+=("$2"); shift ;;
        --tag=*)     TAGS+=("${1#*=}") ;;
        --latest)    WANT_LATEST=1 ;;
        --force-version) FORCE_VERSION=1 ;;
        -h|--help)   usage 0 ;;
        *)           echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

# --update moves the pin to whatever upstream main is right now, so the bump is
# an explicit, reviewable change to UPSTREAM_REF rather than a silent drift.
if [ "$UPDATE" -eq 1 ]; then
    echo "Resolving upstream main..."
    NEW_REF=$(git ls-remote "$UPSTREAM_REPO" refs/heads/main | cut -f1)
    [ -n "$NEW_REF" ] || { echo "could not resolve upstream main" >&2; exit 1; }
    OLD_REF=$(cat UPSTREAM_REF)
    if [ "$NEW_REF" = "$OLD_REF" ]; then
        echo "Already at upstream tip ($NEW_REF)"
    else
        echo "$NEW_REF" > UPSTREAM_REF
        echo "UPSTREAM_REF: $OLD_REF -> $NEW_REF"
        echo
        echo "Before shipping this, re-check the things that have bitten us before:"
        echo "  - config key units and names   (blocktime seconds, rx888 reference)"
        echo "  - presets.conf vs config/presets.conf"
        echo "  - src/Makefile EXECS list"
        echo "  - status.h enum status_type tag numbering"
        echo "  See UPSTREAM_RADIOD_MIGRATION.md in the ka9q_ubersdr repo."
        echo
    fi
fi

[ -n "$REF" ] || REF=$(cat UPSTREAM_REF)

# Keep the local reference checkout in step with what is about to be built, so
# "the code in the image" is always readable on disk.  Advisory only: the image
# build fetches its own copy, so a failure here (offline, local edits in
# upstream/) is worth a warning and nothing more.
if [ "$SYNC" -eq 1 ]; then
    ./sync-upstream.sh --ref "$REF" --quiet || \
        echo "warning: upstream/ is not in sync with $REF (see above)" >&2
fi

BUILD_ARGS=(--build-arg "UPSTREAM_REF=$REF" --build-arg "UPSTREAM_REPO=$UPSTREAM_REPO")

# A docker-container builder is required for multi-platform builds: the default
# "docker" driver can only produce the host architecture.  --bootstrap starts the
# BuildKit container up front, and current BuildKit images ship their own QEMU
# emulators -- so cross-building arm64 needs no binfmt_misc registration on the
# host and no privileged helper container.
BUILDER_NAME="${BUILDER_NAME:-ubersdr-radiod-builder}"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "Creating buildx builder: $BUILDER_NAME"
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap >/dev/null
fi

OUTPUT=()
if [ "$PUSH" -eq 1 ]; then
    OUTPUT=(--push)
elif [ "$LOAD" -eq 1 ]; then
    OUTPUT=(--load)
fi

# Assemble the tag list.  "latest" is never implied: it is added only by --latest,
# so an ordinary --tag push leaves the existing :latest manifest untouched.
# --latest also pulls in the VERSION file, so the two always move together.
if [ "$WANT_LATEST" -eq 1 ]; then
    VERSION=$(tr -d '[:space:]' < VERSION)
    case "$VERSION" in
        "")       echo "VERSION is empty; put the release number in it" >&2; exit 1 ;;
        latest)   echo "VERSION must be a release number, not \"latest\"" >&2; exit 1 ;;
        *[!A-Za-z0-9._-]*)
                  echo "VERSION \"$VERSION\" is not a usable docker tag" >&2; exit 1 ;;
    esac
    TAGS+=("$VERSION" "latest")
fi
[ "${#TAGS[@]}" -gt 0 ] || TAGS=("testing")

# Refuse an accidental "latest" typed as a plain tag; it has to be the flag, so
# that moving the tag everyone pulls is always a deliberate act.
for t in "${TAGS[@]}"; do
    if [ "$t" = "latest" ] && [ "$WANT_LATEST" -eq 0 ]; then
        echo "refusing --tag latest; use --latest to move it deliberately" >&2
        exit 1
    fi
done

# A published version number is a fixed point people roll back to, so overwriting
# one silently would make that point a lie.  Only a push can do damage here: a
# local build has nothing to clobber.
if [ "$PUSH" -eq 1 ] && [ "$WANT_LATEST" -eq 1 ] && [ "$FORCE_VERSION" -eq 0 ]; then
    if docker buildx imagetools inspect "$IMAGE:$VERSION" >/dev/null 2>&1; then
        echo "$IMAGE:$VERSION is already published." >&2
        echo "Bump VERSION for this release, or pass --force-version to overwrite it." >&2
        exit 1
    fi
fi

TAG_ARGS=()
for t in "${TAGS[@]}"; do
    TAG_ARGS+=(--tag "$IMAGE:$t")
done

echo "Building $IMAGE"
echo "  tags:      ${TAGS[*]}"
echo "  platforms: $PLATFORM"
echo "  upstream:  $REF"
if [ "$PUSH" -eq 1 ]; then
    if [ "$WANT_LATEST" -eq 1 ]; then
        echo "  NOTE:      :latest WILL be moved to this build, published as $VERSION."
        echo "             Every deployment pulling $IMAGE:latest switches to it."
        echo "             Roll back to the previous release with:"
        echo "               docker buildx imagetools create -t $IMAGE:latest $IMAGE:<previous version>"
    else
        echo "  :latest is not in the list and will not be touched"
    fi
fi
echo

# shellcheck disable=SC2086
docker buildx build \
    --builder "$BUILDER_NAME" \
    --platform "$PLATFORM" \
    "${BUILD_ARGS[@]}" \
    $NO_CACHE \
    "${TAG_ARGS[@]}" \
    "${OUTPUT[@]}" \
    .

echo
echo "Built $IMAGE (${TAGS[*]}) from ka9q-radio $REF"
if [ "$PUSH" -eq 0 ] && [ "$LOAD" -eq 0 ]; then
    echo "Note: neither --push nor a single-arch build, so the result stayed in the"
    echo "build cache. Use --amd64 to load locally, or --push to publish."
fi
