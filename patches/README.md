# Local patches

Any `*.patch` file here is applied to the upstream tree at build time with
`git apply`, in filename order. The names of the patches an image was built with
are recorded in `/usr/local/share/ka9q-radio/APPLIED_PATCHES`, so a running
container can say what it carries.

## Currently applied

**`0001-fm-always-open-squelch.patch`** — restores the "always open" FM squelch.
ka9q-radio used to map `squelch-open <= -999` to exactly `0.0` and skip the
squelch when both thresholds were zero; both halves were removed, so `-999` now
just means `dB2power(-999)` = 1.26e-100. That is not the same thing, because
`chan->fm.snr` can be zero or negative while `dB2power()` is always positive —
so no threshold keeps the gate open on a noise-only channel, and radiod emits no
RTP at all. UberSDR gates audio itself and needs everything passed through.
Drop this if upstream reinstates an explicit way to disable the FM squelch.

**`0002-spectrum-bin-data-resize.patch`** — lets a spectrum channel's bin count
grow. `demod_spectrum()` compares `chan->spectrum.bin_count` against a local that
the reinitialisation block has already synced to it, so only the "buffer is NULL"
arm of the guard can ever fire: `bin_data` is allocated once, at the bin count the
channel was created with, while the polls memset and fill `bin_count` elements of
it. Raising a live channel's BIN_COUNT therefore writes past the end of the block
and glibc aborts with "corrupted size vs. prev_size in fastbins". Tracks the
allocated length in a new field instead. UberSDR used to route around it by
creating each channel at the largest bin count it would ever need, but bins are
float32 on the wire, so that made every channel carry its deepest zoom's payload
at every zoom. With the guard fixed, bin_count follows the view — which is what
lets the WebSDR emulation reach radiod's cheap narrowband path at the two zooms
that previously sat on the expensive one. **UberSDR ≥ 0.1.62 assumes this patch
is present**; the two images are pushed together. Drop it if upstream fixes the
guard; it is worth sending them.

**`0003-capture-time-anchor.patch`** — tells receivers when each channel's
samples were captured. The RX888 USB callback estimates the `CLOCK_REALTIME` of
input sample 0 (floor of callback time minus sample time over a 10 s window;
the A/D is GPSDO-locked, so the rest follows from the sample count), and each
channel's status carries a pair: `CAPTURE_TS_REF` (240), the RTP timestamp of
the first frame of its latest block, and `CAPTURE_TIME_REF` (241), when that
frame's signal was captured, net of the channel filter's group delay and of the
RX888's own latency (`RX888_CAPTURE_LATENCY_NS` in `rx888.c`, 0 until measured).
`CAPTURE_GENERATION` (242) bumps whenever the anchor is re-established (lost
transfer, clock step). One pair gives every packet its capture time:
`TIME_REF + (int32)(ts − TS_REF) / rate`. The tags are numbered from the top of
the byte, in their own enum, so upstream appending tags can't collide with them;
receivers that don't know them skip them. Only radiod can do this: UberSDR only
sees packets after the 20 ms block fill and all of radiod's processing. **UberSDR
uses the pair when present** and falls back to packet arrival time without it,
so either image works with either version. Drop it if upstream grows an
equivalent; worth offering.

**The point of this repo is that we no longer maintain a fork.** Every patch
added here is a divergence that has to be rebased by hand on each upstream bump,
and a silent way for our build to drift from what upstream tests. Prefer, in
order:

1. Change our config or entrypoint instead.
2. Change UberSDR instead.
3. Send it upstream and pin `UPSTREAM_REF` past the merge.
4. Only then, a patch here.

If you do add one, name it `NNNN-short-description.patch` and say at the top of
the file what it does, why config or UberSDR could not, and what would let us
drop it.

## Known candidates, deliberately not applied

Carried in the old fork, judged not worth the divergence:

| Patch | Trigger for reconsidering |
|---|---|
| rx888 firmware load `sleep(1)` → `sleep(2)` | rx888 fails to enumerate on a Pi 5. The RP1 USB controller re-enumerates slower than the Pi 4's. |
| `cwsl_websdr.c` front end driver | You actually deploy the CWSL WebSDR network source. This is a whole new file, not a patch — it would need adding to `src/Makefile` too. |
| `is_poll_only()` in `radio_status.c` | Only if UberSDR's own fix proves insufficient: UberSDR now carries `LIFETIME` in its spectrum polls, so a channel accidentally created by a poll reaps itself. |

The FM squelch patch above is the counter-example that shows where the line
sits: it went in only after establishing that neither config nor UberSDR could
reach the behaviour, because the decision is made inside radiod before any
stream exists.

Deliberately dropped and not worth revisiting: the rx888 bias-T config keys, the
A/D data-gap counter, per-channel filter wait statistics, master block-gap
logging, and the `[Filter Stats]` thread. All diagnostics, all divergence.
