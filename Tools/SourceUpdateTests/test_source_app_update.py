"""Synthetic-only updater tests. Never build, sign, download, or launch an app.

Run by the build/test owner: python3 -B -m unittest discover -s Tools/SourceUpdateTests
"""
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

WORKER = Path(__file__).resolve().parents[2] / "Sources/OpenBotsServices/Resources/source-app-update.py"
SPEC = importlib.util.spec_from_file_location("source_update_worker", WORKER)
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)
COMMIT = "a" * 40
TEAM = "ABCDEFGHIJ"


class SourceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.files = {"Scripts/build-source-update.sh": b"reviewed build", "Scripts/swiftpm-public.sh": b"reviewed dependency boundary",
                      "Scripts/source-update-sign.py": b"reviewed local signing",
                      "Sources/Example.swift": b"reviewed source"}
        self.entries = [{"path": name, "sha256": hashlib.sha256(data).hexdigest(),
                         "mode": "100755" if name.endswith(".sh") else "100644"} for name, data in self.files.items()]
        self.inventory = updater.inventory(self.entries)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, mutate=None, prefix=None):
        prefix = prefix or "openbots-" + COMMIT
        entries = []
        for name, data in self.files.items():
            info = tarfile.TarInfo(prefix + "/" + name)
            info.size = len(data)
            info.mode = 0o775 if name.endswith(".sh") else 0o664
            entries.append((info, data))
        if mutate:
            mutate(entries)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for info, data in entries:
                archive.addfile(info, io.BytesIO(data))
        path = self.root / (str(uuid.uuid4()) + ".tar.gz")
        path.write_bytes(gzip.compress(stream.getvalue()))
        return path

    def extract(self, archive):
        destination = self.root / str(uuid.uuid4())
        updater.extract_verified(archive, destination, self.inventory, COMMIT)
        return destination

    def test_complete_exact_tree_and_executable_modes(self):
        destination = self.extract(self.archive())
        self.assertEqual((destination / "Sources/Example.swift").read_bytes(), self.files["Sources/Example.swift"])
        self.assertEqual((destination / "Scripts/build-source-update.sh").stat().st_mode & 0o777, 0o700)
        self.assertEqual((destination / "Sources/Example.swift").stat().st_mode & 0o777, 0o600)

    def test_gzip_serialization_does_not_define_source_identity(self):
        first = self.archive()
        raw = gzip.decompress(first.read_bytes())
        second = self.root / "other.tar.gz"
        second.write_bytes(gzip.compress(raw, mtime=1))
        self.extract(first)
        self.extract(second)

    def test_hash_missing_extra_duplicate_and_modes_rejected(self):
        def bad_hash(entries):
            entries[0] = (entries[0][0], b"X" * entries[0][0].size)
        def extra(entries):
            info = tarfile.TarInfo("openbots-" + COMMIT + "/surprise.sh")
            info.mode = 0o755
            entries.append((info, b""))
        def mode(entries):
            entries[0][0].mode = 0o664
        for mutation in (bad_hash, lambda entries: entries.pop(), extra, lambda entries: entries.append(entries[0]), mode):
            with self.subTest(mutation=mutation), self.assertRaises(updater.UpdateError):
                self.extract(self.archive(mutation))

    def test_links_specials_traversal_aliases_and_wrong_wrapper_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE):
            def change(entries):
                info = entries[0][0]
                info.type = kind
                info.linkname = "../../outside"
                info.size = 0
                entries[0] = (info, b"")
            with self.subTest(kind=kind), self.assertRaises(updater.UpdateError):
                self.extract(self.archive(change))
        for path in ("../outside", "/outside", "openbots-" + COMMIT + "/Scripts/../outside", "openbots-" + COMMIT + "/scripts/build-source-update.sh"):
            def change(entries):
                entries[0][0].name = path
            with self.subTest(path=path), self.assertRaises(updater.UpdateError):
                self.extract(self.archive(change))
        with self.assertRaises(updater.UpdateError):
            self.extract(self.archive(prefix="another-wrapper"))

    def test_bounded_inflate_and_appended_gzip_rejected(self):
        archive = self.archive()
        with patch.object(updater, "MAX_TAR", 1024), self.assertRaises(updater.UpdateError):
            self.extract(archive)
        self.assertFalse((self.root / "source.tar").exists())
        archive.write_bytes(archive.read_bytes() + gzip.compress(b"extra"))
        with self.assertRaises(updater.UpdateError):
            self.extract(archive)
        self.assertFalse((self.root / "source.tar").exists())

    def test_existing_staging_file_is_never_overwritten_or_removed(self):
        raw = self.root / "source.tar"
        raw.write_bytes(b"another operation owns this file")
        with self.assertRaises(updater.UpdateError):
            self.extract(self.archive())
        self.assertEqual(raw.read_bytes(), b"another operation owns this file")

    def test_cancellation_happens_during_extraction_before_any_build(self):
        calls = 0
        def cancel():
            nonlocal calls
            calls += 1
            if calls == 2:
                updater.fail("cancelled", "cancelled")
        with self.assertRaises(updater.UpdateError) as error:
            updater.extract_verified(self.archive(), self.root / "cancelled", self.inventory, COMMIT, cancel)
        self.assertEqual(error.exception.code, "cancelled")

    def test_post_extraction_rehash_catches_mutation(self):
        destination = self.extract(self.archive())
        (destination / "Sources/Example.swift").write_bytes(b"changed after extraction")
        with self.assertRaises(updater.UpdateError):
            updater.verify_source_tree(destination, self.inventory)

    def test_inventory_rejects_case_aliases_and_parent_files(self):
        for path in ("scripts/build-source-update.sh", "Scripts", ".git/config", "../bad", ".build.noindex/secret"):
            with self.subTest(path=path), self.assertRaises(updater.UpdateError):
                updater.inventory(self.entries + [{"path": path, "sha256": "f" * 64, "mode": "100644"}])

    def test_only_git_commit_pax_comment_is_supported(self):
        body = ("comment=" + COMMIT + "\n").encode()
        size = len(body) + 3
        while len(str(size).encode() + b" " + body) != size:
            size = len(str(size).encode() + b" " + body)
        updater.pax_comment(str(size).encode() + b" " + body, COMMIT)
        with self.assertRaises(updater.UpdateError):
            updater.pax_comment(b"20 path=../../bad\n", COMMIT)


class LaunchJobTests(unittest.TestCase):
    def test_user_requested_update_runs_as_a_standard_job(self):
        stage = Path("/private/var/empty/" + str(uuid.uuid4()))
        with patch.dict(os.environ, {"HOME": "/private/var/empty"}):
            definition = plistlib.loads(plistlib.dumps(updater.job_definition("label", stage, "prepare", "a" * 32)))
        self.assertEqual(definition["ProcessType"], "Standard")
        self.assertEqual(definition["ProgramArguments"][-3:], ["owned-prepare", str(stage), "a" * 32])
        self.assertEqual(definition["ProgramArguments"][:2], ["/usr/bin/env", "-i"])
        self.assertEqual((definition["KeepAlive"], definition["LaunchOnlyOnce"], definition["AbandonProcessGroup"]),
                         (False, True, False))


class ControllerMetadata:
    """Process metadata for one host, this controller and one worker (pid 777)."""
    def __init__(self):
        self.host = {"pid": os.getppid(), "uid": os.getuid(), "coalition": 1}
        self.controller = {"pid": os.getpid(), "uid": os.getuid(), "coalition": 2}
        self.worker = {"pid": 777, "uid": os.getuid(), "coalition": 3}
        self.dead = set()

    def identity(self, pid):
        for value in (self.host, self.controller, self.worker):
            if value["pid"] == pid and pid not in self.dead:
                return dict(value)
        return None

    def alive(self, identity):
        return identity["pid"] not in self.dead

    def members(self, coalition):
        return {777: self.worker} if coalition == 3 else {}

    def active(self, coalition, allow_reaped=False):
        return 0 if allow_reaped else 1


class ControllerRestoreTests(unittest.TestCase):
    """The real controller loop, with launchd and process metadata faked."""
    NONCE = "b" * 32

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.stage = Path(self.temporary.name).resolve() / str(uuid.uuid4())
        self.stage.mkdir(mode=0o700)
        files = [{"path": path, "sha256": "a" * 64, "mode": "100755"} for path in
                 ("Scripts/build-source-update.sh", "Scripts/source-update-sign.py", "Scripts/swiftpm-public.sh")]
        updater.write_json(self.stage / "job.json", {
            "schema": 1, "repository": "LorenzoColombani/openbots", "sourceCommit": COMMIT,
            "archiveURL": "https://codeload.github.com/LorenzoColombani/openbots/tar.gz/" + COMMIT,
            "build": "3008", "version": "1.1", "files": files, "installedApplication": "/Applications/OpenBots Next.app",
            "currentBuild": "3007", "googleClientID": "", "durableGoogleClientID": "", "parentPID": os.getppid()})
        self.meta = ControllerMetadata()
        self.stops = []
        launched = type("Result", (), {"returncode": 0, "stdout": b"", "stderr": b""})()
        self.patches = [patch.object(updater.processes, "Metadata", lambda: self.meta),
                        patch.object(updater.processes, "service_absent", lambda *_args, **_kwargs: True),
                        patch.object(updater.processes, "launchctl", lambda _arguments: launched),
                        patch.object(updater.processes, "same_identity", lambda *_args: True),
                        patch.object(updater.processes, "stop_entire_coalition", lambda _api, coalition: self.stops.append(coalition)),
                        patch.object(updater.processes, "remove_job", lambda *_args: None),
                        patch.object(updater, "CANCEL_FUSE", 0.2), patch.object(updater, "INSTALL_LIMIT", 0.5),
                        patch.object(updater, "RESTORE_LIMIT", 10)]
        for item in self.patches:
            item.start()
        self.handlers = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}

    def tearDown(self):
        for number, handler in self.handlers.items():
            signal.signal(number, handler)
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def wait_for(self, name):
        deadline = time.monotonic() + 5
        while not (self.stage / name).exists():
            if time.monotonic() > deadline:
                raise AssertionError("The controller never wrote " + name)
            time.sleep(0.02)

    def admit(self):
        self.wait_for("launch.json")
        updater.write_json(self.stage / "started.json", {"nonce": self.NONCE, "population": 1,
                                                         "identity": self.meta.worker, "coalition": 3})
        self.wait_for("admitted.json")

    def run_controller(self, worker_side):
        failures = []

        def guarded():
            try:
                worker_side()
            except BaseException as error:
                failures.append(error)

        thread = threading.Thread(target=guarded)
        thread.start()
        code = updater.controller_main(self.stage, "install", self.NONCE)
        thread.join(10)
        if failures:
            raise failures[0]
        return code

    def snapshot(self):
        return {"cancel": (self.stage / "cancel").exists(), "stops": list(self.stops),
                "error": (self.stage / "error.json").exists()}

    def test_marker_holds_off_the_cancel_write_the_fuse_and_the_time_limit(self):
        seen = []

        def worker_side():
            self.admit()
            updater.write_json(self.stage / updater.RESTORING, {"nonce": self.NONCE})
            # The host quits with no ready receipt: normally the controller cancels.
            self.meta.dead.add(self.meta.host["pid"])
            time.sleep(0.4)
            seen.append(self.snapshot())
            # A cancel already on disk, held past the fuse and the install limit.
            (self.stage / "cancel").touch()
            # A cancellation signal to the controller while restoring.
            updater.cancellation_file(self.stage)
            time.sleep(0.8)
            seen.append(self.snapshot())
            (self.stage / updater.RESTORING).unlink()
            updater.write_json(self.stage / "worker-stopped.json", {"nonce": self.NONCE, "coalition": 3,
                               "childrenStopped": True, "population": 1, "exitCode": 0})

        self.assertEqual(self.run_controller(worker_side), 0)
        self.assertEqual(seen, [{"cancel": False, "stops": [], "error": False},
                                {"cancel": True, "stops": [], "error": False}])
        self.assertFalse((self.stage / "error.json").exists())
        self.assertTrue(updater.private_json(self.stage / "stopped.json")["stopped"])

    def test_without_the_marker_the_fuse_still_stops_the_worker(self):
        def worker_side():
            self.admit()
            (self.stage / "cancel").touch()

        # The fuse (0.2 s) must be the deadline that fires, not the whole-install
        # limit: on a slow runner admission alone took longer than the 0.5 s limit
        # and the controller reported "failed" before the fuse could speak.
        with patch.object(updater, "INSTALL_LIMIT", 5):
            self.assertEqual(self.run_controller(worker_side), 1)
        self.assertEqual(updater.private_json(self.stage / "error.json")["code"], "cleanup_failed")
        self.assertEqual(self.stops, [3])

    def test_crash_recovery_never_stops_a_live_restore(self):
        launch = {"nonce": self.NONCE, "operation": "install", "service": updater.processes.service_name(self.NONCE),
                  "hostIdentity": self.meta.host, "controllerIdentity": self.meta.controller}
        updater.write_json(self.stage / "launch.json", launch)
        updater.write_json(self.stage / "started.json", {"nonce": self.NONCE, "population": 1,
                                                         "identity": self.meta.worker, "coalition": 3})
        updater.write_json(self.stage / "admitted.json", {"nonce": self.NONCE, "coalition": 3})
        updater.write_json(self.stage / updater.RESTORING, {"nonce": self.NONCE})
        self.meta.dead.add(self.meta.controller["pid"])
        self.assertEqual(updater.cleanup_main(self.stage, self.NONCE), 1)
        self.assertEqual(self.stops, [])
        self.assertFalse((self.stage / "cancel").exists())
        # Once the worker is gone, recovery proceeds as before.
        self.meta.dead.add(777)
        self.assertEqual(updater.cleanup_main(self.stage, self.NONCE), 0)
        self.assertEqual(self.stops, [3])

    def test_cancellation_file_is_refused_while_restoring(self):
        updater.write_json(self.stage / updater.RESTORING, {"nonce": self.NONCE})
        updater.cancellation_file(self.stage)
        self.assertFalse((self.stage / "cancel").exists())
        (self.stage / updater.RESTORING).unlink()
        updater.cancellation_file(self.stage)
        self.assertTrue((self.stage / "cancel").exists())


class FakeLiveness:
    def __init__(self):
        self.dead = set()

    def alive(self, identity):
        return identity["pid"] not in self.dead


class FakeWorker(updater.Worker):
    # Inherits the real Worker.check: a cancel file, a cancellation signal, a
    # dead controller or a passed deadline refuse exactly as in production.
    CONTROLLER = 2

    def __init__(self, stage, job):
        self.stage, self.job = stage, job
        self.allowed_after_exit = False
        self.cancelled = False
        self.api = FakeLiveness()
        self.host_identity = {"pid": job["parentPID"]}
        self.controller_identity = {"pid": self.CONTROLLER}
        self.deadline = time.monotonic() + 3600
        self.nonce = "a" * 32
        self.owner = type("FakeOwner", (), {"coalition": 99, "assert_alone": lambda _self: None})()
        self.fail_replacement_signature = False
        self.opens = []
        self.open_status = []
        self.events = []
        # ditto_hook(source, target) returns None to copy normally, or a status.
        self.ditto_hook = None

    def run(self, arguments, **_kwargs):
        self.check()
        if arguments[0] == "/usr/bin/open":
            self.opens.append(arguments[-1])
            self.events.append(("open", arguments[-1]))
            return (self.open_status.pop(0) if self.open_status else 0), b""
        if arguments[0] == updater.LSREGISTER:
            self.events.append(("lsregister", arguments[1], arguments[2]))
            return 0, b""
        if arguments[0] == "/usr/bin/ditto":
            source, target = Path(arguments[1]), Path(arguments[2])
            if target.exists() or target.is_symlink():
                raise AssertionError("ditto would merge into an existing folder: " + str(target))
            self.events.append(("ditto", str(source), str(target)))
            status = self.ditto_hook(source, target) if self.ditto_hook else None
            if status is not None:
                return status, b""
            shutil.copytree(source, target, symlinks=True)
            return 0, b""
        if arguments[0] != "/usr/bin/codesign":
            raise AssertionError("Unexpected external process: " + repr(arguments))
        if "--verify" in arguments:
            if (self.fail_replacement_signature and arguments[-1] == self.job["installedApplication"]
                    and updater.read_plist(Path(arguments[-1]))["CFBundleVersion"] == self.job["build"]):
                return 1, b"synthetic bad replacement"
            return 0, b""
        if "--entitlements" in arguments:
            return 0, plistlib.dumps({"com.apple.security.automation.apple-events": True})
        return 0, ("TeamIdentifier=" + TEAM + "\n").encode()


class FakeObserver:
    def __init__(self, _pid):
        pass
    def wait(self, worker):
        worker.check()
    def close(self):
        pass


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.stage = self.root / str(uuid.uuid4())
        self.stage.mkdir(mode=0o700)
        self.installed = self.root / updater.APP_NAME
        self.candidate = self.stage / "source" / updater.BUILD_RELATIVE
        self.job = {"installedApplication": str(self.installed), "currentBuild": "3007", "build": "3008", "version": "1.1",
                    "sourceCommit": COMMIT, "googleClientID": "", "durableGoogleClientID": "", "parentPID": 12345}
        self.make_app(self.installed, "3007", "old bytes")
        self.make_app(self.candidate, "3008", "new bytes")
        self.worker = FakeWorker(self.stage, self.job)
        self.old_fingerprint = updater.bundle_fingerprint(self.installed)
        updater.write_json(self.stage / "result.json", {"appURL": str(self.candidate), "fingerprint": updater.bundle_fingerprint(self.candidate),
                           "oldFingerprint": self.old_fingerprint, "team": TEAM})
        self.patches = [patch.object(updater, "NormalExitObserver", FakeObserver), patch.object(updater, "any_running_bundle", return_value=False),
                        patch.object(updater, "executable_path", return_value=str(self.installed / "Contents/MacOS/OpenBots Next"))]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def make_app(self, path, build, payload):
        executable = path / "Contents/MacOS/OpenBots Next"
        executable.parent.mkdir(parents=True)
        executable.write_text(payload)
        executable.chmod(0o755)
        info = {"CFBundleIdentifier": updater.BUNDLE_ID, "CFBundlePackageType": "APPL", "CFBundleExecutable": "OpenBots Next",
                "CFBundleVersion": build, "CFBundleShortVersionString": "1.1", "OpenBotsSourceCommit": COMMIT,
                "OpenBotsGoogleConfigurationVersion": 1}
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    @property
    def rollback(self):
        return self.root / "Rollback" / (".incoming-" + self.stage.name) / updater.APP_NAME

    @property
    def kept_rollback(self):
        # The one name both this installer and the bootstrap installer keep.
        return self.root / "Rollback" / updater.APP_NAME

    def older_rollback(self):
        (self.root / "Rollback").mkdir(mode=0o700)
        self.make_app(self.kept_rollback, "3006", "older bytes")
        self.make_app(self.root / "Rollback" / ".incoming-abandoned" / updater.APP_NAME, "3006", "abandoned bytes")
        return updater.bundle_fingerprint(self.kept_rollback)

    def receipt(self):
        value = updater.private_json(self.stage / "receipt.json")
        self.assertEqual(value, updater.private_json(self.root / "last-installation.json"))
        return value

    def partial_copy(self, source, target):
        # A copy that stops half way: one file of the bundle, then failure.
        (target / "Contents").mkdir(parents=True)
        shutil.copy2(source / "Contents/Info.plist", target / "Contents/Info.plist")
        return 1

    def install_failing(self):
        # owned_main turns any other exception into the generic failure message.
        with self.assertRaises((updater.UpdateError, OSError)):
            updater.install(self.worker)

    def altered_copy(self, source, target):
        shutil.copytree(source, target, symlinks=True)
        (target / "Contents/MacOS/OpenBots Next").write_text("altered")
        return 0

    def test_install_copies_never_moves_and_keeps_one_rollback(self):
        self.older_rollback()
        real_rename, real_replace = os.rename, os.replace

        def guarded(real):
            def move(source, target, *args, **kwargs):
                if Path(source) in (self.installed, self.candidate) or Path(target) == self.installed:
                    raise AssertionError("A bundle was moved: " + str(source))
                return real(source, target, *args, **kwargs)
            return move

        with patch.object(os, "rename", guarded(real_rename)), patch.object(os, "replace", guarded(real_replace)):
            updater.install(self.worker)
        self.assertEqual(updater.read_plist(self.installed)["CFBundleVersion"], "3008")
        self.assertEqual(updater.bundle_fingerprint(self.kept_rollback), self.old_fingerprint)
        self.assertEqual(sorted(path.name for path in (self.root / "Rollback").iterdir()), [updater.APP_NAME])
        # Nothing is left beside the installed app.
        self.assertEqual(sorted(path.name for path in self.root.iterdir()),
                         sorted([updater.APP_NAME, "Rollback", "last-installation.json", self.stage.name]))
        receipt = self.receipt()
        self.assertEqual((receipt["status"], receipt["rollback"]), ("installed", str(self.kept_rollback)))
        events = self.worker.events
        self.assertEqual(events[-1], ("open", str(self.installed)))
        for registration in (("lsregister", "-u", str(self.rollback)), ("lsregister", "-u", str(self.kept_rollback)),
                             ("lsregister", "-u", str(self.candidate)), ("lsregister", "-f", str(self.installed))):
            self.assertIn(registration, events[:-1])
        # The rollback is copied before the host is told to quit.
        self.assertEqual(events[0], ("ditto", str(self.installed), str(self.rollback)))

    def test_failed_post_replacement_validation_restores_and_reopens_old_app(self):
        older = self.older_rollback()
        self.worker.fail_replacement_signature = True
        self.install_failing()
        self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
        self.assertEqual(self.receipt()["status"], "rolledBack")
        self.assertNotIn("rollback", self.receipt())
        self.assertEqual(self.worker.opens, [str(self.installed)])
        # The restored app is its own copy; the older rollback is still the one kept.
        self.assertFalse(self.rollback.parent.exists())
        self.assertEqual(updater.bundle_fingerprint(self.kept_rollback), older)

    def test_failed_rollback_copy_leaves_the_app_untouched_and_unarmed(self):
        for name, hook in (("partial", self.partial_copy), ("mismatch", self.altered_copy)):
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                self.worker.ditto_hook = lambda source, target: hook(source, target) if target == self.rollback else None
                self.install_failing()
                self.assertFalse((self.stage / "ready.json").exists())
                self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
                self.assertEqual(self.receipt()["status"], "failed")
                self.assertFalse(self.rollback.parent.exists())
                self.assertEqual(self.worker.opens, [])
                self.assertIn(("lsregister", "-u", str(self.candidate)), self.worker.events)

    def test_installed_app_changed_after_quit_is_kept_and_reopened(self):
        def changed(observer, worker):
            (self.installed / "Contents/MacOS/OpenBots Next").write_text("changed while quitting")
        with patch.object(FakeObserver, "wait", changed):
            self.install_failing()
        self.assertEqual((self.installed / "Contents/MacOS/OpenBots Next").read_text(), "changed while quitting")
        self.assertEqual(self.receipt()["status"], "failed")
        self.assertFalse(self.rollback.parent.exists())
        self.assertEqual(self.worker.opens, [str(self.installed)])

    def test_failure_at_each_replacement_step_restores_the_previous_app(self):
        real_remove = updater.remove_bundle

        def partial_removal(path):
            if path == self.installed and not getattr(partial_removal, "done", False):
                partial_removal.done = True
                (path / "Contents/Info.plist").unlink()
                raise OSError("synthetic removal failure")
            return real_remove(path)

        def cancel_during_copy(source, target):
            if source == self.candidate:
                (self.stage / "cancel").touch()
            return None

        cases = (("removal", {"remove": partial_removal}),
                 ("copy", {"ditto": lambda source, target: self.partial_copy(source, target) if source == self.candidate else None}),
                 ("cancel", {"ditto": cancel_during_copy}),
                 ("signature", {"signature": True}),
                 ("reopen", {"open": [1, 0]}))
        for name, case in cases:
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                self.worker.ditto_hook = case.get("ditto")
                self.worker.fail_replacement_signature = case.get("signature", False)
                self.worker.open_status = list(case.get("open", []))
                with patch.object(updater, "remove_bundle", case.get("remove", real_remove)):
                    self.install_failing()
                self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
                self.assertEqual(self.receipt()["status"], "rolledBack")
                self.assertFalse((self.stage / "cancel").exists())
                self.assertEqual(self.worker.opens[-1], str(self.installed))
                self.assertEqual(self.worker.events[-1], ("open", str(self.installed)))
                self.assertIn(("lsregister", "-u", str(self.candidate)), self.worker.events)
                self.assertFalse(self.rollback.parent.exists())

    def test_failed_restore_keeps_the_rollback_and_names_it(self):
        self.worker.ditto_hook = lambda source, target: self.partial_copy(source, target) if target == self.installed else None
        self.install_failing()
        self.assertEqual(updater.bundle_fingerprint(self.rollback), self.old_fingerprint)
        receipt = self.receipt()
        self.assertEqual((receipt["status"], receipt["rollback"]), ("failed", str(self.rollback)))
        self.assertIn(str(self.rollback), receipt["message"])
        self.assertEqual(self.worker.opens, [])

    def test_app_relaunched_mid_replacement_is_never_pulled_out(self):
        running = iter([False, False, True])
        self.worker.ditto_hook = lambda source, target: self.partial_copy(source, target) if source == self.candidate else None
        with patch.object(updater, "any_running_bundle", side_effect=lambda _executable: next(running)):
            self.install_failing()
        receipt = self.receipt()
        self.assertEqual((receipt["status"], receipt["rollback"]), ("failed", str(self.rollback)))
        self.assertEqual(updater.bundle_fingerprint(self.rollback), self.old_fingerprint)
        self.assertEqual([event for event in self.worker.events if event[0] == "ditto"][-1][1], str(self.candidate))
        self.assertEqual(self.worker.opens, [])

    def test_restore_runs_to_the_end_whatever_would_stop_the_worker(self):
        triggers = (("cancel file", lambda: (self.stage / "cancel").touch()),
                    ("cancellation signal", lambda: setattr(self.worker, "cancelled", True)),
                    ("controller gone", lambda: self.worker.api.dead.add(FakeWorker.CONTROLLER)),
                    ("deadline passed", lambda: setattr(self.worker, "deadline", 0)))
        for name, fire in triggers:
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                seen = []

                def hook(source, target):
                    if source == self.candidate:
                        return self.partial_copy(source, target)
                    if source == self.rollback and target == self.installed:
                        # Mid-restore: the app is gone and the marker holds the controller off.
                        restoring = self.worker.restoring
                        seen.append(((self.stage / updater.RESTORING).exists(), restoring))
                        fire()
                        # The same trigger refuses any worker that is not restoring.
                        self.worker.restoring = False
                        with self.assertRaises(updater.UpdateError):
                            self.worker.check()
                        self.worker.restoring = restoring
                    return None

                self.worker.ditto_hook = hook
                self.install_failing()
                self.assertEqual(seen, [(True, True)])
                self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
                self.assertEqual(self.receipt()["status"], "rolledBack")
                self.assertEqual(self.worker.opens[-1], str(self.installed))
                self.assertFalse((self.stage / updater.RESTORING).exists())
                self.assertFalse(self.worker.restoring)

    def test_replacement_is_guarded_by_the_marker_and_cleared_after(self):
        seen = []
        self.worker.ditto_hook = lambda source, target: seen.append((self.stage / updater.RESTORING).exists()) \
            if source == self.candidate else None
        updater.install(self.worker)
        self.assertEqual(seen, [True])
        self.assertFalse((self.stage / updater.RESTORING).exists())

    def test_changed_candidate_cannot_arm_installer(self):
        (self.candidate / "Contents/MacOS/OpenBots Next").write_text("mutated")
        with self.assertRaises(updater.UpdateError):
            updater.install(self.worker)
        self.assertFalse((self.stage / "ready.json").exists())
        self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)

    def test_cancel_after_ack_preserves_running_app(self):
        def cancelled(observer, worker):
            worker.cancelled = True
            worker.check()
        with patch.object(FakeObserver, "wait", cancelled), self.assertRaises(updater.UpdateError):
            updater.install(self.worker)
        self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
        self.assertEqual(updater.private_json(self.stage / "receipt.json")["status"], "aborted")
        self.assertEqual(self.worker.opens, [])

    def test_another_running_copy_prevents_replacement(self):
        with patch.object(updater, "any_running_bundle", return_value=True), self.assertRaises(updater.UpdateError):
            updater.install(self.worker)
        self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
        self.assertEqual(self.worker.opens, [])

    def test_abnormal_host_exit_does_not_authorize_replacement_or_reopen(self):
        with patch.object(FakeObserver, "wait", side_effect=updater.UpdateError("Host did not exit normally")), self.assertRaises(updater.UpdateError):
            updater.install(self.worker)
        self.assertEqual(updater.bundle_fingerprint(self.installed), self.old_fingerprint)
        self.assertEqual(updater.private_json(self.stage / "receipt.json")["status"], "failed")
        self.assertEqual(self.worker.opens, [])

    def test_source_commit_team_and_google_must_match(self):
        info_path = self.candidate / "Contents/Info.plist"
        original = plistlib.loads(info_path.read_bytes())
        for field, value in (("OpenBotsSourceCommit", "b" * 40), ("CFBundleVersion", "3009"),
                             ("CFBundleIdentifier", "com.example.legacy"), ("OpenBotsGoogleOAuthClientID", "someone.apps.googleusercontent.com")):
            with self.subTest(field=field):
                info_path.write_bytes(plistlib.dumps(dict(original, **{field: value})))
                with self.assertRaises(updater.UpdateError):
                    updater.verify_bundle(self.candidate, self.job, self.worker.run, TEAM, candidate=True)
        info_path.write_bytes(plistlib.dumps(original))
        with self.assertRaises(updater.UpdateError):
            updater.verify_bundle(self.candidate, self.job, self.worker.run, "ZZZZZZZZZZ", candidate=True)

    def test_generic_google_requires_exact_durable_marker(self):
        job = dict(self.job, googleClientID="user.apps.googleusercontent.com", durableGoogleClientID="user.apps.googleusercontent.com")
        updater.google_compatible({"OpenBotsGoogleConfigurationVersion": 1}, job)
        for marker in (True, "1", 2, None):
            with self.subTest(marker=marker), self.assertRaises(updater.UpdateError):
                updater.google_compatible({"OpenBotsGoogleConfigurationVersion": marker}, job)

    def test_only_debugger_privilege_reduction_is_allowed(self):
        baseline = {"com.apple.security.automation.apple-events": True}
        debugging = dict(baseline, **{"com.apple.security.get-task-allow": True})
        self.assertTrue(updater.permissions_compatible(debugging, baseline))
        self.assertTrue(updater.permissions_compatible(debugging, dict(baseline, **{"com.apple.security.get-task-allow": False})))
        self.assertFalse(updater.permissions_compatible(baseline, debugging))
        self.assertFalse(updater.permissions_compatible(baseline, dict(baseline, **{"com.apple.security.cs.disable-library-validation": True})))
        self.assertFalse(updater.permissions_compatible(baseline, {}))


if __name__ == "__main__":
    unittest.main()
