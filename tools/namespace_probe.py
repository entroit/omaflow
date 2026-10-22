"""Check namespace support without leaving mapping helpers behind."""
import os
import signal
import subprocess


def namespace_available(command):
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    except OSError:
        return False
    try:
        return process.wait(timeout=5) == 0
    except subprocess.TimeoutExpired:
        return False
    finally:
        # unshare can exit after namespace denial while its mapping helper waits.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
