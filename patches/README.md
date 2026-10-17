# Local patches

Any `*.patch` file here is applied to the upstream tree at build time with
`git apply`, in filename order. The names of the patches an image was built with
are recorded in `/usr/local/share/ka9q-radio/APPLIED_PATCHES`, so a running
container can say what it carries.

## Currently applied

**`0003-capture-time-anchor.patch`** — tells receivers when each channel's
samples were captured. The RX888 USB callback estimates the `CLOCK_REALTIME` of
input sample 0 (floor of callback time minus sample time over a 10 s window;
the A/D is GPSDO-locked, so the rest follows from the sample count), and each
channel's status carries a pair: `CAPTURE_TS_REF` (240), the RTP timestamp of
the first frame of its latest block, and `CAPTURE_TIME_REF` (241), when that
frame's signal was captured, net of the channel filter's group delay (and of
WFM's composite filter, half a block) and of the
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

*Why not upstream's own timing fields?* Upstream already does a lot here, much
of it for HamSCI, and this patch builds on it. `INPUT_SAMPLES` is snapshotted
from a ring that runs alongside the FFT jobs, and together with `RTP_TIMESNAP`
it ties an RTP timestamp to an A/D sample. `capture_mark()` reads the same
sample index. The part we still need is the link from that sample to wall-clock
time. `GPS_TIME` is read when the status packet is built, so it also includes
the block fill, the FFT and the demod, plus scheduling jitter: about 20 ms late,
give or take a few ms. On a host disciplined only by NTP that hardly matters,
and upstream has sensibly not gone further yet. Our hosts take time from a
GPSDO/PPS, though, and ubersdr-ntp wants microseconds. So the patch estimates
the time from the lowest USB-callback delays, which strips out the jitter. It
also accounts for filter group delay and queued frames, and flags re-anchoring
with a generation counter. If upstream ever publishes a capture time for
`INPUT_SAMPLES` that has that jitter filtered out, most of this patch can go.

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

The FM squelch patch (now dropped, below) is the counter-example that shows
where the line sits: it went in only after establishing that neither config nor
UberSDR could reach the behaviour, because the decision is made inside radiod
before any stream exists -- and it came out as soon as upstream fixed it.

## Fixed upstream, dropped

Both landed upstream on 2026-10-16/17 and went with the bump to `486fca36`:

- **`0001-fm-always-open-squelch`** — `8e6dcbe5`/`75ac1b6d` clamp `fm.snr` to
  >= 0 on both estimator paths and stop replacing a zero threshold with the
  default. `-999` dB is `exp10f(-99.9)`, which underflows to exactly `0.0f`, so
  `snr >= open` always holds and our presets' sentinel works unpatched again.
  If upstream ever widens `squelch.open` back to double, `-999` becomes 1.3e-100
  and FM silently gates on noise: check `fm.c` and `radio.h` on every bump.
- **`0002-spectrum-bin-data-resize`** — `c5481fef` is the same fix, field name
  and all. UberSDR >= 0.1.62 still needs it; it is now in every upstream build.

Deliberately dropped and not worth revisiting: the rx888 bias-T config keys, the
A/D data-gap counter, per-channel filter wait statistics, master block-gap
logging, and the `[Filter Stats]` thread. All diagnostics, all divergence.
