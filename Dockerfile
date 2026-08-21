# radiod container for UberSDR, built from unmodified upstream ka9q-radio.
#
# This repo is a build wrapper, not a fork.  Upstream source is fetched at build
# time at the ref in UPSTREAM_REF; the only things layered on top are our config
# files, the entrypoint, and anything dropped in patches/.

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Build dependencies, taken from upstream's own debian/control Build-Depends.
# libfobos-dev and libhydrasdr-dev are not packaged for Ubuntu 24.04, so those
# two drivers are disabled below rather than built.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      rsync \
      libairspy-dev \
      libairspyhf-dev \
      libbladerf-dev \
      libbsd-dev \
      libfftw3-dev \
      libhackrf-dev \
      libiniparser-dev \
      libncurses-dev \
      libogg-dev \
      libopus-dev \
      librtlsdr-dev \
      libsamplerate0-dev \
      libusb-1.0-0-dev \
      portaudio19-dev \
    && rm -rf /var/lib/apt/lists/*

# Which upstream to build.  Pinned by default for reproducible images; override
# with --build-arg UPSTREAM_REF=main to track the tip.  build.sh reads the
# default from the UPSTREAM_REF file at the repo root.
ARG UPSTREAM_REPO=https://github.com/ka9q/ka9q-radio.git
ARG UPSTREAM_REF=main

# Per-driver build switches, passed through to upstream's top-level Makefile.
# SDRPLAY is off upstream too (proprietary API).  FOBOS and HYDRASDR are off
# because Ubuntu 24.04 has no libfobos-dev / libhydrasdr-dev.
ARG ENABLE_AIRSPY=1
ARG ENABLE_AIRSPYHF=1
ARG ENABLE_BLADERF=1
ARG ENABLE_FOBOS=0
ARG ENABLE_FUNCUBE=1
ARG ENABLE_HACKRF=1
ARG ENABLE_HYDRASDR=0
ARG ENABLE_RTLSDR=1
ARG ENABLE_RX888=1
ARG ENABLE_SDRPLAY=0
ARG ENABLE_SIG_GEN=1

# init+fetch rather than `clone --branch`, because that only accepts a branch or
# tag name.  ka9q-radio publishes no tags -- releases are marked by commit
# message -- so UPSTREAM_REF is usually a commit SHA, and this form takes a SHA,
# branch or tag equally.
WORKDIR /build
RUN git init -q ka9q-radio \
 && git -C ka9q-radio remote add origin "${UPSTREAM_REPO}" \
 && git -C ka9q-radio fetch -q --depth 1 origin "${UPSTREAM_REF}" \
 && git -C ka9q-radio checkout -q FETCH_HEAD \
 && git -C ka9q-radio rev-parse HEAD > /build/UPSTREAM_SHA \
 && echo "Building ka9q-radio ${UPSTREAM_REF} ($(cat /build/UPSTREAM_SHA))"

# Local patches, applied in filename order.  Empty by default -- see patches/README.md.
COPY patches/ /build/patches/
RUN set -e; \
    for p in $(find /build/patches -maxdepth 1 -name '*.patch' | sort); do \
      echo "Applying $p"; \
      git -C /build/ka9q-radio apply --verbose "$p"; \
    done

WORKDIR /build/ka9q-radio

# DEB_BUILD_ARCH is upstream's "this is a package build, skip local-install side
# effects" switch.  Setting it skips setcap on monitor and two chown radio:radio
# steps -- all three are meaningless here (the container runs as root and has no
# radio user) and would otherwise need libcap2-bin and a created user.
ENV DEB_BUILD_ARCH=container

RUN make -C src -j"$(nproc)" \
      ENABLE_AIRSPY=${ENABLE_AIRSPY} ENABLE_AIRSPYHF=${ENABLE_AIRSPYHF} \
      ENABLE_BLADERF=${ENABLE_BLADERF} ENABLE_FOBOS=${ENABLE_FOBOS} \
      ENABLE_FUNCUBE=${ENABLE_FUNCUBE} ENABLE_HACKRF=${ENABLE_HACKRF} \
      ENABLE_HYDRASDR=${ENABLE_HYDRASDR} ENABLE_RTLSDR=${ENABLE_RTLSDR} \
      ENABLE_RX888=${ENABLE_RX888} ENABLE_SDRPLAY=${ENABLE_SDRPLAY} \
      ENABLE_SIG_GEN=${ENABLE_SIG_GEN}

# Install only what the container needs: binaries and driver plugins (src),
# presets.conf plus the rx888 FX3 firmware images (share), and upstream's
# example configs (config).  Skips service units, udev rules, man pages, cron
# jobs and the hfdl tree, none of which mean anything in a container.
# config/Makefile does not create /etc/radio, so do it first.
RUN mkdir -p /etc/radio \
 && make -C src install \
      ENABLE_AIRSPY=${ENABLE_AIRSPY} ENABLE_AIRSPYHF=${ENABLE_AIRSPYHF} \
      ENABLE_BLADERF=${ENABLE_BLADERF} ENABLE_FOBOS=${ENABLE_FOBOS} \
      ENABLE_FUNCUBE=${ENABLE_FUNCUBE} ENABLE_HACKRF=${ENABLE_HACKRF} \
      ENABLE_HYDRASDR=${ENABLE_HYDRASDR} ENABLE_RTLSDR=${ENABLE_RTLSDR} \
      ENABLE_RX888=${ENABLE_RX888} ENABLE_SDRPLAY=${ENABLE_SDRPLAY} \
      ENABLE_SIG_GEN=${ENABLE_SIG_GEN} \
 && make -C share install \
 && make -C config install

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libraries matching the drivers built above, plus:
#   avahi-utils  radiod shells out to avahi-publish/avahi-browse for mDNS
#                (it no longer links the Avahi library)
#   iproute2     the entrypoint enables multicast on the container interfaces
#   python3      background helpers (restart watcher, thread-stats writer)
RUN apt-get update && apt-get install -y --no-install-recommends \
      avahi-utils \
      ca-certificates \
      iproute2 \
      libairspy0 \
      libairspyhf1 \
      libbladerf2 \
      libbsd0 \
      libfftw3-single3 \
      libhackrf0 \
      libiniparser1 \
      libncurses6 \
      libogg0 \
      libopus0 \
      libportaudio2 \
      librtlsdr2 \
      libsamplerate0 \
      libusb-1.0-0 \
      python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the whole install prefix rather than naming individual binaries.  The set
# of executables upstream ships changes between releases -- `pl` was dropped and
# `ctcss`, `opussend` and `pcmsend` added -- and a per-binary COPY list turns
# each of those into a build failure.
COPY --from=builder /usr/local/ /usr/local/
COPY --from=builder /etc/radio/ /etc/radio/
COPY --from=builder /build/UPSTREAM_SHA /usr/local/share/ka9q-radio/UPSTREAM_SHA

RUN ldconfig \
 && ln -sf /usr/local/lib/ka9q-radio/*.so /usr/local/lib/ 2>/dev/null || true

# Our presets.conf goes to /etc/radio, which radiod's dist_path() checks BEFORE
# the packaged copy in /usr/local/share/ka9q-radio -- so this overrides upstream's
# without modifying it.
#
# Deliberately baked into the image rather than exposed in the config volume:
# UberSDR hardcodes values that must agree with these presets (sample rate per
# mode in config.go GetSampleRateForMode, AGC defaults, the always-open FM
# squelch), so an operator editing them breaks audio in ways that look like
# UberSDR bugs.  Change it here, in version control, and rebuild.
COPY config/presets.conf /etc/radio/presets.conf

# The radiod config template.  Seeded into the /etc/ka9q-radio volume on first
# run by the entrypoint, which is also where it can be edited afterwards.
COPY config/radiod@ubersdr.conf /usr/local/share/ka9q-radio/ubersdr/radiod@ubersdr.conf

COPY entrypoint/start-radiod.sh /usr/local/bin/start-radiod.sh
COPY entrypoint/restart-watcher.py /usr/local/lib/ubersdr-radiod/restart-watcher.py
COPY entrypoint/thread-stats.py /usr/local/lib/ubersdr-radiod/thread-stats.py
RUN chmod +x /usr/local/bin/start-radiod.sh

RUN mkdir -p /etc/ka9q-radio /var/lib/ka9q-radio /var/run/restart-trigger

WORKDIR /etc/ka9q-radio

# 5004/udp RTP audio, 5006/udp RTP status+control
EXPOSE 5004/udp 5006/udp

ENV TZ=UTC

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD pgrep radiod || exit 1

ENTRYPOINT ["/usr/local/bin/start-radiod.sh"]
CMD ["/etc/ka9q-radio/radiod@ubersdr.conf"]
