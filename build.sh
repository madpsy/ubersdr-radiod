#!/usr/bin/env bash
# Build the UberSDR radiod container from upstream ka9q-radio.
#
#   ./build.sh                      # both arches, pinned upstream, load/push per flags
#   ./build.sh --amd64              # this arch only, loaded into the local docker
#   ./build.sh --ref main           # track upstream tip instead of the pin
#   ./build.sh --update             # move the pin to upstream tip, then build
#   ./build.sh --push               # push the multi-arch manifest
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-ubersdr-radiod}"
TAG="${TAG:-latest}"
PLATFORM="linux/amd64,linux/arm64"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/ka9q/ka9q-radio.git}"
REF=""
PUSH=0
LOAD=0
NO_CACHE=""
UPDATE=0

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
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
        --tag)       TAG="$2"; shift ;;
        --tag=*)     TAG="${1#*=}" ;;
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

echo "Building $IMAGE:$TAG"
echo "  platforms: $PLATFORM"
echo "  upstream:  $REF"
echo

# shellcheck disable=SC2086
docker buildx build \
    --builder "$BUILDER_NAME" \
    --platform "$PLATFORM" \
    "${BUILD_ARGS[@]}" \
    $NO_CACHE \
    -t "$IMAGE:$TAG" \
    "${OUTPUT[@]}" \
    .

echo
echo "Built $IMAGE:$TAG from ka9q-radio $REF"
if [ "$PUSH" -eq 0 ] && [ "$LOAD" -eq 0 ]; then
    echo "Note: neither --push nor a single-arch build, so the result stayed in the"
    echo "build cache. Use --amd64 to load locally, or --push to publish."
fi
