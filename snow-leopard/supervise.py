#!/opt/local/bin/python3.14
"""Supervise ./build-snow-leopard.sh so a multi-day build survives on its own.

    /opt/local/bin/python3.14 snow-leopard/supervise.py --daemon
    tail -f snow-leopard-supervise.log

Why this exists. On the 2 GB / 1.83 GHz target the build takes days, and it is
usually driven over SSH. Two things kept stopping it:

  * The session that started it went away. `nohup` plus `< /dev/null` was not
    enough; the build still ended up idle. `os.setsid()` puts the build in a
    new session with no controlling terminal, so nothing from the login
    session can reach it.
  * `gmake` was twice left sleeping with no children and a frozen log, having
    apparently lost a child it was waiting on. There is no error to react to,
    so this watches the log's mtime and restarts when it goes stale. gyp's
    makefiles are incremental, so a restart only costs the file in flight.

A build tree stopped on purpose (state T in ps, e.g. `kill -STOP` while
another large compile runs; 2 GB cannot hold two) is treated as quiet, not
stalled.

It stops, leaving everything for inspection, on BUILD-OK or on a real build
failure. It does not retry a failing compile.

Paths default to this repository's layout and can be overridden:
  SL_BUILD   build command            (default ./build-snow-leopard.sh build)
  SL_STATUS  status file              (default .sl-status)
  SL_LOG     build log                (default build-snow-leopard.log)
  SL_STALL   stall threshold, minutes (default 20)
"""

import os
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.environ.get("SL_BUILD", os.path.join(ROOT, "build-snow-leopard.sh") + " build").split()
STATUS = os.environ.get("SL_STATUS", os.path.join(ROOT, ".sl-status"))
LOG = os.environ.get("SL_LOG", os.path.join(ROOT, "build-snow-leopard.log"))
DLOG = os.path.join(ROOT, "snow-leopard-supervise.log")
PIDFILE = os.path.join(ROOT, ".sl-supervise.pid")

STALL_SECONDS = int(os.environ.get("SL_STALL", "20")) * 60
POLL_SECONDS = 60
MAX_RESTARTS = 40

SUCCESS = ("BUILD-OK", "INSTALLED")
FAILURE = ("BUILD-FAILED", "INSTALL-FAILED", "FAILED")


def say(msg):
    with open(DLOG, "a") as f:
        f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))


def read_status():
    try:
        with open(STATUS) as f:
            return f.read().strip()
    except OSError:
        return ""


def log_mtime():
    for p in (LOG, LOG + ".prev"):
        try:
            return os.stat(p).st_mtime
        except OSError:
            pass
    return 0.0


def ps_lines():
    out = subprocess.run(["/bin/ps", "ax", "-o", "pid=,stat=,command="],
                         capture_output=True, text=True, timeout=30).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            yield parts


def is_build_proc(cmd):
    return ("build-snow-leopard.sh" in cmd or "gmake" in cmd or "clang" in cmd
            or "libtool" in cmd)


def busy_or_paused():
    """A compiler/archiver/generator is working, or the tree is stopped on purpose."""
    try:
        for _pid, stat, cmd in ps_lines():
            if "grep" in cmd or "supervise.py" in cmd:
                continue
            if is_build_proc(cmd) and stat.startswith("T"):
                return True
            if ("clang" in cmd or "libtool" in cmd or "mksnapshot" in cmd
                    or "/torque" in cmd or ("python" in cmd and "gyp" in cmd)):
                return True
    except Exception:
        return True  # never kill on a failed probe
    return False


def kill_tree():
    me = os.getpid()
    for sigs in ((signal.SIGCONT, signal.SIGTERM), (signal.SIGKILL,)):
        try:
            for pid, _stat, cmd in ps_lines():
                if int(pid) == me or "supervise.py" in cmd:
                    continue
                if "build-snow-leopard.sh" in cmd or "gmake" in cmd:
                    for s in sigs:
                        try:
                            os.kill(int(pid), s)
                        except OSError:
                            pass
        except Exception:
            pass
        time.sleep(3)


def supervise():
    with open(PIDFILE, "w") as f:
        f.write("%d\n" % os.getpid())
    say("supervisor started, pid %d; build: %s" % (os.getpid(), " ".join(BUILD)))
    restarts = 0
    while restarts <= MAX_RESTARTS:
        kill_tree()
        say("starting build (attempt %d)" % (restarts + 1))
        with open(os.devnull, "rb") as dn, open(os.path.join(ROOT, ".sl-build.out"), "ab") as out:
            proc = subprocess.Popen(BUILD, stdin=dn, stdout=out, stderr=out, cwd=ROOT, close_fds=True)
        stalled = False
        while proc.poll() is None:
            time.sleep(POLL_SECONDS)
            age = time.time() - log_mtime()
            if proc.poll() is None and age > STALL_SECONDS and not busy_or_paused():
                say("stalled: log untouched for %d min, nothing compiling; restarting" % (age // 60))
                stalled = True
                proc.terminate()
                time.sleep(5)
                kill_tree()
                break
        if stalled:
            restarts += 1
            continue
        st = read_status()
        say("build exited rc=%s, status=%r" % (proc.returncode, st))
        if st.startswith(SUCCESS):
            say("SUCCESS")
            return 0
        if st.startswith(FAILURE):
            say("real failure; stopping for inspection (see the build log)")
            return 1
        restarts += 1
    say("giving up after %d restarts" % restarts)
    return 1


def daemonize():
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.chdir(ROOT)
    fd = os.open(os.devnull, os.O_RDWR)
    for n in (0, 1, 2):
        os.dup2(fd, n)
    if fd > 2:
        os.close(fd)


if __name__ == "__main__":
    if "--daemon" in sys.argv:
        daemonize()
    sys.exit(supervise())
