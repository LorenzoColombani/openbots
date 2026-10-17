"""Private source-update process ownership; Python standard library only.

Darwin ABI and return contracts were checked with the bounded coalition probe.
Pinned implementation reference: apple-oss-distributions/xnu revision
f6217f891ac0bb64f3d375211650a4c1ff8ca1ea, proc_info_private.h, libproc.c,
sys_coalition.c, wrappers/coalition.c, and doc/observability/coalitions.md.
No argv/environment inspection, historical PGIDs, or PID-only signals.
"""
import ctypes
import errno
import os
import re
import signal
import struct
import subprocess
import sys
import time


class OwnershipError(Exception):
    pass


def require(condition):
    if not condition:
        raise OwnershipError("The update worker could not verify process ownership. Keep the app open.")


def same_identity(first, second):
    return (first is not None and second is not None
            and all(first[key] == second[key] for key in ("pid", "version", "unique", "uid", "coalition")))


class Metadata:
    def __init__(self):
        require(sys.platform == "darwin" and os.getuid() != 0)
        try:
            self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            self.lib.proc_pidinfo.restype = ctypes.c_int
            self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
            self.lib.proc_listpids.restype = ctypes.c_int
            self.lib.proc_signal_with_audittoken.argtypes = [ctypes.c_void_p, ctypes.c_int]
            self.lib.proc_signal_with_audittoken.restype = ctypes.c_int
            self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            self.system.coalition_info_resource_usage.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
            self.system.coalition_info_resource_usage.restype = ctypes.c_int
        except (OSError, AttributeError) as error:
            raise OwnershipError("This macOS version cannot safely supervise source updates.") from error

    def active(self, coalition, allow_reaped=False):
        require(type(coalition) is int and coalition > 1)
        values = (ctypes.c_uint64 * 2)()
        ctypes.set_errno(0)
        result = self.system.coalition_info_resource_usage(coalition, values, ctypes.sizeof(values))
        error = ctypes.get_errno()
        if result == -1 and error == errno.ESRCH and allow_reaped:
            return 0
        # tasks_started/tasks_exited are one locked kernel snapshot. The kernel
        # permits this stable 16-byte prefix of coalition_resource_usage.
        require(result == 0 and values[0] >= values[1])
        return int(values[0] - values[1])

    def field(self, pid, flavor, size):
        require(type(pid) is int and 0 < pid <= 0x7FFFFFFF)
        buffer = ctypes.create_string_buffer(size)
        ctypes.set_errno(0)
        count = self.lib.proc_pidinfo(pid, flavor, 0, buffer, size)
        if count == 0 and ctypes.get_errno() == errno.ESRCH:
            return None
        require(count == size)
        return buffer.raw

    def pids(self):
        buffer = (ctypes.c_int * 65536)()
        count = self.lib.proc_listpids(4, os.getuid(), buffer, ctypes.sizeof(buffer))  # PROC_UID_ONLY
        require(0 < count < ctypes.sizeof(buffer) and count % 4 == 0)
        return {int(pid) for pid in buffer[:count // 4] if pid > 0}

    def coalition(self, pid):
        data = self.field(pid, 20, 40)
        return struct.unpack_from("=Q", data, 0)[0] if data is not None else None

    def identity(self, pid):
        first = self.field(pid, 17, 56)
        if first is None:
            return None
        bsd = self.field(pid, 13, 64)
        coalition = self.coalition(pid)
        after = self.field(pid, 17, 56)
        if bsd is None or coalition is None or after is None:
            return None
        unique = struct.unpack_from("=Q", first, 16)[0]
        version = struct.unpack_from("=I", first, 32)[0]
        require(unique == struct.unpack_from("=Q", after, 16)[0]
                and version == struct.unpack_from("=I", after, 32)[0])
        actual_pid, parent, group, status = struct.unpack_from("=IIII", bsd, 0)
        flags, uid, gid, ruid, rgid, svuid, svgid, reserved = struct.unpack_from("=IIIIIIII", bsd, 32)
        require(actual_pid == pid and unique > 0)
        return {"pid": pid, "version": version, "unique": unique, "coalition": coalition,
                "parent": parent, "group": group, "status": status, "uid": uid, "gid": gid, "ruid": ruid, "rgid": rgid}

    def alive(self, identity):
        return same_identity(identity, self.identity(identity["pid"]))

    def members(self, coalition):
        found = {}
        for pid in self.pids():
            if self.coalition(pid) == coalition:
                identity = self.identity(pid)
                if identity is not None:
                    require(identity["coalition"] == coalition and identity["uid"] == os.getuid())
                    found[pid] = identity
        return found

    def send(self, identity, sig):
        require(identity["uid"] == os.getuid() and 0 < sig < signal.NSIG)
        token = (ctypes.c_uint32 * 8)(identity["uid"], identity["uid"], identity["gid"], identity["ruid"],
                                    identity["rgid"], identity["pid"], 0, identity["version"])
        result = self.lib.proc_signal_with_audittoken(ctypes.byref(token), sig)
        # libproc converts the syscall's -1/errno into a positive errno return.
        # ESRCH includes PID-version mismatch; it never authorizes a PID retry.
        require(result in (0, errno.ESRCH))
        return result


class CoalitionOwner:
    def __init__(self, metadata, host, controller, pid=None):
        self.api = metadata
        self.pid = os.getpid() if pid is None else pid
        self.identity = metadata.identity(self.pid)
        require(self.identity is not None and self.identity["uid"] == os.getuid())
        self.coalition = self.identity["coalition"]
        require(self.coalition > 1 and self.coalition not in (host["coalition"], controller["coalition"]))
        # This gate runs before any command, source download, or build starts.
        self.assert_alone()

    def assert_alone(self):
        require(set(self.api.members(self.coalition)) == {self.pid} and self.api.active(self.coalition) == 1)

    def stop_children(self, reap=lambda: None):
        for sig, interval in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
            deadline = time.monotonic() + interval
            while time.monotonic() < deadline:
                reap()
                members = self.api.members(self.coalition)
                require(self.pid in members and same_identity(self.identity, members[self.pid]))
                others = {pid: identity for pid, identity in members.items() if pid != self.pid}
                # Enumeration can miss a concurrent fork. Only the atomic
                # resource population of one proves no other task can fork.
                if not others and self.api.active(self.coalition) == 1:
                    return
                for identity in others.values():
                    self.api.send(identity, sig)
                time.sleep(0.05)
        raise OwnershipError("The update worker could not confirm all build processes stopped. Keep the app open.")


def launchctl(arguments):
    try:
        result = subprocess.run(["/bin/launchctl"] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=4,
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OwnershipError("The temporary update job could not be managed. Keep the app open.") from error
    require(len(result.stdout) <= 65536 and len(result.stderr) <= 65536)
    return result


def service_name(nonce):
    require(isinstance(nonce, str) and re.fullmatch(r"[a-f0-9]{32}", nonce) is not None)
    return "gui/" + str(os.getuid()) + "/com.lorenzocolombani.openbotsnext.source-update-" + nonce


def service_absent(service, run=launchctl):
    result = run(["print", service])
    return result.returncode != 0 and b"Could not find service" in result.stderr


def remove_job(service, coalition, metadata, run=launchctl):
    # Never bootout a domain or a remembered PID. The service string is derived
    # from this run's nonce, and was checked absent before our bootstrap.
    run(["bootout", service])
    require(service_absent(service, run=run))
    if coalition is not None:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if metadata.active(coalition, allow_reaped=True) == 0 and not metadata.members(coalition):
                return
            time.sleep(0.05)
        raise OwnershipError("The temporary update job still has work running. Keep the app open.")


def stop_entire_coalition(metadata, coalition):
    # Controller-only crash recovery, after a nonce-bound startup receipt
    # proved the coalition belonged solely to our worker before any commands.
    for sig, interval in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
        deadline = time.monotonic() + interval
        while time.monotonic() < deadline:
            for identity in metadata.members(coalition).values():
                metadata.send(identity, sig)
            if metadata.active(coalition, allow_reaped=True) == 0:
                return
            time.sleep(0.05)
    raise OwnershipError("The update job did not confirm shutdown. Keep the app open.")
