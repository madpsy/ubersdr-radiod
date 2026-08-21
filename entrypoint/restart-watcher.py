#!/usr/bin/env python3
"""Watch for UberSDR's restart trigger and stop radiod so the container restarts.

UberSDR asks for a radiod restart by creating a file in the shared trigger
volume.  We remove it and SIGTERM PID 1 (radiod), letting the container's
restart policy bring it back.
"""

import os
import signal
import time

TRIGGER = "/var/run/restart-trigger/restart"
POLL_SECONDS = 2

while True:
    if os.path.exists(TRIGGER):
        print("Restart trigger detected from ubersdr, restarting...", flush=True)
        os.remove(TRIGGER)
        os.kill(1, signal.SIGTERM)
        break
    time.sleep(POLL_SECONDS)
