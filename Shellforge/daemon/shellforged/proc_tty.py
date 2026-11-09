"""Which terminal a process belongs to: its controlling tty, read from the kernel with libproc
(`proc_pidinfo(PROC_PIDTBSDINFO)`), in-process, without running `ps`. macOS only: anywhere else, or
for a process that is gone or has no terminal, the answer is None, which every caller treats as no."""
from __future__ import annotations

import ctypes
import sys

PROC_PIDTBSDINFO = 3
# `struct proc_bsdinfo` (<sys/proc_info.h>): twelve 32-bit fields, pbi_comm[16], pbi_name[32], then
# pbi_nfiles, pbi_pgid, pbi_pjobc, e_tdev, e_tpgid, pbi_nice and two 64-bit start times.
_BSDINFO_SIZE = 136
_PID_OFFSET = 12
_TDEV_OFFSET = 108
#: e_tdev for a process with no controlling terminal.
NODEV = 0xFFFFFFFF


def _libproc() -> ctypes.CDLL | None:
    if sys.platform != "darwin":
        return None
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
    except (OSError, AttributeError):
        return None
    return lib


_LIB = _libproc()


def controlling_tty(pid: int) -> int | None:
    """The device number of `pid`'s controlling terminal, or None."""
    if _LIB is None or pid <= 0:
        return None
    buffer = ctypes.create_string_buffer(_BSDINFO_SIZE)
    if _LIB.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, _BSDINFO_SIZE) != _BSDINFO_SIZE:
        return None
    if int.from_bytes(buffer.raw[_PID_OFFSET:_PID_OFFSET + 4], sys.byteorder) != pid:
        return None  # not the struct this reads it as
    device = int.from_bytes(buffer.raw[_TDEV_OFFSET:_TDEV_OFFSET + 4], sys.byteorder)
    return None if device == NODEV else device
