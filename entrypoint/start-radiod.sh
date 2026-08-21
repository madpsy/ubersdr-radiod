#!/bin/bash
# Entrypoint for the UberSDR radiod container.
#
# Responsibilities, in order:
#   1. Seed the persistent config volume from the packaged template on first run
#   2. Migrate any legacy config in that volume to current ka9q-radio syntax
#   3. Enable multicast on the container's interfaces
#   4. Signal UberSDR that radiod has (re)started
#   5. Start the background helpers UberSDR's admin panel reads
#   6. exec radiod as PID 1
set -e

CONFIG_DIR=/etc/ka9q-radio
DEFAULT_CONFIG="$CONFIG_DIR/radiod@ubersdr.conf"
TEMPLATE_DIR=/usr/local/share/ka9q-radio/ubersdr
TRIGGER_DIR=/var/run/restart-trigger

# ---------------------------------------------------------------------------
# 1. Initialise the config volume from templates if it is empty
# ---------------------------------------------------------------------------
if [ ! -f "$DEFAULT_CONFIG" ]; then
    echo "Initializing config directory from templates..."
    mkdir -p "$CONFIG_DIR/examples"
    cp -r /usr/local/share/ka9q-radio/examples/* "$CONFIG_DIR/examples/" 2>/dev/null || true
    cp "$TEMPLATE_DIR/radiod@ubersdr.conf" "$DEFAULT_CONFIG"
    echo "Config directory initialized with default ubersdr configuration"
else
    echo "Using existing configuration from persistent volume"
fi

# ---------------------------------------------------------------------------
# 2. Config migration for current ka9q-radio.
#
# Rewrites values inside the .conf file only -- radiod itself is stock upstream.
# This runs on every start because /etc/ka9q-radio is a persistent volume: it is
# seeded from the template once and then never updated, so a deployment created
# before these changes still holds the old syntax and no user can be expected to
# know it moved.
#
#   blocktime  Changed from milliseconds to seconds.  A legacy "blocktime = 20"
#              reads as 20 SECONDS and asks for a ~1.3-billion-sample FFT block
#              at 64.8 Msps.  Any value >= 1 is therefore milliseconds and is
#              divided by 1000.  Idempotent: legal second-values (0.0025-0.12)
#              are < 1 and left alone, so re-running never re-scales.
#
#   calibrate  Removed from the rx888 driver, which now takes the corrected
#              reference frequency directly.  Converted, not deleted: a receiver
#              that has been calibrated holds a real value here.
#                  reference = 27e6 * (1 + calibrate)
#              Skipped with a warning if the config already sets 'reference',
#              since then the 27 MHz nominal assumption does not hold.
# ---------------------------------------------------------------------------
migrate_conf() {
    conf="$1"
    [ -f "$conf" ] || return 0
    tmp="${conf}.migrate.$$"

    has_ref=$(grep -cE '^[ \t]*reference[ \t]*=' "$conf" || true)

    awk -v has_ref="$has_ref" '
    /^[ \t]*blocktime[ \t]*=/ {
        line = $0; cmt = ""
        if (match(line, /[#;].*$/)) {
            cmt  = substr(line, RSTART)
            line = substr(line, 1, RSTART - 1)
        }
        val = substr(line, index(line, "=") + 1)
        gsub(/[ \t]/, "", val)
        if (val + 0 >= 1) {
            new = (val + 0) / 1000
            printf "blocktime = %g%s\n", new, (cmt == "" ? "" : "  " cmt)
            printf "  blocktime: %s ms -> %g s\n", val, new > "/dev/stderr"
            next
        }
    }
    /^[ \t]*calibrate[ \t]*=/ {
        line = $0
        if (match(line, /[#;].*$/)) line = substr(line, 1, RSTART - 1)
        val = substr(line, index(line, "=") + 1)
        gsub(/[ \t]/, "", val)
        if (has_ref + 0 > 0) {
            print $0
            print "  calibrate: NOT converted - config already sets reference; fix by hand" > "/dev/stderr"
            next
        }
        newref = 27000000 * (1 + (val + 0))
        printf "# migrated to reference for current ka9q-radio: %s\n", $0
        printf "reference = %.3f\n", newref
        printf "  calibrate %s -> reference %.3f Hz\n", val, newref > "/dev/stderr"
        next
    }
    { print }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 0; }

    if cmp -s "$conf" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    echo "MIGRATION: updating $conf for current ka9q-radio"
    [ -f "${conf}.pre-upstream" ] || cp "$conf" "${conf}.pre-upstream"
    # Copy contents rather than mv, to keep the inode intact for bind mounts
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    echo "MIGRATION: original saved as ${conf}.pre-upstream"
}

# radiod's config path arrives as an argument (see CMD); migrate any that exist
for arg in "$@"; do
    case "$arg" in
        -*) continue ;;
        *)  migrate_conf "$arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# 3. Multicast setup
# ---------------------------------------------------------------------------
if ip link show eth0 >/dev/null 2>&1; then
    echo "Enabling multicast on eth0..."
    ip link set eth0 multicast on || true
    ip link set eth0 allmulticast on || true
fi
ip link set lo multicast on || true

# ---------------------------------------------------------------------------
# 4. Record startup time and signal UberSDR
# ---------------------------------------------------------------------------
mkdir -p "$TRIGGER_DIR"
RADIOD_START_TIME=$(date +%s)
echo "$RADIOD_START_TIME" > "$TRIGGER_DIR/radiod-startup-time"
touch "$TRIGGER_DIR/restart-ubersdr"
echo "Radiod started at $RADIOD_START_TIME, signaling ubersdr"

# ---------------------------------------------------------------------------
# 5. Background helpers
#    - restart-watcher: UberSDR drops a trigger file to request a restart
#    - thread-stats:    per-thread CPU CSV that the admin panel reads
# ---------------------------------------------------------------------------
python3 /usr/local/lib/ubersdr-radiod/restart-watcher.py &
python3 /usr/local/lib/ubersdr-radiod/thread-stats.py &

# ---------------------------------------------------------------------------
# 6. Start radiod as PID 1
# ---------------------------------------------------------------------------
exec /usr/local/sbin/radiod "$@"
