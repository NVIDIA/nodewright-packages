#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Hold one of apt's locks for the lock-wait tests, run inside the test container.

Usage: lock_holder.py <lock> <seconds> <held-marker> [<apt-word> <seen-marker>]

Takes an fcntl lock on <lock>, the kind apt and dpkg take, and creates
<held-marker>. Given <apt-word>, it then keeps the lock until an apt or apt-get
process with that word among its arguments is running, creates <seen-marker>,
and only then starts the <seconds> count, so that command is sure to meet the
lock however long the commands before it took.
"""

import fcntl
import os
import sys
import time

# How long to wait for the apt command before giving up and releasing the lock.
APT_START_TIMEOUT_SECONDS = 300


def apt_running(word):
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as cmdline:
                args = cmdline.read().split(b"\0")
        except OSError:
            continue
        if os.path.basename(args[0]) in (b"apt", b"apt-get") and word.encode() in args:
            return True
    return False


def main():
    lock, seconds, held = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o640)
    fcntl.lockf(fd, fcntl.LOCK_EX)
    open(held, "w").close()

    if len(sys.argv) > 4:
        word, seen = sys.argv[4], sys.argv[5]
        deadline = time.monotonic() + APT_START_TIMEOUT_SECONDS
        while not apt_running(word):
            if time.monotonic() > deadline:
                return 1
            time.sleep(0.1)
        open(seen, "w").close()

    time.sleep(seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
