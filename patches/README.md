# Local patches

Any `*.patch` file here is applied to the upstream tree at build time with
`git apply`, in filename order. The directory is empty by design.

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

Deliberately dropped and not worth revisiting: the rx888 bias-T config keys, the
A/D data-gap counter, per-channel filter wait statistics, master block-gap
logging, and the `[Filter Stats]` thread. All diagnostics, all divergence.
