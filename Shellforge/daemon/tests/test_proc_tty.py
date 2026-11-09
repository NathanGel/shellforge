"""A process's controlling terminal, read from the kernel: what binds an armed launch to its tab."""
import fcntl
import os
import subprocess
import sys
import termios

import pytest

from shellforged.proc_tty import controlling_tty

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="libproc is macOS's")


def take_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def test_a_process_on_a_pty_has_that_pty():
    master, slave = os.openpty()
    child = subprocess.Popen(["/bin/cat"], stdin=slave, stdout=slave, stderr=slave, preexec_fn=take_terminal)
    try:
        assert controlling_tty(child.pid) == os.fstat(slave).st_rdev
    finally:
        child.kill()
        child.wait()
        os.close(master)
        os.close(slave)


def test_a_process_with_no_terminal_has_none():
    child = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, start_new_session=True)
    try:
        assert controlling_tty(child.pid) is None
    finally:
        child.kill()
        child.wait()


@pytest.mark.parametrize("pid", [0, -1, 999_999_999])
def test_no_such_process_has_none(pid):
    assert controlling_tty(pid) is None
