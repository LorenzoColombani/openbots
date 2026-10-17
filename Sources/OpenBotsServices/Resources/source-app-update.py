#!/usr/bin/python3
"""Bundled source-update worker. No third-party Python modules or shell input.

Only Swift's authenticated manifest is admitted in job.json. This installed
worker, never a downloaded helper, owns extraction, processes and replacement.
"""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import select
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
import zlib

# -I/-S deliberately omit ordinary import paths. Load only the sibling resource
# sealed in the installed application, never anything from downloaded source.
_process_spec = importlib.util.spec_from_file_location("openbots_source_processes", Path(__file__).with_name("source-app-update-processes.py"))
processes = importlib.util.module_from_spec(_process_spec)
_process_spec.loader.exec_module(processes)

APP_NAME = "OpenBots Next.app"
BUNDLE_ID = "com.lorenzocolombani.openbotsnext.preview"
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_SOURCE = 512 * 1024 * 1024
MAX_TAR = 600 * 1024 * 1024
MAX_FILE = 64 * 1024 * 1024
MAX_FILES = 20000
MAX_LOG = 65536
MAX_BUNDLE = 2 * 1024 * 1024 * 1024
BUILD_RELATIVE = ".build.noindex/source-update/Build/Products/Release/" + APP_NAME
# Present from the removal of the installed app until it is back in place. While
# it exists nothing asks the worker to stop and the controller kills nothing.
RESTORING = "restoring.json"
CANCEL_FUSE = 18
# Worst case after Install: the host's two-minute ready wait, three minutes for
# it to quit, five for the replacement, then a restore bounded by its own
# command timeouts (a five-minute copy, the signature checks, the reopen).
INSTALL_LIMIT = 30 * 60
# While restoring, the controller waits past INSTALL_LIMIT for at most this long.
RESTORE_LIMIT = 30 * 60


class UpdateError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


def fail(message="The source update failed its verification checks.", code="failed"):
    raise UpdateError(message, code)


def private_directory(path):
    path = Path(path)
    for parent in [*reversed(path.parents), path]:
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode):
            fail("The update staging path is not a private directory.")
    info = path.lstat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail("The update staging directory is not private.")
    return path


def private_json(path, maximum=8 * 1024 * 1024):
    info = Path(path).lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
            or info.st_mode & 0o077 or not 0 <= info.st_size <= maximum):
        fail()
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail()
            result[key] = value
        return result
    with open(path, "rb") as stream:
        return json.load(stream, object_pairs_hook=unique)


def write_json(path, value):
    path = Path(path)
    # Controller/worker failures may arrive together. A uniquely owned file
    # avoids collisions and permits retry after an interrupted atomic write.
    fd, temporary_path = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(temporary_path)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def safe_path(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 1024
            or "\\" in value or ":" in value or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        fail("The source archive contains an unsafe path.")
    parts = value.split("/")
    if len(parts) > 64 or any(not p or p in (".", "..") or len(p.encode()) > 255 for p in parts):
        fail("The source archive contains an unsafe path.")
    return parts


def canonical(value):
    return unicodedata.normalize("NFC", value).lower()


def inventory(entries):
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_FILES:
        fail()
    result, names = {}, {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "mode"}:
            fail()
        path = entry["path"]
        parts = safe_path(path)
        if (path in result or not isinstance(entry["sha256"], str)
                or not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"])
                or entry["mode"] not in ("100644", "100755")
                or any(p in (".git", ".build") or p.endswith(".noindex") for p in parts)):
            fail()
        for count in range(1, len(parts) + 1):
            name = "/".join(parts[:count])
            key = canonical(name)
            if key in names and names[key] != name:
                fail("The source inventory contains ambiguous filenames.")
            names[key] = name
        result[path] = entry
    for path in result:
        if any(str(parent) in result for parent in PurePosixPath(path).parents):
            fail()
    if not {"Scripts/build-source-update.sh", "Scripts/source-update-sign.py", "Scripts/swiftpm-public.sh"} <= result.keys():
        fail("The source inventory is missing its reviewed build entrypoint.")
    return result


def validate_job(job):
    required = {"schema", "repository", "archiveURL", "sourceCommit", "build", "version", "files",
                "installedApplication", "currentBuild", "googleClientID", "durableGoogleClientID", "parentPID"}
    if not isinstance(job, dict) or set(job) != required or type(job["schema"]) is not int or job["schema"] != 1:
        fail()
    if (job["repository"] != "LorenzoColombani/openbots"
            or not re.fullmatch(r"[a-f0-9]{40}", job["sourceCommit"])
            or not re.fullmatch(r"[1-9][0-9]{0,17}", job["build"])
            or not re.fullmatch(r"[1-9][0-9]{0,17}", job["currentBuild"])
            or int(job["build"]) <= int(job["currentBuild"])
            or not re.fullmatch(r"(?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){1,3}", job["version"])
            or job["archiveURL"] != "https://codeload.github.com/" + job["repository"] + "/tar.gz/" + job["sourceCommit"]
            or type(job["parentPID"]) is not int or job["parentPID"] <= 1):
        fail()
    for key in ("googleClientID", "durableGoogleClientID"):
        value = job[key]
        if not isinstance(value, str) or (value and (len(value) > 512 or not re.fullmatch(r"[A-Za-z0-9.-]+\.apps\.googleusercontent\.com", value))):
            fail("The saved Google configuration is not valid for an update.")
    return inventory(job["files"])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fail("The immutable source archive unexpectedly redirected.")


def download_archive(url, target, check):
    # No proxy environment, cookies, netrc, credential store or auth handler.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, headers={"Accept": "application/gzip", "User-Agent": "OpenBots-Source-Updater/1"})
    deadline, count = time.monotonic() + 180, 0
    with opener.open(request, timeout=10) as response, open(target, "xb") as output:
        os.chmod(target, 0o600)
        if response.status != 200 or response.geturl() != url:
            fail("The source archive server returned an unexpected response.")
        length = response.headers.get("Content-Length")
        if length is not None and (not length.isdecimal() or int(length) > MAX_ARCHIVE):
            fail("The source archive exceeds its download limit.")
        while True:
            check()
            if time.monotonic() > deadline:
                fail("The source archive download timed out.")
            chunk = response.read(65536)
            if not chunk:
                break
            count += len(chunk)
            if count > MAX_ARCHIVE:
                fail("The source archive exceeds its download limit.")
            output.write(chunk)
        if count == 0 or (length is not None and count != int(length)):
            fail("The source archive download was incomplete.")


def inflate_archive(archive, output, check):
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    count = compressed = 0
    with open(archive, "rb") as source:
        try:
            target = open(output, "xb")
        except FileExistsError:
            # Never replace or clean up another operation's staging file.
            fail("The source archive staging file already exists. Prepare the update again.")
        try:
            with target:
                os.chmod(output, 0o600)
                while True:
                    chunk = source.read(65536)
                    if not chunk:
                        break
                    compressed += len(chunk)
                    if compressed > MAX_ARCHIVE or inflater.eof:
                        fail("The source archive is too large or contains appended data.")
                    while chunk:
                        check()
                        data = inflater.decompress(chunk, 65536)
                        count += len(data)
                        if count > MAX_TAR:
                            fail("The expanded source archive exceeds its limit.")
                        target.write(data)
                        chunk = inflater.unconsumed_tail
                        if inflater.unused_data:
                            fail("The source archive contains appended data.")
                if not inflater.eof or count == 0:
                    fail("The source archive is incomplete.")
        except BaseException:
            # Ownership began only after exclusive creation succeeded. Inflate
            # failures occur before extract_verified's cleanup scope starts.
            Path(output).unlink(missing_ok=True)
            raise


def pax_comment(data, commit):
    # git archive emits one global PAX comment containing the immutable commit.
    # No path/size/link overrides, GNU longnames, sparse files or local PAX.
    expected = "comment=" + commit + "\n"
    prefix, separator, body = data.partition(b" ")
    if not separator or not prefix.isdigit() or int(prefix) != len(data) or body != expected.encode():
        fail("The source archive contains unsupported metadata.")


def extract_verified(archive, destination, expected, commit, check=lambda: None):
    destination = Path(destination)
    destination.mkdir(mode=0o700)
    raw = destination.parent / "source.tar"
    inflate_archive(archive, raw, check)
    wrapper = "openbots-" + commit
    directories = {""}
    for name in expected:
        directories.update(str(parent) for parent in PurePosixPath(name).parents if str(parent) != ".")
    seen, actual, spellings = set(), set(), {}
    total, count, pax_seen, first = 0, 0, False, True
    try:
        with open(raw, "rb") as stream:
            while True:
                check()
                block = stream.read(512)
                if len(block) != 512:
                    fail("The source archive is truncated.")
                if block == bytes(512):
                    if stream.read(512) != bytes(512):
                        fail("The source archive has an invalid ending.")
                    while True:
                        rest = stream.read(65536)
                        if not rest:
                            break
                        check()
                        if any(rest):
                            fail("The source archive contains appended files.")
                    break
                entry = tarfile.TarInfo.frombuf(block, "utf-8", "strict")
                count += 1
                if count > MAX_FILES * 4 or entry.size < 0:
                    fail("The source archive has too many entries.")
                if entry.type == tarfile.XGLTYPE:
                    if not first or pax_seen or not 0 < entry.size <= 1024:
                        fail("The source archive contains unsupported metadata.")
                    pax_comment(stream.read(entry.size), commit)
                    stream.read((-entry.size) % 512)
                    pax_seen, first = True, False
                    continue
                first = False
                name = entry.name.rstrip("/") if entry.isdir() else entry.name
                parts = safe_path(name)
                if parts[0] != wrapper:
                    fail("The source archive has an unexpected root.")
                relative = "/".join(parts[1:])
                if name in seen or canonical(name) in spellings:
                    fail("The source archive repeats or aliases a path.")
                seen.add(name)
                spellings[canonical(name)] = name
                if entry.mode & 0o7000 or entry.linkname or entry.pax_headers:
                    fail("The source archive contains a link or special permission.")
                if entry.isdir():
                    if relative not in directories or entry.size != 0:
                        fail("The source archive contains an unlisted directory.")
                    if relative:
                        (destination / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
                elif entry.isreg():
                    if relative not in expected or entry.size > MAX_FILE:
                        fail("The source archive contains an unlisted or oversized file.")
                    item = expected[relative]
                    allowed_modes = (0o755, 0o775) if item["mode"] == "100755" else (0o644, 0o664)
                    if entry.mode not in allowed_modes:
                        fail("The source archive executable modes do not match the signed inventory.")
                    total += entry.size
                    if total > MAX_SOURCE:
                        fail("The source archive exceeds its expanded file limit.")
                    target = destination / relative
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    digest = hashlib.sha256()
                    with open(target, "xb") as out:
                        os.chmod(target, 0o700 if item["mode"] == "100755" else 0o600)
                        remaining = entry.size
                        while remaining:
                            check()
                            data = stream.read(min(65536, remaining))
                            if not data:
                                fail("The source archive is truncated.")
                            remaining -= len(data)
                            digest.update(data)
                            out.write(data)
                    if digest.hexdigest() != item["sha256"]:
                        fail("A source file does not match its signed SHA256.")
                    actual.add(relative)
                    padding = stream.read((-entry.size) % 512)
                    if len(padding) != (-entry.size) % 512 or any(padding):
                        fail("The source archive contains invalid padding.")
                else:
                    fail("The source archive contains an unsupported file or link.")
            if actual != expected.keys():
                fail("The source archive is missing signed files.")
        verify_source_tree(destination, expected, check)
    finally:
        raw.unlink(missing_ok=True)


def verify_source_tree(source, expected, check=lambda: None):
    actual = set()
    for directory, folders, files in os.walk(source, followlinks=False):
        for name in folders:
            if not stat.S_ISDIR((Path(directory) / name).lstat().st_mode):
                fail()
        for name in files:
            check()
            path = Path(directory) / name
            relative = path.relative_to(source).as_posix()
            info = path.lstat()
            if relative not in expected or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE:
                fail()
            item = expected[relative]
            if stat.S_IMODE(info.st_mode) != (0o700 if item["mode"] == "100755" else 0o600):
                fail()
            digest = hashlib.sha256()
            with open(path, "rb") as stream:
                while True:
                    data = stream.read(65536)
                    if not data:
                        break
                    check()
                    digest.update(data)
            if digest.hexdigest() != item["sha256"]:
                fail()
            actual.add(relative)
    if actual != expected.keys():
        fail()


def process_table():
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,lstart="], capture_output=True,
                            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}, timeout=3, check=True)
    table = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4 and all(value.isdecimal() for value in fields[:3]):
            table[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
    return table


def executable_path(pid):
    if sys.platform != "darwin":
        return None
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    buffer = ctypes.create_string_buffer(4096)
    result = library.proc_pidpath(int(pid), buffer, len(buffer))
    return os.fsdecode(buffer.value) if result > 0 else None


class Worker:
    restoring = False

    def __init__(self, stage, job, launch, metadata=None):
        self.stage, self.job = stage, job
        self.launch = launch
        self.nonce = launch["nonce"]
        self.api = metadata or processes.Metadata()
        self.cancelled = False
        self.allowed_after_exit = False
        self.child = None
        self.host_identity = launch["hostIdentity"]
        self.controller_identity = launch["controllerIdentity"]
        self.deadline = time.monotonic() + 40 * 60
        if (self.host_identity["pid"] != job["parentPID"] or not self.api.alive(self.host_identity)
                or not self.api.alive(self.controller_identity)):
            fail("The update host is no longer running.", "cancelled")
        self.owner = processes.CoalitionOwner(self.api, self.host_identity, self.controller_identity)

    def admit(self):
        self.check()
        self.owner.assert_alone()
        write_json(self.stage / "started.json", {"nonce": self.nonce, "identity": self.owner.identity,
                                                "coalition": self.owner.coalition, "population": 1})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.check()
            path = self.stage / "admitted.json"
            if path.exists():
                value = private_json(path, maximum=16384)
                if value == {"nonce": self.nonce, "coalition": self.owner.coalition}:
                    self.owner.assert_alone()
                    return
                fail("The source update startup handoff did not match this run.")
            time.sleep(0.05)
        fail("The source update host did not acknowledge its private worker.")

    def check(self):
        # Once the installed app is gone only putting it back matters: no cancel,
        # deadline, host or controller state stops a restore half way. Each of its
        # commands is still bounded by its own timeout.
        if self.restoring:
            return
        if (self.cancelled or (self.stage / "cancel").exists()
                or not self.api.alive(self.controller_identity)
                or (not self.allowed_after_exit and not self.api.alive(self.host_identity))):
            fail("The source update was cancelled.", "cancelled")
        if time.monotonic() > self.deadline:
            fail("The source update exceeded its time limit.")

    def progress(self, stage):
        write_json(self.stage / "progress.json", {"stage": stage})

    def stop_children(self):
        def reap():
            if self.child is not None:
                self.child.poll()
        self.owner.stop_children(reap=reap)
        if self.child is not None:
            self.child.wait(timeout=1)
            self.child = None

    def run(self, arguments, timeout=30, cwd=None, environment=None):
        self.check()
        env = environment or {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "HOME": os.environ["HOME"]}
        self.child = subprocess.Popen(arguments, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        output_stream = self.child.stdout
        output = bytearray()
        selector = selectors.DefaultSelector()
        selector.register(output_stream, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        try:
            while True:
                self.check()
                now = time.monotonic()
                if now > deadline:
                    fail("An update build or verification command timed out.")
                for key, _ in selector.select(0.1):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if data:
                        output.extend(data)
                        del output[:-MAX_LOG]
                    else:
                        selector.unregister(key.fileobj)
                code = self.child.poll()
                if code is not None and not selector.get_map():
                    break
            # A command cannot leave background workers running even on success.
            self.stop_children()
            return code, bytes(output)
        finally:
            selector.close()
            try:
                self.stop_children()
            finally:
                output_stream.close()


def read_plist(app):
    path = Path(app) / "Contents/Info.plist"
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
        fail("The built application has invalid identity metadata.")
    with open(path, "rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        fail()
    return value


def google_compatible(info, job):
    embedded = info.get("OpenBotsGoogleOAuthClientID", "")
    if not isinstance(embedded, str):
        fail("The update does not preserve the Google connection configuration.")
    required = job["googleClientID"]
    if embedded:
        if embedded != required:
            fail("The update does not preserve the Google connection configuration.")
    elif required:
        marker = info.get("OpenBotsGoogleConfigurationVersion")
        if job["durableGoogleClientID"] != required or type(marker) is not int or marker != 1:
            fail("Save the existing Google configuration before installing this update.")


def bundle_fingerprint(app, check=lambda: None):
    app = Path(app)
    if not stat.S_ISDIR(app.lstat().st_mode):
        fail("The application bundle path is not a real directory.")
    digest, total, entries, names = hashlib.sha256(), 0, 0, set()
    for directory, folders, files in os.walk(app, followlinks=False):
        folders.sort(); files.sort()
        for name in sorted(folders + files):
            check()
            entries += 1
            if entries > 100000:
                fail("The application bundle exceeds its file limit.")
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            safe_path(relative)
            key = canonical(relative)
            if key in names:
                fail("The application bundle has ambiguous paths.")
            names.add(key)
            info = path.lstat()
            digest.update(relative.encode() + b"\0" + str(info.st_mode).encode() + b"\0")
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                if os.path.isabs(target) or not path.exists() or not path.resolve().is_relative_to(app.resolve()):
                    fail("The application contains a link outside its bundle.")
                digest.update(b"L" + os.fsencode(target) + b"\0")
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > MAX_BUNDLE or info.st_nlink != 1:
                    fail("The application bundle exceeds its size limit or contains hard links.")
                digest.update(b"F" + str(info.st_size).encode() + b"\0")
                with open(path, "rb") as stream:
                    while True:
                        data = stream.read(65536)
                        if not data:
                            break
                        check()
                        digest.update(data)
            elif stat.S_ISDIR(info.st_mode):
                digest.update(b"D")
            else:
                fail("The application bundle contains a special file.")
    return digest.hexdigest()


def verify_bundle(app, job, run, expected_team=None, candidate=False, check=lambda: None):
    app = Path(app)
    if (not app.is_absolute() or app.is_symlink() or app.resolve() != app
            or app.name != APP_NAME):
        fail("Only the current OpenBots Next application can be replaced.")
    info = read_plist(app)
    executable = info.get("CFBundleExecutable")
    if (info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundlePackageType") != "APPL"
            or not isinstance(executable, str) or len(safe_path(executable)) != 1
            or not (app / "Contents/MacOS" / executable).is_file()
            or info.get("CFBundleVersion") != (job["build"] if candidate else job["currentBuild"])):
        fail("The application identity or ordered build does not match this update.")
    if candidate and (info.get("CFBundleShortVersionString") != job["version"] or info.get("OpenBotsSourceCommit") != job["sourceCommit"]):
        fail("The built application does not match the reviewed source release.")
    google_compatible(info, job)
    fingerprint = bundle_fingerprint(app, check)
    status, _ = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=60)
    if status:
        fail("The application code signature could not be verified.")
    status, metadata = run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)])
    match = re.search(rb"^TeamIdentifier=([A-Z0-9]{10})$", metadata, re.MULTILINE)
    if status or match is None:
        fail("A valid local Apple Development signing identity is required. Open Xcode to finish your existing signing setup.")
    team = match.group(1).decode("ascii")
    if expected_team is not None and team != expected_team:
        fail("The built application uses a different signing team from the installed app.")
    status, entitlements = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)])
    # The display lines ("Executable=…") share the captured stream with the
    # entitlements plist; parse only the plist itself, wherever it sits.
    start = entitlements.find(b"<?xml")
    if start < 0:
        start = entitlements.find(b"<plist")
    end = entitlements.find(b"</plist>", start) if start >= 0 else -1
    try:
        if start >= 0 and end < 0:
            raise ValueError("unterminated plist")
        permissions = plistlib.loads(entitlements[start:end + len(b"</plist>")]) if start >= 0 else {}
    except Exception:
        fail("The application's signing permissions could not be verified.")
    if status or not isinstance(permissions, dict):
        fail("The application's signing permissions could not be verified.")
    return {"team": team, "fingerprint": fingerprint, "entitlements": permissions,
            "executable": str(app / "Contents/MacOS" / executable)}


def permissions_compatible(previous, candidate):
    # Release builds may remove the Debug-only debugger entitlement. No other
    # change and no new entitlement (including an explicit false key) is added.
    before, after = dict(previous), dict(candidate)
    key = "com.apple.security.get-task-allow"
    if before.get(key) is True and (key not in after or after[key] is False):
        before.pop(key)
        after.pop(key, None)
    return plistlib.dumps(before, sort_keys=True) == plistlib.dumps(after, sort_keys=True)


def prepare(worker, expected):
    stage, job = worker.stage, worker.job
    installed = Path(job["installedApplication"])
    worker.progress("verifying")
    old = verify_bundle(installed, job, worker.run, check=worker.check)
    worker.progress("downloading")
    archive = stage / "source.tar.gz"
    download_archive(job["archiveURL"], archive, worker.check)
    worker.progress("verifying")
    source = stage / "source"
    extract_verified(archive, source, expected, job["sourceCommit"], worker.check)
    archive.unlink()
    worker.check()
    worker.progress("building")
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": os.environ["HOME"],
           "LANG": "en_US.UTF-8", "TMPDIR": str(stage), "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
           "SSH_ASKPASS": "/usr/bin/false", "NETRC": "/dev/null"}
    arguments = ["/bin/zsh", "-f", str(source / "Scripts/build-source-update.sh"), "--commit", job["sourceCommit"],
                 "--build", job["build"], "--version", job["version"], "--team", old["team"],
                 "--google-client-id", job["googleClientID"]]
    status, log = worker.run(arguments, timeout=35 * 60, cwd=source, environment=env)
    with open(stage / "build.log", "xb") as stream:
        os.chmod(stage / "build.log", 0o600)
        stream.write(log[-MAX_LOG:])
    if status:
        fail("The local source build failed. Check that full Xcode and your existing Apple Development signing identity are available, then retry. The current app is unchanged.")
    worker.progress("validating")
    candidate = source / BUILD_RELATIVE
    fresh = verify_bundle(candidate, job, worker.run, old["team"], candidate=True, check=worker.check)
    if not permissions_compatible(old["entitlements"], fresh["entitlements"]):
        fail("The built application's signing permissions differ from this installation.")
    # Rechecking the old bundle closes the long build's configuration/identity gap.
    unchanged = verify_bundle(installed, job, worker.run, old["team"], check=worker.check)
    if unchanged["fingerprint"] != old["fingerprint"]:
        fail("The installed app changed while the source update was building. Prepare the update again.")
    # Xcode registers what it builds. A newer build Launch Services knows could
    # be opened by bundle id against data the installed app then cannot read.
    register(worker, "-u", candidate)
    worker.check()
    write_json(stage / "result.json", {"appURL": str(candidate), "fingerprint": fresh["fingerprint"],
                                      "oldFingerprint": old["fingerprint"], "team": old["team"]})


def write_receipt(worker, status, message, rollback=None):
    value = {"status": status, "message": message, "build": worker.job["build"], "sourceCommit": worker.job["sourceCommit"]}
    if rollback is not None:
        value["rollback"] = str(rollback)
    write_json(worker.stage / "receipt.json", value)
    write_json(worker.stage.parent / "last-installation.json", value)


LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def copy_bundle(worker, source, target):
    # ditto keeps signatures, extended attributes and internal framework links;
    # every copy is fingerprinted again before anything relies on it. ditto
    # merges into an existing folder, so the target must not exist yet.
    if target.exists() or target.is_symlink():
        fail("An application copy target already exists.")
    status, _ = worker.run(["/usr/bin/ditto", str(source), str(target)], timeout=300)
    if status:
        fail("An application bundle could not be copied.")


def remove_bundle(path):
    # rmtree never follows a link inside the bundle; a link in its place is unlinked.
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def register(worker, option, app):
    # Launch Services bookkeeping only: a failure never changes the outcome.
    try:
        worker.run([LSREGISTER, option, str(app)], timeout=30)
    except Exception:
        pass


def promote_rollback(worker, rollbacks, rollback):
    # One installed app and one rollback copy, at the name the bootstrap
    # installer shares: Rollback/OpenBots Next.app. The older copy and any other
    # incoming folder go, then this private, unregistered copy is renamed in;
    # the installed bundle itself is never renamed. Returns where the copy is.
    final = rollbacks / APP_NAME
    try:
        for entry in rollbacks.iterdir():
            if entry == final or (entry.name.startswith(".incoming-") and entry != rollback.parent):
                remove_bundle(entry)
        os.rename(rollback, final)
        rollback.parent.rmdir()
    except OSError:
        return rollback if rollback.exists() else final
    register(worker, "-u", final)
    return final


def discard_rollback(rollback):
    # Removes this operation's copy, whether still incoming or already promoted.
    try:
        remove_bundle(rollback.parent if rollback.parent.name.startswith(".incoming-") else rollback)
    except OSError:
        pass


def restore(worker, job, rollback, installed, old):
    # Copied back, never moved. A copy that cannot be proved leaves the
    # rollback where the receipt names it.
    try:
        remove_bundle(installed)
        copy_bundle(worker, rollback, installed)
        back = verify_bundle(installed, job, worker.run, old["team"], check=worker.check)
        return back["fingerprint"] == old["fingerprint"]
    except Exception:
        return False


def any_running_bundle(executable):
    for pid in process_table():
        if executable_path(pid) == executable:
            return True
    return False


class NormalExitObserver:
    """Kernel-bound process identity and exit status, registered before ACK.

    A vanished/reused PID or crash is never accepted as a normal Quit. Darwin's
    NOTE_EXITSTATUS is allowed for a same-UID process, including our parent.
    """
    def __init__(self, pid):
        if not hasattr(select, "kqueue"):
            fail("The source installer requires macOS process-exit monitoring.")
        self.queue = select.kqueue()
        self.pid = pid
        flags = select.KQ_NOTE_EXIT | 0x04000000  # NOTE_EXITSTATUS
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT, fflags=flags)
        self.queue.control([event], 0, 0)

    def wait(self, worker):
        while True:
            worker.check()
            for event in self.queue.control(None, 1, 0.1):
                if (event.ident != self.pid or event.flags & select.KQ_EV_ERROR
                        or not event.fflags & select.KQ_NOTE_EXIT or event.data != 0):
                    fail("OpenBots Next did not exit normally. The current app was preserved.")
                return

    def close(self):
        self.queue.close()


def install(worker):
    stage, job = worker.stage, worker.job
    prepared = private_json(stage / "result.json", maximum=16384)
    candidate = stage / "source" / BUILD_RELATIVE
    installed = Path(job["installedApplication"])
    if prepared.get("appURL") != str(candidate):
        fail()
    fresh = verify_bundle(candidate, job, worker.run, prepared.get("team"), candidate=True, check=worker.check)
    old = verify_bundle(installed, job, worker.run, fresh["team"], check=worker.check)
    if (fresh["fingerprint"] != prepared.get("fingerprint") or old["fingerprint"] != prepared.get("oldFingerprint")
            or not permissions_compatible(old["entitlements"], fresh["entitlements"])):
        fail("The candidate or installed app changed. Prepare the update again.")
    if executable_path(job["parentPID"]) != old["executable"]:
        fail("The update host is not running from the application being replaced.")
    # UUID is created by the host and also names its private operation directory.
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", stage.name):
        fail()
    # The previous app is copied, never moved: Launch Services and the Dock
    # follow a moved bundle and can launch that stale build against newer data.
    # The copy lives in the app's own update area, outside every swept stage.
    rollbacks = stage.parent / "Rollback"
    if not rollbacks.exists() and not rollbacks.is_symlink():
        rollbacks.mkdir(mode=0o700)
    private_directory(rollbacks)
    rollback = rollbacks / (".incoming-" + stage.name) / APP_NAME
    if rollback.parent.exists() or rollback.parent.is_symlink():
        fail("A previous update transaction needs attention before retrying.")
    (stage / RESTORING).unlink(missing_ok=True)
    observer = NormalExitObserver(job["parentPID"])
    kept = replacing = normal_exit_confirmed = False
    try:
        rollback.parent.mkdir(mode=0o700)
        kept = True
        copy_bundle(worker, installed, rollback)
        register(worker, "-u", rollback)
        copied = verify_bundle(rollback, job, worker.run, old["team"], check=worker.check)
        if copied["fingerprint"] != old["fingerprint"]:
            fail("The copy of the current app did not match it. The current app is unchanged.")
        worker.check()
        worker.owner.assert_alone()
        write_json(stage / "ready.json", {"ready": True, "nonce": worker.nonce,
                                          "coalition": worker.owner.coalition, "population": 1})
        worker.allowed_after_exit = True
        worker.deadline = time.monotonic() + 180
        observer.wait(worker)
        normal_exit_confirmed = True
        # No force quit, kill, or overwrite of any running application.
        if any_running_bundle(old["executable"]):
            fail("OpenBots Next is still running. The update was not installed.")
        # The replacement's own limit; a restore after it is not bound by this.
        worker.deadline = time.monotonic() + 300
        rechecked = verify_bundle(installed, job, worker.run, old["team"], check=worker.check)
        final = verify_bundle(candidate, job, worker.run, old["team"], candidate=True, check=worker.check)
        if rechecked["fingerprint"] != old["fingerprint"] or final["fingerprint"] != fresh["fingerprint"]:
            fail("An application changed before installation. The current app was preserved.")
        worker.check()
        if any_running_bundle(old["executable"]):
            fail("OpenBots Next restarted before replacement. The update was not installed.")
        # Written first, so an interruption from here on still names the copy.
        write_receipt(worker, "failed", "The update stopped while replacing the app. A copy of the previous app is kept at "
                      + str(rollback) + ".", rollback)
        write_json(stage / RESTORING, {"nonce": worker.nonce})
        replacing = True
        remove_bundle(installed)
        copy_bundle(worker, candidate, installed)
        actual = verify_bundle(installed, job, worker.run, old["team"], candidate=True, check=worker.check)
        if actual["fingerprint"] != fresh["fingerprint"]:
            fail("The installed update did not match its verified build.")
        (stage / RESTORING).unlink()
        # Recorded before reopening: the new app starts while this worker runs.
        register(worker, "-u", candidate)
        register(worker, "-f", installed)
        rollback = promote_rollback(worker, rollbacks, rollback)
        write_receipt(worker, "installed", "The source update was installed and reopening was requested. "
                      "A copy of the previous app is kept for recovery.", rollback)
        status, _ = worker.run(["/usr/bin/open", "-a", str(installed)], timeout=15)
        if status:
            fail("The updated app could not be reopened.")
    except Exception as error:
        # This transaction owns only the installed app and its own rollback
        # copy. It never touches content, preferences or Keychain.
        cancelled = isinstance(error, UpdateError) and error.code == "cancelled"
        if replacing:
            # From here the worker ignores cancel files, deadlines and the
            # controller (Worker.check), and the marker keeps the controller
            # from arming its kill or writing cancel until install() returns.
            if not (stage / RESTORING).exists():
                write_json(stage / RESTORING, {"nonce": worker.nonce})
            worker.restoring = True
            worker.cancelled = False
            worker.allowed_after_exit = True
            (stage / "cancel").unlink(missing_ok=True)
            # A newer build Launch Services still knows could be opened by bundle id.
            register(worker, "-u", candidate)
            if any_running_bundle(old["executable"]):
                write_receipt(worker, "failed", "The update needs recovery. A copy of the previous app is kept at "
                              + str(rollback) + ".", rollback)
                raise
            if restore(worker, job, rollback, installed, old):
                register(worker, "-f", installed)
                # The copy now duplicates the installed app; an older rollback
                # stays unless this copy had already replaced it.
                discard_rollback(rollback)
                status, _ = worker.run(["/usr/bin/open", "-a", str(installed)], timeout=15)
                write_receipt(worker, "rolledBack", "The update failed and the previous app was restored."
                              + (" Reopening was requested." if status == 0 else " Open OpenBots Next again."))
            else:
                write_receipt(worker, "failed", "The update failed and the previous app could not be put back. A copy of it "
                              "is kept at " + str(rollback) + "; copy it to " + str(installed) + " to restore it.", rollback)
        else:
            # After an abort the cancel file refuses this; prepare already did it.
            register(worker, "-u", candidate)
            write_receipt(worker, "aborted" if cancelled else "failed",
                          "The source update was cancelled; the current app is unchanged." if cancelled
                          else "The source update was not installed; the current app is unchanged.")
            if kept:
                discard_rollback(rollback)
            # A normal host exit followed by validation failure still reopens
            # the unchanged old app. An explicit abort never launches anything.
            if normal_exit_confirmed and not cancelled:
                if not any_running_bundle(old["executable"]):
                    worker.deadline = time.monotonic() + 30
                    worker.run(["/usr/bin/open", "-a", str(installed)], timeout=15)
        raise
    finally:
        observer.close()
        worker.restoring = False
        (stage / RESTORING).unlink(missing_ok=True)


def owned_main(stage, operation, nonce):
    worker = None
    launch = None
    code, stopped, coalition = 1, True, None
    try:
        job = private_json(stage / "job.json")
        expected = validate_job(job)
        launch = private_json(stage / "launch.json", maximum=16384)
        if (set(launch) != {"nonce", "operation", "service", "hostIdentity", "controllerIdentity"}
                or launch["nonce"] != nonce or launch["operation"] != operation
                or launch["service"] != processes.service_name(nonce)):
            fail("The source update startup handoff is invalid.")
        worker = Worker(stage, job, launch)
        coalition = worker.owner.coalition
        def cancel(_signal, _frame):
            worker.cancelled = True
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        worker.admit()
        if operation == "prepare":
            prepare(worker, expected)
        else:
            install(worker)
        worker.stop_children()
        worker.owner.assert_alone()
        code = 0
    except BaseException as error:
        try:
            if worker is not None:
                worker.stop_children()
                worker.owner.assert_alone()
        except BaseException:
            stopped = False
            error = UpdateError("The update worker could not confirm all build processes stopped. Keep the app open.", "cleanup_failed")
        message = str(error)[:1024] if isinstance(error, UpdateError) else "The source update could not finish. The current app remains available; retry the update."
        write_json(stage / "error.json", {"code": error.code if isinstance(error, UpdateError) else "failed", "message": message})
    finally:
        write_json(stage / "worker-stopped.json", {"nonce": nonce, "childrenStopped": stopped,
                   "coalition": coalition, "population": 1 if stopped and coalition is not None else None, "exitCode": code})
        # If the controller died, our parent watchdog has already cancelled the
        # operation and reaped its complete coalition. Remove our exact job;
        # never leave a persistent service or invoke a domain-wide bootout.
        if worker is not None and stopped:
            try:
                if not worker.api.alive(worker.controller_identity):
                    processes.launchctl(["bootout", launch["service"]])
            except BaseException:
                pass  # No clean host receipt is emitted by this worker.
    return code


def cancellation_file(stage):
    # Never while the installed app is being put back: see RESTORING.
    path = stage / "cancel"
    if not (stage / RESTORING).exists() and not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)


def job_definition(label, stage, operation, nonce):
    # env -i removes any launchd-manager environment. These are fixed
    # arguments, with no shell or source-provided executable/command.
    arguments = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8",
                 "HOME=" + os.environ["HOME"], "TMPDIR=" + str(stage),
                 "/usr/bin/python3", "-I", "-B", "-S", str(Path(__file__).resolve()),
                 "owned-" + operation, str(stage), nonce]
    # Standard, not Background: the person asked for this update and is waiting
    # on it. Background throttles CPU and I/O onto the efficiency cores, which a
    # full Xcode build under a 35-minute cap cannot afford.
    return {"Label": label, "RunAtLoad": True, "KeepAlive": False, "LaunchOnlyOnce": True,
            "ProcessType": "Standard", "AbandonProcessGroup": False, "ExitTimeOut": 3,
            "ProgramArguments": arguments, "WorkingDirectory": str(stage),
            "StandardInPath": "/dev/null", "StandardOutPath": str(stage / "job-stdout.log"),
            "StandardErrorPath": str(stage / "job-stderr.log")}


def controller_main(stage, operation, nonce):
    """One transient launchd job, with a positive final kernel cleanup receipt."""
    service = processes.service_name(nonce)
    domain, label = service.rsplit("/", 1)
    api, coalition, started_identity = None, None, None
    owns_label = admitted = False
    code, stopped = 1, False
    plist = stage / ("launch-" + nonce + ".plist")
    try:
        job = private_json(stage / "job.json")
        validate_job(job)
        api = processes.Metadata()
        host = api.identity(job["parentPID"])
        controller = api.identity(os.getpid())
        if host is None or controller is None or host["uid"] != os.getuid() or os.getppid() != host["pid"]:
            fail("The source update host is no longer running.", "cancelled")
        # Never adopt or unload a preexisting label, even on an improbable UUID
        # collision. An ambiguous bootstrap outcome is ours only after this gate.
        if not processes.service_absent(service):
            fail("The private update job name is already in use. Prepare the update again.")
        owns_label = True
        launch = {"nonce": nonce, "operation": operation, "service": service,
                  "hostIdentity": host, "controllerIdentity": controller}
        write_json(stage / "launch.json", launch)
        for name in ("job-stdout.log", "job-stderr.log"):
            fd = os.open(stage / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            os.close(fd)
        with open(plist, "xb") as stream:
            os.chmod(plist, 0o600)
            stream.write(plistlib.dumps(job_definition(label, stage, operation, nonce)))
        def cancel(_signal, _frame):
            cancellation_file(stage)
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        result = processes.launchctl(["bootstrap", domain, str(plist)])
        if result.returncode:
            fail("The private source update job could not start.")
        startup_deadline = time.monotonic() + 12
        deadline = time.monotonic() + (45 * 60 if operation == "prepare" else INSTALL_LIMIT)
        hard_deadline = deadline + RESTORE_LIMIT
        cancellation_deadline = None
        while True:
            restoring = (stage / RESTORING).exists()
            if restoring:
                # The worker keeps a minute to report once the app is back.
                deadline = max(deadline, min(time.monotonic() + 60, hard_deadline))
            if time.monotonic() >= deadline:
                fail("The source update exceeded its time limit.")
            if not api.alive(host):
                ready = None
                if operation == "install" and (stage / "ready.json").exists():
                    ready = private_json(stage / "ready.json", maximum=16384)
                if not (ready and ready.get("nonce") == nonce and ready.get("ready") is True):
                    cancellation_file(stage)
            if restoring:
                # A cancel seen earlier cannot fire while the app is put back.
                cancellation_deadline = None
            elif (stage / "cancel").exists() and cancellation_deadline is None:
                cancellation_deadline = time.monotonic() + CANCEL_FUSE
            if cancellation_deadline is not None and time.monotonic() >= cancellation_deadline:
                fail("The source update did not stop in time.", "cleanup_failed")
            if not admitted and (stage / "started.json").exists():
                startup = private_json(stage / "started.json", maximum=16384)
                identity = startup.get("identity")
                candidate_coalition = startup.get("coalition")
                if (startup.get("nonce") != nonce or startup.get("population") != 1
                        or not isinstance(identity, dict) or identity.get("coalition") != candidate_coalition
                        or candidate_coalition in (host["coalition"], controller["coalition"])
                        or not processes.same_identity(identity, api.identity(identity["pid"]))
                        or set(api.members(candidate_coalition)) != {identity["pid"]}
                        or api.active(candidate_coalition) != 1):
                    fail("The private update worker could not prove isolation.")
                coalition, started_identity = candidate_coalition, identity
                if (stage / "cancel").exists():
                    fail("The source update was cancelled.", "cancelled")
                write_json(stage / "admitted.json", {"nonce": nonce, "coalition": coalition})
                admitted = True
            if (stage / "worker-stopped.json").exists():
                outcome = private_json(stage / "worker-stopped.json", maximum=16384)
                if outcome.get("nonce") != nonce:
                    fail("The update completion receipt did not match this run.")
                if admitted and (outcome.get("coalition") != coalition or outcome.get("childrenStopped") is not True
                                 or outcome.get("population") != 1):
                    fail("The update worker did not confirm descendant cleanup.", "cleanup_failed")
                code = 0 if admitted and outcome.get("exitCode") == 0 else 1
                break
            if admitted and not api.alive(started_identity):
                fail("The private update worker stopped unexpectedly.")
            if not admitted and time.monotonic() >= startup_deadline:
                fail("The private update worker did not become ready in time.")
            time.sleep(0.1)
    except BaseException as error:
        cancellation_file(stage)
        message = str(error)[:1024] if isinstance(error, UpdateError) else "The private update worker could not finish safely. The current app remains available."
        write_json(stage / "error.json", {"code": error.code if isinstance(error, UpdateError) else "failed", "message": message})
    finally:
        try:
            if coalition is not None:
                # Allow an acknowledged worker to finish writing and exit. A
                # crash or timeout is recovered using its proven whole cohort.
                end = time.monotonic() + 1
                while api.active(coalition, allow_reaped=True) and time.monotonic() < end:
                    time.sleep(0.05)
                processes.stop_entire_coalition(api, coalition)
            if owns_label:
                processes.remove_job(service, coalition, api)
            stopped = True
        except BaseException:
            code = 1
            write_json(stage / "error.json", {"code": "cleanup_failed",
                       "message": "The update job has not confirmed full shutdown and removal. Keep the app open and retry cancellation."})
        if stopped:
            plist.unlink(missing_ok=True)
        write_json(stage / "stopped.json", {"nonce": nonce, "stopped": stopped,
                   "jobRemoved": stopped, "resourceCoalitionEmpty": stopped})
    return code


def cleanup_main(stage, nonce):
    """Bounded retry for one crashed/failed controller, never a new build."""
    stopped = False
    try:
        api = processes.Metadata()
        launch = private_json(stage / "launch.json", maximum=16384)
        service = processes.service_name(nonce)
        if launch.get("nonce") != nonce or launch.get("service") != service:
            fail("The update cleanup receipt does not match this run.", "cleanup_failed")
        if api.alive(launch["controllerIdentity"]):
            fail("The original update controller is still running.", "cleanup_failed")
        cancellation_file(stage)
        coalition = None
        if (stage / "admitted.json").exists():
            admitted = private_json(stage / "admitted.json", maximum=16384)
            started = private_json(stage / "started.json", maximum=16384)
            coalition = admitted.get("coalition")
            if (admitted.get("nonce") != nonce or started.get("nonce") != nonce
                    or started.get("population") != 1 or started.get("coalition") != coalition
                    or started.get("identity", {}).get("coalition") != coalition
                    or coalition in (launch["hostIdentity"]["coalition"], launch["controllerIdentity"]["coalition"])):
                fail("The update cleanup ownership receipt is invalid.", "cleanup_failed")
            # A live worker putting the installed app back is never stopped.
            if (stage / RESTORING).exists() and api.alive(started["identity"]):
                fail("The previous app is still being put back.", "cleanup_failed")
            processes.stop_entire_coalition(api, coalition)
        # Without admission the trusted worker cannot start any source command.
        processes.remove_job(service, coalition, api)
        (stage / ("launch-" + nonce + ".plist")).unlink(missing_ok=True)
        stopped = True
    except BaseException:
        write_json(stage / "error.json", {"code": "cleanup_failed",
                   "message": "The update job has not confirmed full shutdown and removal. Keep the app open and retry cancellation."})
    write_json(stage / "stopped.json", {"nonce": nonce, "stopped": stopped,
               "jobRemoved": stopped, "resourceCoalitionEmpty": stopped})
    return 0 if stopped else 1


def main(arguments):
    os.umask(0o077)
    if len(arguments) != 3 or arguments[0] not in ("prepare", "install", "owned-prepare", "owned-install", "cleanup"):
        return 64
    stage = private_directory(Path(arguments[1]))
    private_directory(stage.parent)
    nonce = arguments[2]
    processes.service_name(nonce)
    if arguments[0].startswith("owned-"):
        return owned_main(stage, arguments[0][6:], nonce)
    if arguments[0] == "cleanup":
        return cleanup_main(stage, nonce)
    return controller_main(stage, arguments[0], nonce)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
