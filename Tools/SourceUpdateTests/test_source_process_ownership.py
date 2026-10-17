"""Synthetic kernel/job-boundary regressions; no launchd or child processes."""
import ctypes
import errno
import importlib.util
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

RESOURCE = Path(__file__).resolve().parents[2] / "Sources/OpenBotsServices/Resources/source-app-update.py"
SPEC = importlib.util.spec_from_file_location("source_update_ownership_tests", RESOURCE)
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)
ownership = updater.processes


def identity(pid, coalition=77, version=1, parent=1, group=None):
    return {"pid": pid, "coalition": coalition, "version": version, "unique": pid * 100 + version,
            "uid": os.getuid(), "gid": os.getgid(), "ruid": os.getuid(), "rgid": os.getgid(),
            "parent": parent, "group": pid if group is None else group, "status": 2}


class FakeMetadata:
    def __init__(self):
        self.values = {101: identity(101), 201: identity(201, 88), 301: identity(301, 99)}
        self.signals = []
        self.hide_once = False
    def identity(self, pid):
        return self.values.get(pid)
    def alive(self, value):
        return ownership.same_identity(value, self.identity(value["pid"]))
    def members(self, coalition):
        if self.hide_once:
            self.hide_once = False
            return {101: self.values[101]}
        return {pid: value for pid, value in self.values.items() if value["coalition"] == coalition}
    def active(self, coalition, allow_reaped=False):
        return sum(value["coalition"] == coalition for value in self.values.values())
    def send(self, value, sig):
        self.signals.append((value["pid"], value["version"], sig))
        current = self.values.get(value["pid"])
        if current is None or current["version"] != value["version"]:
            return errno.ESRCH
        self.values.pop(value["pid"])
        return 0


class CoalitionOwnershipTests(unittest.TestCase):
    def owner(self, api):
        return ownership.CoalitionOwner(api, api.values[201], api.values[301], pid=101)

    def test_retry_receipt_does_not_overwrite_an_interrupted_writers_file(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            pending = stage / "stopped.json.new"
            pending.write_bytes(b"interrupted writer")
            updater.write_json(stage / "stopped.json", {"stopped": False})
            self.assertEqual(pending.read_bytes(), b"interrupted writer")
            self.assertEqual(updater.private_json(stage / "stopped.json"), {"stopped": False})

    def test_fast_detached_child_is_found_without_ancestry_history(self):
        api = FakeMetadata()
        owner = self.owner(api)
        api.values[401] = identity(401, parent=1, group=401)
        with patch.object(os, "killpg", side_effect=AssertionError("no group signals")), patch.object(ownership.time, "sleep"):
            owner.stop_children()
        self.assertEqual([value[0] for value in api.signals], [401])
        self.assertEqual(api.active(77), 1)

    def test_atomic_population_catches_child_missed_by_pid_enumeration(self):
        api = FakeMetadata()
        owner = self.owner(api)
        api.values[401] = identity(401, parent=1)
        api.hide_once = True
        with patch.object(ownership.time, "sleep"):
            owner.stop_children()
        self.assertEqual([value[0] for value in api.signals], [401])
        self.assertEqual(api.active(77), 1)

    def test_historical_group_reuse_does_not_authorize_unrelated_process(self):
        api = FakeMetadata()
        owner = self.owner(api)
        api.values[401] = identity(401, parent=1, group=777)
        api.values[501] = identity(501, coalition=88, group=777)
        with patch.object(os, "killpg", side_effect=AssertionError("no group signals")), patch.object(ownership.time, "sleep"):
            owner.stop_children()
        self.assertIn(501, api.values)
        self.assertEqual([value[0] for value in api.signals], [401])

    def test_shared_initial_coalition_is_rejected_before_signaling(self):
        api = FakeMetadata()
        api.values[401] = identity(401)
        with self.assertRaises(ownership.OwnershipError):
            self.owner(api)
        self.assertEqual(api.signals, [])

    def test_unknown_atomic_population_never_acknowledges_stop(self):
        api = FakeMetadata()
        owner = self.owner(api)
        api.active = lambda _coalition, **_kwargs: 2
        clock = iter(range(30))
        with patch.object(ownership.time, "monotonic", side_effect=lambda: next(clock)), patch.object(ownership.time, "sleep"), self.assertRaises(ownership.OwnershipError):
            owner.stop_children()

    def test_parent_death_cancels_build_and_controller_death_always_cancels(self):
        api = FakeMetadata()
        with tempfile.TemporaryDirectory() as directory:
            worker = object.__new__(updater.Worker)
            worker.stage = Path(directory)
            worker.api = api
            worker.host_identity = api.values[201]
            worker.controller_identity = api.values[301]
            worker.cancelled = worker.allowed_after_exit = False
            worker.deadline = time.monotonic() + 60
            worker.check()
            api.values.pop(201)
            with self.assertRaises(updater.UpdateError) as error:
                worker.check()
            self.assertEqual(error.exception.code, "cancelled")
            worker.allowed_after_exit = True
            worker.check()  # Only the already-acknowledged installer uses this.
            api.values.pop(301)
            with self.assertRaises(updater.UpdateError):
                worker.check()

    def test_failed_bootout_cannot_return_positive_removal(self):
        api = FakeMetadata()
        def still_loaded(_arguments):
            return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        with self.assertRaises(ownership.OwnershipError):
            ownership.remove_job(ownership.service_name("a" * 32), 77, api, run=still_loaded)

    def test_failed_cleanup_removal_writes_negative_nonce_bound_receipt(self):
        api = FakeMetadata()
        original_controller = api.values.pop(301)
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            nonce = "a" * 32
            updater.write_json(stage / "launch.json", {"nonce": nonce, "service": ownership.service_name(nonce),
                               "hostIdentity": api.values[201], "controllerIdentity": original_controller})
            updater.write_json(stage / "started.json", {"nonce": nonce, "population": 1, "coalition": 77, "identity": api.values[101]})
            updater.write_json(stage / "admitted.json", {"nonce": nonce, "coalition": 77})
            with patch.object(ownership, "Metadata", return_value=api), patch.object(ownership.time, "sleep"), \
                    patch.object(ownership, "remove_job", side_effect=ownership.OwnershipError("failed")):
                self.assertEqual(updater.cleanup_main(stage, nonce), 1)
            receipt = updater.private_json(stage / "stopped.json")
            self.assertEqual(receipt["nonce"], nonce)
            self.assertFalse(receipt["stopped"])
            self.assertFalse(receipt["jobRemoved"])

    def test_stale_pid_version_is_passed_to_kernel_without_pid_only_fallback(self):
        api = object.__new__(ownership.Metadata)
        received = []
        def kernel(pointer, sig):
            token = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint32 * 8)).contents
            received.append((token[5], token[7], sig))
            return errno.ESRCH
        api.lib = SimpleNamespace(proc_signal_with_audittoken=kernel)
        with patch.object(os, "kill", side_effect=AssertionError("no PID-only fallback")):
            self.assertEqual(api.send(identity(401, version=8), 15), errno.ESRCH)
        self.assertEqual(received, [(401, 8, 15)])

    def test_truncated_pid_list_and_partial_identity_fail_closed(self):
        api = object.__new__(ownership.Metadata)
        api.lib = SimpleNamespace(proc_listpids=lambda *_args: 65536 * 4, proc_pidinfo=lambda *_args: 12)
        with self.assertRaises(ownership.OwnershipError):
            api.pids()
        with self.assertRaises(ownership.OwnershipError):
            api.field(101, 17, 56)
