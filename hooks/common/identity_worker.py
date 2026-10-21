"""Run one signature query with finite, owned-process cleanup.

Windows 10+ uses an atomic Job assignment at CreateProcessW, explicit inherited
stdio handles and no console. POSIX uses a new session; WNOWAIT retains the
leader's PID until its group is killed. Linux additionally adopts/reaps orphans.
These boundaries cover ordinary Git/verifier descendants, not escaped sessions.
No third-party runtime modules, network access or global configuration changes.

OS contracts: Microsoft Learn UpdateProcThreadAttribute / Job Objects;
Python os.waitid and subprocess.Popen(start_new_session=True).
See docs/IDENTITY.md for the verification failure and prerequisite contract.
"""

import argparse
import ctypes
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import suppress
from pathlib import Path
from types import FrameType

LIMIT = 1024 * 1024
CLEANUP_SECONDS = 2
_cancelled = False
MAX_TIMEOUT_SECONDS = 300
MAX_EXIT_STATUS = 255
EXIT_TIMEOUT = 124
EXIT_TOOL_ERROR = 125
WAIT_TIMEOUT = 258


def exceeded(paths: tuple[Path, ...]) -> bool:
    return any(path.stat().st_size > LIMIT for path in paths)


def interrupted(_signum: int, _frame: FrameType | None) -> None:
    # Raising here can interrupt Popen's ownership transfer or the cleanup itself.
    global _cancelled
    _cancelled = True


def check_cancelled() -> None:
    if _cancelled:
        raise InterruptedError("signature worker interrupted")


def posix_run(command: list[str], timeout: int, output: Path, error: Path) -> int:
    if sys.platform == "win32":
        raise RuntimeError("POSIX containment is unavailable on Windows")
    if not all(hasattr(os, name) for name in ("waitid", "WNOWAIT", "WEXITED")):
        raise RuntimeError("this POSIX runtime lacks waitid/WNOWAIT containment")
    if sys.platform.startswith("linux"):
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise OSError(ctypes.get_errno(), "cannot establish child subreaper")
    with (
        open(os.devnull, "rb") as stdin,
        output.open("wb") as stdout,
        error.open("wb") as stderr,
    ):
        child = subprocess.Popen(
            command, stdin=stdin, stdout=stdout, stderr=stderr, start_new_session=True
        )
        result = EXIT_TOOL_ERROR
        try:
            deadline = time.monotonic() + timeout
            while True:
                check_cancelled()
                status = os.waitid(
                    os.P_PID, child.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG
                )
                if status is not None:
                    result = (
                        status.si_status
                        if status.si_code == os.CLD_EXITED
                        else EXIT_TOOL_ERROR
                    )
                    break
                if exceeded((output, error)):
                    raise RuntimeError("signature output exceeded 1 MiB")
                if time.monotonic() >= deadline:
                    result = EXIT_TIMEOUT
                    break
                time.sleep(0.025)
        finally:
            # Leader remains unreaped, so its numeric process-group ID is ours.
            # An already-empty owned group is an expected successful cleanup.
            with suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=CLEANUP_SECONDS)
            if sys.platform.startswith("linux"):
                deadline = time.monotonic() + CLEANUP_SECONDS
                while True:
                    try:
                        adopted, _ = os.waitpid(-1, os.WNOHANG)
                    except ChildProcessError:
                        break
                    if adopted == 0:
                        if time.monotonic() >= deadline:
                            raise RuntimeError("owned descendant cleanup deadline")
                        time.sleep(0.01)
        return result


def windows_run(command: list[str], timeout: int, output: Path, error: Path) -> int:
    """Assign the process to a kill-on-close Job before its first instruction."""
    if sys.platform != "win32":
        raise RuntimeError("Windows containment is unavailable on this platform")
    import msvcrt
    from ctypes import wintypes as w

    size = ctypes.c_size_t
    pointer = ctypes.c_void_p
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    class Startup(ctypes.Structure):
        _fields_ = [
            ("cb", w.DWORD),
            ("reserved", w.LPWSTR),
            ("desktop", w.LPWSTR),
            ("title", w.LPWSTR),
            ("x", w.DWORD),
            ("y", w.DWORD),
            ("xsize", w.DWORD),
            ("ysize", w.DWORD),
            ("xchars", w.DWORD),
            ("ychars", w.DWORD),
            ("fill", w.DWORD),
            ("flags", w.DWORD),
            ("show", w.WORD),
            ("reserved_size", w.WORD),
            ("reserved2", pointer),
            ("stdin", w.HANDLE),
            ("stdout", w.HANDLE),
            ("stderr", w.HANDLE),
        ]

    class ExtendedStartup(ctypes.Structure):
        _fields_ = [("startup", Startup), ("attributes", pointer)]

    class ProcessInfo(ctypes.Structure):
        _fields_ = [
            ("process", w.HANDLE),
            ("thread", w.HANDLE),
            ("pid", w.DWORD),
            ("tid", w.DWORD),
        ]

    class BasicLimit(ctypes.Structure):
        _fields_ = [
            ("process_time", ctypes.c_int64),
            ("job_time", ctypes.c_int64),
            ("flags", w.DWORD),
            ("min_working", size),
            ("max_working", size),
            ("active_limit", w.DWORD),
            ("affinity", size),
            ("priority", w.DWORD),
            ("scheduling", w.DWORD),
        ]

    class IoCounters(ctypes.Structure):
        _fields_ = [
            (name, ctypes.c_uint64)
            for name in (
                "read",
                "write",
                "other",
                "read_bytes",
                "write_bytes",
                "other_bytes",
            )
        ]

    class Limits(ctypes.Structure):
        _fields_ = [
            ("basic", BasicLimit),
            ("io", IoCounters),
            ("process_memory", size),
            ("job_memory", size),
            ("peak_process", size),
            ("peak_job", size),
        ]

    class Accounting(ctypes.Structure):
        _fields_ = [
            (name, ctypes.c_int64)
            for name in ("user", "kernel", "period_user", "period_kernel")
        ] + [(name, w.DWORD) for name in ("faults", "total", "active", "terminated")]

    signatures = {
        "CreateJobObjectW": ([pointer, w.LPCWSTR], w.HANDLE),
        "SetInformationJobObject": ([w.HANDLE, ctypes.c_int, pointer, w.DWORD], w.BOOL),
        "QueryInformationJobObject": (
            [w.HANDLE, ctypes.c_int, pointer, w.DWORD, pointer],
            w.BOOL,
        ),
        "TerminateJobObject": ([w.HANDLE, w.UINT], w.BOOL),
        "InitializeProcThreadAttributeList": (
            [pointer, w.DWORD, w.DWORD, ctypes.POINTER(size)],
            w.BOOL,
        ),
        "UpdateProcThreadAttribute": (
            [pointer, w.DWORD, size, pointer, size, pointer, pointer],
            w.BOOL,
        ),
        "DeleteProcThreadAttributeList": ([pointer], None),
        "CreateProcessW": (
            [
                w.LPCWSTR,
                w.LPWSTR,
                pointer,
                pointer,
                w.BOOL,
                w.DWORD,
                pointer,
                w.LPCWSTR,
                pointer,
                pointer,
            ],
            w.BOOL,
        ),
        "WaitForSingleObject": ([w.HANDLE, w.DWORD], w.DWORD),
        "GetExitCodeProcess": ([w.HANDLE, ctypes.POINTER(w.DWORD)], w.BOOL),
        "CloseHandle": ([w.HANDLE], w.BOOL),
    }
    for name, (arguments, returns) in signatures.items():
        function = getattr(kernel, name)
        function.argtypes = arguments
        function.restype = returns

    def checked(value):
        if not value:
            raise ctypes.WinError(ctypes.get_last_error())
        return value

    job = checked(kernel.CreateJobObjectW(None, None))
    information = ProcessInfo()
    attributes = None
    initialized = False
    try:
        limits = Limits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        checked(
            kernel.SetInformationJobObject(
                job, 9, ctypes.byref(limits), ctypes.sizeof(limits)
            )
        )
        length = size()
        kernel.InitializeProcThreadAttributeList(None, 2, 0, ctypes.byref(length))
        if not length.value:
            raise ctypes.WinError(ctypes.get_last_error())
        attributes = ctypes.create_string_buffer(length.value)
        checked(
            kernel.InitializeProcThreadAttributeList(
                attributes, 2, 0, ctypes.byref(length)
            )
        )
        initialized = True
        jobs = (w.HANDLE * 1)(job)
        checked(
            kernel.UpdateProcThreadAttribute(
                attributes, 0, 0x2000D, jobs, ctypes.sizeof(jobs), None, None
            )
        )
        with (
            open(os.devnull, "rb") as stdin,
            output.open("wb") as stdout,
            error.open("wb") as stderr,
        ):
            handles = (w.HANDLE * 3)(
                *[
                    msvcrt.get_osfhandle(stream.fileno())
                    for stream in (stdin, stdout, stderr)
                ]
            )
            for handle in handles:
                if handle is None:
                    raise RuntimeError("signature stdio handle is unavailable")
                os.set_handle_inheritable(handle, True)
            checked(
                kernel.UpdateProcThreadAttribute(
                    attributes, 0, 0x20002, handles, ctypes.sizeof(handles), None, None
                )
            )
            startup = ExtendedStartup()
            startup.startup.cb = ctypes.sizeof(startup)
            startup.startup.flags = 0x100  # STARTF_USESTDHANDLES
            startup.startup.stdin, startup.startup.stdout, startup.startup.stderr = (
                handles
            )
            startup.attributes = ctypes.cast(attributes, pointer)
            executable = shutil.which(command[0])
            if not executable:
                raise FileNotFoundError("signature command is unavailable")
            command[0] = os.path.normpath(executable)
            argv = ctypes.create_unicode_buffer(subprocess.list2cmdline(command))
            checked(
                kernel.CreateProcessW(
                    command[0],
                    argv,
                    None,
                    None,
                    True,
                    0x08080000,
                    None,
                    None,
                    ctypes.byref(startup),
                    ctypes.byref(information),
                )
            )
            deadline = time.monotonic() + timeout
            result = EXIT_TOOL_ERROR
            while True:
                check_cancelled()
                state = kernel.WaitForSingleObject(information.process, 25)
                if state == 0:
                    code = w.DWORD()
                    checked(
                        kernel.GetExitCodeProcess(
                            information.process, ctypes.byref(code)
                        )
                    )
                    result = code.value
                    break
                if state != WAIT_TIMEOUT:
                    raise ctypes.WinError(ctypes.get_last_error())
                if exceeded((output, error)):
                    raise RuntimeError("signature output exceeded 1 MiB")
                if time.monotonic() >= deadline:
                    result = EXIT_TIMEOUT
                    break
            return result
    finally:
        # This job is unnamed/non-inherited; it can contain only our query tree.
        try:
            checked(kernel.TerminateJobObject(job, EXIT_TOOL_ERROR))
            deadline = time.monotonic() + CLEANUP_SECONDS
            while True:
                counts = Accounting()
                checked(
                    kernel.QueryInformationJobObject(
                        job, 1, ctypes.byref(counts), ctypes.sizeof(counts), None
                    )
                )
                if counts.active == 0:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("owned descendant cleanup deadline")
                time.sleep(0.01)
        finally:
            for handle in (information.thread, information.process):
                if handle:
                    kernel.CloseHandle(handle)
            if initialized:
                kernel.DeleteProcThreadAttributeList(attributes)
            kernel.CloseHandle(job)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-runtime", action="store_true")
    parser.add_argument("--timeout-seconds", default=30, type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--error", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not args.check_runtime and (
        not command or args.output is None or args.error is None
    ):
        parser.error("need a command and private output/error paths")
    if not 1 <= args.timeout_seconds <= MAX_TIMEOUT_SECONDS:
        parser.error("need a command and timeout between 1 and 300 seconds")
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    runtime_directory = None
    try:
        if args.check_runtime:
            runtime_directory = tempfile.TemporaryDirectory(prefix="gg-identity-ready-")
            root = Path(runtime_directory.name)
            args.output, args.error = root / "out", root / "err"
            args.timeout_seconds = 2
            command = [sys.executable, "-I", "-S", "-B", "-c", "pass"]
        run = windows_run if os.name == "nt" else posix_run
        result = run(command, args.timeout_seconds, args.output, args.error)
        check_cancelled()
        if exceeded((args.output, args.error)):
            raise RuntimeError("signature output exceeded 1 MiB")
        if result == EXIT_TIMEOUT:
            print(
                "git-guard: signature query deadline exceeded; verification failed",
                file=sys.stderr,
            )
        return result if 0 <= result <= MAX_EXIT_STATUS else EXIT_TOOL_ERROR
    except (
        OSError,
        RuntimeError,
        InterruptedError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"git-guard: signature supervisor failed: {error}", file=sys.stderr)
        return EXIT_TOOL_ERROR
    finally:
        if runtime_directory is not None:
            runtime_directory.cleanup()


if __name__ == "__main__":
    sys.exit(main())
