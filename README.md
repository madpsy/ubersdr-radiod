# ubersdr-radiod

Container build for [ka9q-radio](https://github.com/ka9q/ka9q-radio)'s `radiod`,
as UberSDR uses it.

**This is a build wrapper, not a fork.** Upstream source is fetched at build time
and compiled unmodified. What this repo adds is the container, our configuration,
and the entrypoint. It replaces the old `madpsy/ka9q-radio` fork, whose local
changes have either been absorbed upstream or moved into UberSDR itself.

## Layout

```
UPSTREAM_REF                  upstream commit this image is pinned to
Dockerfile                    two-stage build: fetch + compile, then a slim runtime
build.sh                      buildx wrapper (multi-arch, pin management)
config/radiod@ubersdr.conf    seeded into the config volume on first run
config/presets.conf           baked to /etc/radio/presets.conf, overrides upstream's
entrypoint/start-radiod.sh    config migration, multicast setup, then exec radiod
entrypoint/*.py              background helpers the UberSDR admin panel reads
patches/                      empty by design; see patches/README.md
```

## Build

```sh
./build.sh --amd64            # local single-arch build, loaded into docker
./build.sh                    # amd64 + arm64
./build.sh --push             # publish the multi-arch manifest
```

`docker-compose.yml` in the UberSDR repo should point its radiod service at this
directory as the build context.

## Upstream version

`UPSTREAM_REF` pins the exact commit built. It is a commit SHA rather than a tag
because ka9q-radio publishes no tags — releases are marked by commit message.

```sh
./build.sh --ref main         # one-off build against upstream tip
./build.sh --update           # move the pin to tip and build
```

Pinning is deliberate. Upstream moves quickly and has made changes that break us
silently rather than loudly — `blocktime` switched from milliseconds to seconds,
the rx888 `calibrate` key was replaced by `reference`, the `pl` binary was
dropped. A floating build turns any of those into a mystery outage. `--update`
prints the checklist worth walking before shipping a bump.

## What the entrypoint does

1. Seeds `/etc/ka9q-radio` from the packaged template on first run.
2. **Migrates legacy config in place.** That directory is a persistent volume:
   seeded once, never updated, so an existing deployment still holds old syntax
   and no operator can be expected to know it moved. Handled automatically:
   - `blocktime` in milliseconds → seconds (any value ≥ 1 is divided by 1000;
     idempotent, since legal second-values are all < 1)
   - rx888 `calibrate` → `reference = 27e6 × (1 + calibrate)`, preserving a
     calibrated receiver's correction rather than silently discarding it
   The original is kept once as `<config>.pre-upstream`, and every change is
   logged with a `MIGRATION:` prefix.
3. Enables multicast on `eth0` and `lo`.
4. Signals UberSDR that radiod has restarted.
5. Starts the restart watcher and the per-thread CPU stats writer.
6. `exec`s radiod as PID 1.

## Configuration

**`config/radiod@ubersdr.conf`** is a template. It is copied into the config
volume on first run and is editable after that, including through the UberSDR
admin panel.

**`config/presets.conf`** is not. It is baked to `/etc/radio/presets.conf`, which
radiod's `dist_path()` checks before its own packaged copy — so it overrides
upstream without modifying it.

It is kept out of the volume on purpose. UberSDR hardcodes values that must agree
with these presets: sample rate per mode (`GetSampleRateForMode` in `config.go`),
the AGC defaults, and the always-open FM squelch that lets UberSDR gate audio
itself. An operator editing presets breaks audio in ways that look like UberSDR
bugs. Change it here, in version control, and rebuild.

Upstream's own `presets.conf` differs from ours in ways that matter — its `am`
and `sam` run at 12k where UberSDR expects 24k, its FM presets omit the
always-open squelch, and it has none of the wide `iq48`/`iq96`/`iq192`/`iq384`
modes. Ours is the authority; diff the two on each upstream bump.

## Drivers

Built as `.so` plugins, selected by `ENABLE_*` build args. airspy, airspyhf,
bladerf, funcube, hackrf, rtlsdr, rx888 and sig_gen are on. `fobos` and
`hydrasdr` are off because Ubuntu 24.04 packages no `libfobos-dev` or
`libhydrasdr-dev`; `sdrplay` is off upstream too, for its proprietary API.

```sh
docker buildx build --build-arg ENABLE_BLADERF=0 ...
```

## Related

`UPSTREAM_RADIOD_MIGRATION.md` in the `ka9q_ubersdr` repo records why the fork
was retired, which of its changes were absorbed upstream, what moved into
UberSDR, and the verification steps for the switchover.

## Licence

[ka9q-radio](https://github.com/ka9q/ka9q-radio) is Copyright Phil Karn KA9Q and
licensed under the GNU General Public License v3. It is fetched at build time
and compiled unmodified; none of it is vendored here.

`config/presets.conf` is the exception: it is a modified copy of upstream's
`share/presets.conf`, so it is GPLv3 too, and carries that notice in its header.

The rest — Dockerfile, entrypoint, build script — is original to this repo.
