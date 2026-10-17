#!/usr/bin/env python3
"""Source bootstrap for a recipient's Mac. No app data or private key export."""
import argparse
import base64
import ctypes
import errno
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
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
import uuid

APP = 'OpenBots Next.app'
BUNDLE = 'com.lorenzocolombani.openbotsnext.preview'
REPOSITORY = 'LorenzoColombani/openbots'
FEED = 'https://raw.githubusercontent.com/' + REPOSITORY + '/main/docs/updates/source-update.json'
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_SOURCE = 512 * 1024 * 1024
MAX_FILE = 64 * 1024 * 1024
MAX_FILES = 20000
MAX_FEED = 8 * 1024 * 1024
MAX_LOG = 256 * 1024
XCODE = Path('/Applications/Xcode.app')
MINIMUM_XCODE = (16, 3)
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
RENAME_EXCL = 0x4
ENTRYPOINTS = ('Scripts/build-source-update.sh', 'Scripts/source-update-sign.py', 'Scripts/swiftpm-public.sh')


class BootstrapError(Exception):
    pass


def support_root():
    return Path.home() / 'Library/Application Support' / BUNDLE


def rollback_root():
    # One previous bundle, outside /Applications, in a folder Spotlight does
    # not index. Promoting a new copy replaces the previous one.
    return support_root() / 'HighChurn.noindex/SourceUpdates/Rollback'


def build_log_path():
    # Outside the app's own folders, so a first install creates none of them.
    return Path.home() / 'Library/Logs/OpenBots Next/bootstrap-build.log'


def require(value, message):
    if not value:
        raise BootstrapError(message)


def regular(path, limit=MAX_FILE):
    path = Path(path)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= limit,
            'A required file is not a bounded regular file.')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        opened = os.fstat(stream.fileno())
        require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), 'A source file changed.')
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'A required file exceeds its limit.')
    return data


def write_new(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as stream:
        stream.write(data)


def run(arguments, *, data=None, home=False, timeout=60):
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()) if home else '/nonexistent',
                   'LANG': 'C', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
                   'GIT_TERMINAL_PROMPT': '0', 'GIT_ASKPASS': '/usr/bin/false', 'SSH_ASKPASS': '/usr/bin/false',
                   'OPENSSL_CONF': '/dev/null'}
    result = subprocess.run(arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=environment, timeout=timeout)
    require(result.returncode == 0 and len(result.stdout) + len(result.stderr) <= 2 * 1024 * 1024,
            'A required local tool refused the operation. Check Xcode and your local signing setup.')
    return result.stdout + (result.stderr if arguments[0] == '/usr/bin/codesign' else b'')


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_modules(source):
    signing = load_module('bootstrap_signing', source / 'Scripts/source-update-sign.py')
    worker = load_module('bootstrap_update', source / 'Sources/OpenBotsServices/Resources/source-app-update.py')
    return signing, worker


def valid_client(value):
    require(type(value) is str and (value == '' or (len(value.encode()) <= 512 and
            re.fullmatch(r'[A-Za-z0-9.-]+\.apps\.googleusercontent\.com', value))),
            'The Google client ID is malformed. Use the public Desktop client ID, never a secret.')
    return value


def selected_client(old, explicit, replace=False):
    if explicit is not None:
        require(explicit != '', 'An explicit Google client ID cannot be empty.')
        valid_client(explicit)
    require(not replace or explicit is not None,
            'Replacing the Google client ID needs the new ID in OPENBOTS_GOOGLE_OAUTH_CLIENT_ID.')
    if old is None:
        return explicit or ''
    embedded = valid_client(old.get('OpenBotsGoogleOAuthClientID', ''))
    marker = old.get('OpenBotsGoogleConfigurationVersion')
    require(marker is None or (type(marker) is int and marker == 1), 'The installed Google configuration marker is invalid.')
    # An empty embedded ID with marker 1 may use durable app-owned configuration.
    # Do not open its database or turn absence in the plist into a new setting.
    if explicit is None or explicit == embedded:
        return embedded
    if embedded == '':
        # Adding a client ID to an installation built without one.
        return explicit
    require(replace, 'This installation already has a different Google client ID. To switch to the new one, also set '
                     'OPENBOTS_REPLACE_GOOGLE_CLIENT_ID=1 (or pass --replace-google-client-id); the app then asks '
                     'you to sign in to Google again.')
    return explicit


def source_contract(source, commit):
    require(re.fullmatch(r'[a-f0-9]{40}', commit or ''), 'A full immutable public source commit is required.')
    build_config = regular(source / 'Config/ReleaseBuild.xcconfig', 16384).decode('utf-8')
    project = regular(source / 'project.yml', 1024 * 1024).decode('utf-8')
    builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION\s*=\s*([1-9][0-9]{0,17})\s*$', build_config, re.M)
    versions = re.findall(r'^\s*MARKETING_VERSION:\s*((?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){1,3})\s*$', project, re.M)
    require(len(builds) == len(versions) == 1, 'The source does not declare one valid ordered release build and version.')
    return {'commit': commit, 'build': builds[0], 'version': versions[0]}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise BootstrapError('Unexpected redirect from the public release server.')


def opener():
    # No proxy environment, cookies, netrc, credential store or redirect.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def fetch_feed(url=FEED):
    request = urllib.request.Request(url, headers={'User-Agent': 'OpenBots-Source-Bootstrap', 'Accept-Encoding': 'identity'})
    try:
        with opener().open(request, timeout=30) as response:
            require(response.status == 200 and response.geturl() == url, 'The release feed origin did not match.')
            data = response.read(MAX_FEED + 1)
    except urllib.error.HTTPError as error:
        require(error.code != 404, 'No published release yet. To build a local clone instead, run '
                                   'Scripts/bootstrap-install.py --source <clone>.')
        raise BootstrapError('The release feed could not be downloaded (HTTP ' + str(error.code) + ').') from None
    except urllib.error.URLError:
        raise BootstrapError('The release feed could not be downloaded. Check your network connection.') from None
    require(0 < len(data) <= MAX_FEED, 'The release feed is empty or exceeds its limit.')
    return data


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'The release feed is malformed.')
            result[key] = value
        return result
    def constant(_name):
        raise BootstrapError('The release feed is malformed.')
    try:
        return json.loads(data.decode('utf-8'), object_pairs_hook=unique, parse_constant=constant)
    except (UnicodeError, ValueError):
        raise BootstrapError('The release feed is malformed.') from None


def safe_parts(path):
    parts = path.split('/') if type(path) is str else []
    require(parts and len(path.encode()) <= 1024 and len(parts) <= 64 and
            all(p not in ('', '.', '..') and len(p.encode()) <= 255 for p in parts) and
            not any(unicodedata.category(c) in ('Cc', 'Cf') or c in '\\:' for c in path),
            'The release inventory has an unsafe path.')
    return parts


def release_inventory(entries):
    # Same rules as the app's manifest check: exact keys, two file modes,
    # no Git/build state, no macOS case or normalization aliases.
    require(type(entries) is list and 1 <= len(entries) <= MAX_FILES, 'The release inventory is malformed.')
    result, spellings = {}, {}
    for entry in entries:
        require(type(entry) is dict and set(entry) == {'path', 'sha256', 'mode'}, 'The release inventory is malformed.')
        path, digest, mode = entry['path'], entry['sha256'], entry['mode']
        parts = safe_parts(path)
        require(path not in result and type(digest) is str and re.fullmatch(r'[a-f0-9]{64}', digest) and
                mode in ('100644', '100755') and
                not any(p in ('.git', '.build') or p.endswith('.noindex') for p in parts),
                'The release inventory is malformed.')
        for count in range(1, len(parts) + 1):
            spelling = '/'.join(parts[:count])
            key = unicodedata.normalize('NFC', spelling).lower()
            require(spellings.setdefault(key, spelling) == spelling, 'The release inventory has ambiguous filenames.')
        result[path] = {'sha256': digest, 'mode': mode}
    for path in result:
        parts = path.split('/')
        require(not any('/'.join(parts[:i]) in result for i in range(1, len(parts))), 'The release inventory paths conflict.')
    require(all(name in result for name in ENTRYPOINTS), 'The release inventory is missing its build entrypoint.')
    return result


def parse_release(data):
    # The Ed25519 signature is checked by the app on every later update; the
    # system Python has no Ed25519 verifier, so here the feed is trusted over
    # HTTPS. The archive is still checked file by file against this inventory.
    envelope = strict_json(data)
    require(type(envelope) is dict and set(envelope) == {'payload', 'signature'} and
            type(envelope['payload']) is str and type(envelope['signature']) is str, 'The release feed is malformed.')
    try:
        payload = base64.b64decode(envelope['payload'], validate=True)
        signature = base64.b64decode(envelope['signature'], validate=True)
    except ValueError:
        raise BootstrapError('The release feed is malformed.') from None
    require(base64.b64encode(payload).decode() == envelope['payload'] and len(payload) <= 5 * 1024 * 1024 and
            len(signature) == 64, 'The release feed is malformed.')
    value = strict_json(payload)
    require(type(value) is dict and set(value) == {'schema', 'version', 'build', 'sourceCommit', 'files'} and
            type(value['schema']) is int and value['schema'] == 1 and
            type(value['version']) is str and
            re.fullmatch(r'(?:0|[1-9][0-9]{0,5})(?:\.(?:0|[1-9][0-9]{0,5})){1,3}', value['version']) and
            type(value['build']) is str and re.fullmatch(r'[1-9][0-9]{0,17}', value['build']) and
            type(value['sourceCommit']) is str and re.fullmatch(r'[a-f0-9]{40}', value['sourceCommit']),
            'The release feed is malformed.')
    return {'commit': value['sourceCommit'], 'build': value['build'], 'version': value['version'],
            'files': release_inventory(value['files'])}


def download(commit, target):
    url = 'https://codeload.github.com/' + REPOSITORY + '/tar.gz/' + commit
    request = urllib.request.Request(url, headers={'User-Agent': 'OpenBots-Source-Bootstrap', 'Accept-Encoding': 'identity'})
    try:
        response = opener().open(request, timeout=60)
    except urllib.error.URLError:
        raise BootstrapError('The release source could not be downloaded. Check your network connection.') from None
    with response:
        require(response.status == 200 and response.geturl() == url, 'Source download origin did not match the public commit.')
        total = 0
        with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as output:
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= MAX_ARCHIVE, 'Source download exceeds its limit.')
                output.write(chunk)


def expand(archive, expanded):
    # Bound decompression before tarfile interprets headers or seeks over padding.
    written = 0
    with gzip.open(archive, 'rb') as incoming, open(expanded, 'xb') as outgoing:
        while True:
            block = incoming.read(65536)
            if not block:
                break
            written += len(block)
            require(written <= 600 * 1024 * 1024, 'Expanded archive exceeds its limit.')
            outgoing.write(block)


def extract_source(archive, destination, release=None):
    require(len(regular(archive, MAX_ARCHIVE)) <= MAX_ARCHIVE, 'Source archive exceeds its limit.')
    with open(archive, 'rb') as stream:
        compressed = stream.read(2) == b'\x1f\x8b'
    # A name of its own: never the download's name, never the destination's.
    expanded = destination.with_name(destination.name + '.expanded.tar')
    try:
        if compressed:
            expand(archive, expanded)
            archive = expanded
        unpack(archive, destination, release)
    finally:
        if compressed:
            expanded.unlink(missing_ok=True)
    required = ENTRYPOINTS + ('Sources/OpenBotsServices/Resources/source-app-update.py',
                              'Sources/OpenBotsServices/Resources/source-app-update-processes.py')
    require(all((destination / path).is_file() for path in required), 'This source cannot bootstrap source updates.')
    if release is not None:
        verify_tree(destination, release['files'])


def unpack(archive, destination, release):
    destination.mkdir(mode=0o700)
    expected = release['files'] if release is not None else None
    directories = None
    if expected is not None:
        directories = {'/'.join(path.split('/')[:i]) for path in expected for i in range(1, path.count('/') + 1)}
    total, entries, root_name, names, spellings, count = 0, [], None, set(), {}, 0
    # Never use extractall: links, traversal, special modes and duplicate/case
    # aliases are rejected before any member can become source on disk.
    with tarfile.open(archive, 'r:*') as source:
        for member in source:
            count += 1
            require(count <= MAX_FILES + 4096 and (member.isdir() or member.isfile()) and
                    not member.mode & 0o7000 and (not member.isdir() or member.size == 0),
                    'Source archive contains an unsupported entry.')
            parts = member.name.rstrip('/').split('/')
            require(parts and all(p not in ('', '.', '..') and len(p.encode()) <= 255 for p in parts) and
                    len(parts) <= 64 and len(member.name.encode()) <= 1024 and
                    not any(unicodedata.category(c) in ('Cc', 'Cf') or c in '\\:' for c in member.name),
                    'Source archive has an unsafe path.')
            root_name = root_name or parts[0]
            require(parts[0] == root_name, 'Source archive must have one root directory.')
            if len(parts) == 1:
                require(member.isdir(), 'Invalid source archive root.')
                continue
            relative = '/'.join(parts[1:])
            require(not any(p.lower() in ('.git', '.build', '.swiftpm', '.env', '.ds_store', '__macosx', '__pycache__') or
                            p.lower().endswith(('.noindex', '.keychain', '.keychain-db', '.p12', '.p8', '.pem', '.key'))
                            for p in parts[1:]), 'Source archive contains local metadata or signing material.')
            require(relative not in names, 'Source archive repeats a path.')
            names.add(relative)
            for length in range(1, len(parts)):
                spelling = '/'.join(parts[1:length + 1])
                key = unicodedata.normalize('NFC', spelling).casefold()
                require(key not in spellings or spellings[key] == spelling, 'Source archive paths collide on macOS.')
                spellings[key] = spelling
            require(0 <= member.size <= MAX_FILE, 'Source archive contains an oversized file.')
            if expected is not None:
                if member.isdir():
                    require(relative in directories, 'Source archive contains a directory the release does not list.')
                else:
                    require(relative in expected, 'Source archive contains a file the release does not list.')
                    executable = bool(member.mode & 0o111)
                    require(executable == (expected[relative]['mode'] == '100755'),
                            'Source archive file modes do not match the release inventory.')
            total += member.size
            require(total <= MAX_SOURCE, 'Expanded source exceeds its limit.')
            entries.append((member, relative))
        if expected is not None:
            # git archive records the commit in one global header; codeload
            # names the root after the repository and commit.
            require(root_name == REPOSITORY.split('/')[1] + '-' + release['commit'] and
                    source.pax_headers.get('comment') == release['commit'],
                    'Source archive does not come from the released commit.')
        files = {path for member, path in entries if member.isfile()}
        for path in names:
            parts = path.split('/')
            require(not any('/'.join(parts[:i]) in files for i in range(1, len(parts))), 'Source paths conflict.')
        if expected is not None:
            require(files == set(expected), 'Source archive does not contain exactly the released files.')
        for member, relative in entries:
            target = destination / relative
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.extractfile(member) as incoming:
                data = incoming.read(MAX_FILE + 1)
            require(len(data) == member.size, 'Source archive file is incomplete.')
            if expected is not None:
                require(hashlib.sha256(data).hexdigest() == expected[relative]['sha256'],
                        'A source file does not match the release inventory SHA-256.')
            write_new(target, data)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)


def verify_tree(source, expected):
    # Re-read what is on disk before any of it runs: exact file set, one link
    # each, SHA-256 and executable bit as the release inventory lists them.
    actual = set()
    for directory, folders, files in os.walk(source, followlinks=False):
        for name in folders:
            require(stat.S_ISDIR((Path(directory) / name).lstat().st_mode), 'Extracted source contains a link.')
        for name in files:
            path = Path(directory) / name
            relative = path.relative_to(source).as_posix()
            require(relative in expected, 'Extracted source contains a file the release does not list.')
            item = expected[relative]
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == (0o755 if item['mode'] == '100755' else 0o644),
                    'Extracted source file modes do not match the release inventory.')
            require(hashlib.sha256(regular(path)).hexdigest() == item['sha256'],
                    'Extracted source does not match the release inventory SHA-256.')
            actual.add(relative)
    require(actual == set(expected), 'Extracted source is missing released files.')


def archive_clone(source, target):
    source = Path(source).resolve(strict=True)
    base = ['/usr/bin/git', '-C', str(source), '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
            '-c', 'credential.helper=', '-c', 'protocol.allow=never']
    commit = run(base + ['rev-parse', '--verify', 'HEAD^{commit}']).decode().strip()
    require(re.fullmatch(r'[a-f0-9]{40}', commit), 'The clone has no immutable source commit.')
    require(not run(base + ['status', '--porcelain', '--untracked-files=no']), 'Commit or discard tracked clone changes before bootstrap.')
    # Git archive reads only this committed tree. Ignored local Google setup,
    # caches, .git and parent history never enter the disposable build source.
    with open(target, 'xb') as stream:
        result = subprocess.run(base + ['archive', '--format=tar', '--prefix=source/', commit], stdout=stream,
                                stderr=subprocess.PIPE, timeout=60, env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent',
                                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_NO_REPLACE_OBJECTS': '1'})
    require(result.returncode == 0 and target.stat().st_size <= MAX_ARCHIVE, 'The local source archive could not be prepared.')
    return commit


def read_info(app):
    require(app.is_dir() and not app.is_symlink() and app.resolve() == app, 'The application path must be a real bundle.')
    info = plistlib.loads(regular(app / 'Contents/Info.plist', 1024 * 1024))
    require(type(info) is dict and info.get('CFBundleIdentifier') == BUNDLE and
            info.get('CFBundleExecutable') == 'OpenBots Next' and info.get('CFBundlePackageType') == 'APPL',
            'Only the OpenBots Next application can be replaced.')
    valid_client(info.get('OpenBotsGoogleOAuthClientID', ''))
    return info


def refuse_downgrade(old, build):
    if old is None:
        return
    installed = old.get('CFBundleVersion')
    # Early previews used dotted build numbers; compare them part by part.
    require(type(installed) is str and re.fullmatch(r'[0-9]{1,18}(?:\.[0-9]{1,18}){0,3}', installed),
            'The installed app has no readable build number. Nothing was replaced.')
    require(tuple(int(part) for part in installed.split('.')) <= (int(build),),
            'The installed app (build ' + installed + ') is newer than this release (build ' + build + '). '
            'Downgrades are refused. Nothing was replaced.')


def xcode_preflight():
    info = XCODE / 'Contents/Info.plist'
    require(info.is_file(), 'Install full Xcode 16.3 or later in /Applications and open it once first.')
    try:
        version = plistlib.loads(regular(info, 1024 * 1024)).get('CFBundleShortVersionString')
    except (ValueError, plistlib.InvalidFileException):
        version = None
    match = re.fullmatch(r'([0-9]+)\.([0-9]+)(?:\.[0-9]+)?', version) if type(version) is str else None
    require(match and tuple(map(int, match.groups())) >= MINIMUM_XCODE,
            'OpenBots Next needs Xcode 16.3 or later (found ' + (version if type(version) is str else 'an unreadable version') +
            '). Update Xcode and open it once.')
    try:
        result = subprocess.run([str(XCODE / 'Contents/Developer/usr/bin/xcodebuild'), '-version'],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120,
                                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()), 'LANG': 'C',
                                     'DEVELOPER_DIR': str(XCODE / 'Contents/Developer')})
    except (OSError, subprocess.TimeoutExpired):
        raise BootstrapError('Xcode could not run. Open Xcode once so it can finish installing its components.') from None
    if result.returncode != 0:
        require(b'license' not in result.stdout.lower(),
                'Accept the Xcode license first: open Xcode once, or run "sudo xcodebuild -license accept".')
        raise BootstrapError('Xcode could not run. Open Xcode once so it can finish installing its components.')


def signature(app, *, allow_adhoc=False, runtime=False):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], home=True)
    metadata = run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)], home=True)
    match = re.search(rb'^TeamIdentifier=([A-Z0-9]{10})$', metadata, re.M)
    if match:
        require(b'Authority=Apple Development:' in metadata, 'The installed app must use your own Apple Development identity.')
        require(not runtime or b'(runtime)' in metadata, 'The candidate must preserve hardened runtime.')
        return match.group(1).decode()
    require(allow_adhoc and b'Signature=adhoc' in metadata, 'A valid local Apple Development signature is required.')
    return None


def permissions(app):
    data = run(['/usr/bin/codesign', '--display', '--entitlements', ':-', str(app)], home=True)
    start = data.find(b'<?xml')
    if start < 0:
        start = data.find(b'<plist')
    result = plistlib.loads(data[start:]) if start >= 0 else {}
    require(type(result) is dict, 'Application signing permissions could not be read.')
    return result


def available_teams(signing, keychain):
    # Read only public certificates and usable identity metadata. No private key
    # export, password, keychain search-list change or owner-specific default.
    try:
        certificates = signing.run(['/usr/bin/security', 'find-certificate', '-a', '-c', 'Apple Development', '-p', str(keychain)])
    except signing.BuildFailure:
        # security exits non-zero when no certificate matches.
        return set()
    blocks = re.findall(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S)
    require(len(blocks) <= 64, 'The local certificate inventory needs review in Xcode.')
    teams = set()
    for certificate in blocks:
        subject = signing.run(['/usr/bin/openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], data=certificate)
        matches = re.findall(rb'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', subject.strip().removeprefix(b'subject='))
        for match in matches:
            team = match.decode()
            try:
                signing.choose_identity(team, str(keychain))
            except signing.BuildFailure:
                continue
            teams.add(team)
    return teams


def select_team(signing, old_team, explicit):
    if explicit is not None:
        require(re.fullmatch(r'[A-Z0-9]{10}', explicit or ''), 'OPENBOTS_DEVELOPMENT_TEAM must be your ten-character team ID.')
    require(not old_team or explicit is None or explicit == old_team,
            'Bootstrap must preserve this installation\'s signing team.')
    keychain = Path.home() / 'Library/Keychains/login.keychain-db'
    selected = old_team or explicit
    try:
        if selected is None:
            teams = available_teams(signing, keychain)
            require(teams, 'Set up an Apple Development certificate in Xcode: Settings, Accounts, Manage Certificates.')
            require(len(teams) == 1, 'Several Apple Development teams are available. Set OPENBOTS_DEVELOPMENT_TEAM '
                                     'to your own ten-character team ID.')
            selected = next(iter(teams))
        signing.choose_identity(selected, str(keychain))
    except signing.BuildFailure as error:
        raise BootstrapError(str(error)) from None
    return selected


def stopped(app, processes):
    api = processes.Metadata()
    api.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    api.lib.proc_pidpath.restype = ctypes.c_int
    target = str(app / 'Contents/MacOS/OpenBots Next')
    for pid in api.pids():
        buffer = ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        count = api.lib.proc_pidpath(pid, buffer, len(buffer))
        error = ctypes.get_errno()
        if count <= 0:
            require(error == errno.ESRCH, 'macOS could not confirm the application is stopped.')
            continue
        require(os.fsdecode(buffer.value) != target, 'Quit OpenBots Next normally before installing. Nothing was replaced.')


def verify_candidate(app, contract, signing, worker, *, require_channel=True):
    info = read_info(app)
    require(info.get('CFBundleVersion') == contract['build'] and info.get('CFBundleShortVersionString') == contract['version'] and
            info.get('OpenBotsSourceCommit') == contract['commit'] and
            valid_client(info.get('OpenBotsGoogleOAuthClientID', '')) == contract['google'] and
            type(info.get('OpenBotsGoogleConfigurationVersion')) is int and info['OpenBotsGoogleConfigurationVersion'] == 1,
            'The candidate does not match this source or preserve Google setup.')
    require(signature(app, runtime=True) == contract['team'], 'The candidate uses a different signing team.')
    binaries, _ = signing.native_inventory(app)
    for binary in binaries:
        require(signature(binary, runtime=True) == contract['team'], 'A nested executable uses a different signing team.')
    if require_channel:
        key = info.get('OpenBotsSourceUpdatePublicKey')
        require(info.get('OpenBotsSourceUpdateEnabled') is True and info.get('OpenBotsSourceUpdateFeedURL') == FEED and
                info.get('OpenBotsSourceUpdateRepository') == REPOSITORY and type(key) is str,
                'This candidate is not configured for the production source update channel.')
        decoded = base64.b64decode(key, validate=True)
        require(len(decoded) == 32 and base64.b64encode(decoded).decode() == key, 'The source update public key is malformed.')
    return worker.bundle_fingerprint(app)


def build_command(source, contract):
    return ['/bin/zsh', '-f', str(source / 'Scripts/build-source-update.sh'), '--commit', contract['commit'],
            '--build', contract['build'], '--version', contract['version'], '--team', contract['team'],
            '--google-client-id', contract['google']]


def owned_build(stage, nonce):
    config = json.loads(regular(stage / 'bootstrap.json', 16384))
    require(config.get('nonce') == nonce, 'Invalid bootstrap build handoff.')
    source = Path(config['source'])
    signing, module = source_modules(source)
    launch = module.private_json(stage / 'launch.json', maximum=16384)
    require(launch.get('nonce') == nonce, 'Invalid bootstrap launch handoff.')
    worker, code, clean, log = None, 1, False, b''
    try:
        worker = module.Worker(stage, {'parentPID': launch['controllerIdentity']['pid']}, launch)
        def cancel(_signal, _frame):
            worker.cancelled = True
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        worker.admit()
        status, log = worker.run(build_command(source, config['contract']), timeout=35 * 60, cwd=source,
            environment={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': os.environ['HOME'], 'LANG': 'C'})
        require(status == 0, 'The build script exited with status ' + str(status) + '.')
        code = 0
    except BaseException as error:
        code = 1
        log = bytes(log) + ('\nbootstrap: ' + (str(error)[:1024] or type(error).__name__) + '\n').encode()
    finally:
        try:
            write_new(stage / 'build.log', bytes(log)[-MAX_LOG:])
        except OSError:
            pass
        if worker is not None:
            try:
                worker.stop_children()
                worker.owner.assert_alone()
                clean = True
            except BaseException:
                code = 1
        module.write_json(stage / 'worker-stopped.json', {'nonce': nonce, 'exitCode': code, 'childrenStopped': clean,
            'coalition': worker.owner.coalition if worker else None, 'population': 1 if clean else None})
        if worker is not None and clean and not worker.api.alive(worker.controller_identity):
            # A dead Terminal/controller cannot remove its job. Clean children
            # first, then remove only this nonce-derived transient service.
            module.processes.launchctl(['bootout', module.processes.service_name(nonce)])
    return code


def publish_build_log(stage, path):
    # Keep the tail of the build output after staging is removed: one private
    # file, replaced on every run, bounded in size.
    data = b''
    for name in ('build.log', 'job-stderr.log', 'job-stdout.log'):
        part = stage / name
        if part.is_file() and not part.is_symlink() and part.stat().st_size:
            with open(part, 'rb') as stream:
                stream.seek(max(0, part.stat().st_size - MAX_LOG))
                data += ('==> ' + name + '\n').encode() + stream.read(MAX_LOG) + b'\n'
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not path.parent.is_symlink() and path.parent.stat().st_uid == os.getuid(), 'The build log folder is not private.')
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    write_new(temporary, data[-MAX_LOG:])
    os.replace(temporary, path)
    return path


def log_excerpt(path, lines=12):
    try:
        text = regular(path, MAX_LOG).decode('utf-8', 'replace')
    except (OSError, BootstrapError):
        return ''
    kept = [line[:300] for line in text.splitlines() if line.strip() and not line.startswith('==> ')]
    return '\n'.join(kept[-lines:])


def supervise(source, stage, contract, module):
    processes, api = module.processes, module.processes.Metadata()
    nonce = uuid.uuid4().hex
    service = processes.service_name(nonce)
    domain, label = service.rsplit('/', 1)
    controller = api.identity(os.getpid())
    require(controller is not None, 'The bootstrap controller identity is unavailable.')
    require(processes.service_absent(service), 'The temporary bootstrap job name is already in use.')
    module.write_json(stage / 'bootstrap.json', {'nonce': nonce, 'source': str(source), 'contract': contract})
    module.write_json(stage / 'launch.json', {'nonce': nonce, 'hostIdentity': controller, 'controllerIdentity': controller})
    for name in ('job-stdout.log', 'job-stderr.log'):
        write_new(stage / name, b'')
    definition = {'Label': label, 'RunAtLoad': True, 'KeepAlive': False, 'LaunchOnlyOnce': True,
        'ProcessType': 'Background', 'AbandonProcessGroup': False, 'ExitTimeOut': 3,
        'ProgramArguments': ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', 'LANG=C',
            'HOME=' + str(Path.home()), 'TMPDIR=' + str(stage), '/usr/bin/python3', '-I', '-B', '-S',
            str(Path(__file__).resolve()), '__owned-build', str(stage), nonce],
        'WorkingDirectory': str(stage), 'StandardInPath': '/dev/null',
        'StandardOutPath': str(stage / 'job-stdout.log'), 'StandardErrorPath': str(stage / 'job-stderr.log')}
    plist = stage / 'build-job.plist'
    write_new(plist, plistlib.dumps(definition))
    coalition, admitted, result, cleaned, identity = None, False, False, False, None
    previous = {}
    def cancel(_signal, _frame):
        module.cancellation_file(stage)
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, cancel)
    try:
        require(processes.launchctl(['bootstrap', domain, str(plist)]).returncode == 0, 'The private bootstrap build could not start.')
        start, end, cancellation_deadline = time.monotonic() + 12, time.monotonic() + 40 * 60, None
        while time.monotonic() < end:
            if (stage / 'cancel').exists() and cancellation_deadline is None:
                cancellation_deadline = time.monotonic() + 18
            require(cancellation_deadline is None or time.monotonic() < cancellation_deadline, 'Bootstrap cancellation did not finish in time.')
            if not admitted and (stage / 'started.json').exists():
                value = module.private_json(stage / 'started.json', maximum=16384)
                identity = value.get('identity')
                candidate = value.get('coalition')
                require(value.get('nonce') == nonce and value.get('population') == 1 and type(identity) is dict and
                    identity.get('coalition') == candidate and candidate != controller['coalition'] and
                    processes.same_identity(identity, api.identity(identity['pid'])) and
                    set(api.members(candidate)) == {identity['pid']} and api.active(candidate) == 1,
                    'The bootstrap build could not prove isolated process ownership.')
                coalition = candidate
                require(not (stage / 'cancel').exists(), 'Bootstrap was cancelled.')
                module.write_json(stage / 'admitted.json', {'nonce': nonce, 'coalition': coalition})
                admitted = True
            if (stage / 'worker-stopped.json').exists():
                outcome = module.private_json(stage / 'worker-stopped.json', maximum=16384)
                require(admitted and outcome.get('nonce') == nonce and outcome.get('coalition') == coalition and
                        outcome.get('childrenStopped') is True and outcome.get('population') == 1,
                        'The bootstrap worker did not confirm complete cleanup.')
                result = outcome.get('exitCode') == 0 and not (stage / 'cancel').exists()
                break
            require(admitted or time.monotonic() < start, 'The bootstrap worker did not become ready.')
            require(not admitted or api.alive(identity), 'The bootstrap worker stopped unexpectedly.')
            time.sleep(0.1)
    finally:
        try:
            if coalition is not None:
                processes.stop_entire_coalition(api, coalition)
            processes.remove_job(service, coalition, api)
            cleaned = True
        finally:
            module.write_json(stage / 'cleanup.json', {'stopped': cleaned})
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    require(result and cleaned, 'The source build failed. The installed app is unchanged.')


def supervised_build(source, stage, contract, module, log_path):
    failure = None
    try:
        supervise(source, stage, contract, module)
    except BootstrapError as error:
        failure = str(error)
    finally:
        try:
            where = publish_build_log(stage, log_path)
        except (OSError, BootstrapError):
            where = stage / 'build.log'
    if failure is not None:
        excerpt = log_excerpt(where)
        raise BootstrapError(failure + '\nBuild log: ' + str(where) + ('\nLast lines:\n' + excerpt if excerpt else ''))


def exchange(source, target, flags):
    # RENAME_EXCL never replaces an existing (even empty) destination, unlike
    # os.rename. Used only inside the rollback folder.
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    function = libc.renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(os.fsencode(str(source)), os.fsencode(str(target)), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))


def launch_services(flag, app):
    # Registration hygiene only: -u forgets a copy that must never be launched,
    # -f registers the installed app. A failure never changes any file.
    try:
        subprocess.run([LSREGISTER, flag, str(app)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C'})
    except (OSError, subprocess.TimeoutExpired):
        pass


def ditto(source, target):
    # The same copy tool the app's own installer uses; never into an existing
    # folder, because ditto merges into one.
    require(not target.exists() and not target.is_symlink(), 'A copy target already exists: ' + str(target))
    run(['/usr/bin/ditto', str(source), str(target)], timeout=600)


def remove_owned(path):
    # Never through a link, never anything another account owns.
    info = path.lstat()
    require(not stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid(), 'A path to remove is a link or not yours: ' + str(path))
    require(shutil.rmtree.avoids_symlink_attacks, 'Safe removal is unavailable.')
    if stat.S_ISDIR(info.st_mode):
        shutil.rmtree(path)
    else:
        path.unlink()


def private_folder(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077 and path.resolve() == path,
            'The rollback folder is not a private folder.')
    return path


def install_candidate(candidate, destination, contract, signing, worker, old_fingerprint, rollback, scratch):
    """Replace the app in place and keep exactly one rollback copy.

    The installed bundle is never renamed or moved: Launch Services and the Dock
    follow a moved bundle by file reference and would later open the stale copy.
    The previous app is copied first (to the rollback folder, or to private
    scratch when there is none) and verified, then removed, and the verified
    candidate, which stays in private staging, is copied to the same path. On any
    failure after the removal the previous app is copied back and verified.
    """
    processes = worker.processes
    stopped(destination, processes)
    expected = verify_candidate(candidate, contract, signing, worker)
    if old_fingerprint is not None:
        require(worker.permissions_compatible(permissions(destination), permissions(candidate)),
                'The bootstrap candidate changes application signing permissions.')
    launch_services('-u', candidate)
    token = uuid.uuid4().hex
    keep_folder = keep = None
    removing = placed = False
    try:
        if old_fingerprint is not None:
            require(worker.bundle_fingerprint(destination) == old_fingerprint, 'The installed app changed while building.')
            signature(destination, allow_adhoc=True)
            keep_folder = (private_folder(rollback) / ('.incoming-' + token)) if rollback is not None else scratch / ('previous-' + token)
            keep_folder.mkdir(mode=0o700)
            keep = keep_folder / APP
            ditto(destination, keep)
            require(worker.bundle_fingerprint(keep) == old_fingerprint, 'The rollback copy differs from the installed app.')
            launch_services('-u', keep)
            stopped(destination, processes)
            require(worker.bundle_fingerprint(destination) == old_fingerprint, 'The installed app changed while installing.')
            removing = True
            remove_owned(destination)
        else:
            require(not destination.exists() and not destination.is_symlink(), 'An application appeared at the destination.')
        placed = True
        ditto(candidate, destination)
        require(verify_candidate(destination, contract, signing, worker) == expected, 'The installed copy failed verification.')
    except BaseException:
        restore_previous(destination, keep, old_fingerprint, removing, placed, worker, processes)
        if keep_folder is not None and (keep_folder.exists() or keep_folder.is_symlink()):
            try:
                remove_owned(keep_folder)
            except (OSError, BootstrapError):
                print('Temporary copy retained for inspection: ' + str(keep_folder), file=sys.stderr)
        raise
    notes = []
    result = None
    if keep is not None and rollback is not None:
        result = rollback / APP
        try:
            for stale in list(rollback.iterdir()):
                if stale.name == APP or (stale.name.startswith('.incoming-') and stale != keep_folder):
                    launch_services('-u', stale / APP if stale.name != APP else stale)
                    remove_owned(stale)
            # Renames inside the rollback folder only; never the installed app.
            exchange(keep, result, RENAME_EXCL)
            keep_folder.rmdir()
            launch_services('-u', result)
        except (OSError, BootstrapError):
            result = keep
            notes.append('The previous app was kept at ' + str(result))
    elif keep_folder is not None:
        try:
            remove_owned(keep_folder)
        except (OSError, BootstrapError):
            pass
    launch_services('-f', destination)
    for note in notes:
        print(note, file=sys.stderr)
    return result


def restore_previous(destination, keep, old_fingerprint, removing, placed, worker, processes):
    # Put the previous app back at its path by copy, or leave the destination
    # as it was found. A copy that has started running is never removed.
    try:
        if (placed or removing) and (destination.exists() or destination.is_symlink()):
            stopped(destination, processes)
            remove_owned(destination)
        if removing:
            ditto(keep, destination)
            require(worker.bundle_fingerprint(destination) == old_fingerprint, 'The restored app differs from the previous app.')
            launch_services('-f', destination)
    except (OSError, BootstrapError):
        where = (' The previous app is kept at ' + str(keep) + '. To restore it, quit OpenBots Next, remove ' +
                 str(destination) + ' if present, and run: /usr/bin/ditto "' + str(keep) + '" "' + str(destination) + '"') if removing else ''
        # Keep the copy: the caller's cleanup must not remove it.
        raise BootstrapError('Recovery needs attention: the installation failed and could not be undone.' + where) from None


def clean_owned_work(work, identity):
    info = work.lstat()
    require(not work.is_symlink() and (info.st_dev, info.st_ino) == identity and info.st_uid == os.getuid(),
            'Temporary staging changed; it was retained for inspection.')
    # shutil's fd-based removal resists nested directory replacement with links.
    require(shutil.rmtree.avoids_symlink_attacks, 'Safe temporary cleanup is unavailable; staging was retained.')
    shutil.rmtree(work)


def host_preflight():
    require(sys.platform == 'darwin' and os.uname().machine == 'arm64' and os.getuid() != 0,
            'Run bootstrap as your own account on an Apple Silicon Mac, without sudo.')
    xcode_preflight()


def fetch_source(args, work):
    """Return (commit, release, source directory); release is None for a clone."""
    # The download and the expanded tar never share a name (see extract_source).
    archive = work / 'source.download'
    if args.source:
        commit = archive_clone(args.source, archive)
        require(args.commit is None or args.commit == commit, 'The clone is not at the requested commit.')
        release = None
    else:
        release = parse_release(fetch_feed())
        commit = release['commit']
        require(args.commit is None or args.commit == commit,
                'The published release changed while installing. Run the installer again.')
        if args.archive:
            write_new(archive, regular(Path(args.archive), MAX_ARCHIVE))
        else:
            download(commit, archive)
    source = work / 'source'
    extract_source(archive, source, release)
    archive.unlink()
    return commit, release, source


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '__owned-build':
        return owned_build(Path(sys.argv[2]), sys.argv[3])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', help='Clean public clone; only the committed tree is built')
    parser.add_argument('--commit', help='Refuse unless the published release names this commit')
    parser.add_argument('--archive', help='Local copy of the released source archive; still checked against the release feed')
    parser.add_argument('--applications-dir', default=os.environ.get('OPENBOTS_APPLICATIONS_DIR', '/Applications'))
    parser.add_argument('--team', default=os.environ.get('OPENBOTS_DEVELOPMENT_TEAM'))
    parser.add_argument('--google-client-id', default=os.environ.get('OPENBOTS_GOOGLE_OAUTH_CLIENT_ID'))
    parser.add_argument('--replace-google-client-id', action='store_true',
                        default=os.environ.get('OPENBOTS_REPLACE_GOOGLE_CLIENT_ID') == '1',
                        help='Allow a different Google client ID to replace the installed one')
    parser.add_argument('--no-open', action='store_true', default=os.environ.get('OPENBOTS_NO_OPEN') == '1')
    parser.add_argument('--prepare-only', action='store_true', help='Keep the verified candidate without installing or opening')
    parser.add_argument('--allow-disabled-source-updates', action='store_true', help='Only for --prepare-only local checks')
    args = parser.parse_args()
    os.umask(0o077)
    work, identity, safe_cleanup, keep_staging = None, None, True, False
    try:
        require(not args.allow_disabled_source_updates or args.prepare_only, 'Disabled channel checks are allowed only with --prepare-only.')
        require(not (args.source and args.archive), 'Choose a local clone or an archive, not both.')
        require(args.commit is None or re.fullmatch(r'[a-f0-9]{40}', args.commit), 'A full public source commit is required.')
        valid_client(args.google_client_id or '')
        host_preflight()
        work = Path(tempfile.mkdtemp(prefix='openbots-bootstrap-')).resolve()
        work.chmod(0o700)
        info = work.lstat(); identity = (info.st_dev, info.st_ino)
        commit, release, source = fetch_source(args, work)
        signing, worker = source_modules(source)
        contract = source_contract(source, commit)
        require(release is None or (contract['build'], contract['version']) == (release['build'], release['version']),
                'The released source does not declare the build and version its release names.')
        applications = Path(args.applications_dir).absolute()
        require(applications.is_dir() and applications.resolve() == applications and os.access(applications, os.W_OK),
                'The Applications folder must exist, be writable by you, and have no path links. Do not use sudo.')
        destination = applications / APP
        present = destination.exists() or destination.is_symlink()
        before = worker.bundle_fingerprint(destination) if present else None
        old = read_info(destination) if present else None
        old_team = signature(destination, allow_adhoc=True) if old is not None else None
        old_fingerprint = worker.bundle_fingerprint(destination) if old is not None else None
        require(before == old_fingerprint, 'The installed application changed during inspection.')
        stopped(destination, worker.processes)
        refuse_downgrade(old, contract['build'])
        contract['google'] = selected_client(old, args.google_client_id, args.replace_google_client_id)
        contract['team'] = select_team(signing, old_team, args.team)
        stage = work / 'build-control'; stage.mkdir(mode=0o700)
        safe_cleanup = False
        supervised_build(source, stage, contract, worker, build_log_path())
        safe_cleanup = True
        candidate = source / '.build.noindex/source-update/Build/Products/Release' / APP
        verify_candidate(candidate, contract, signing, worker, require_channel=not args.allow_disabled_source_updates)
        if args.prepare_only:
            safe_cleanup = False
            print('Candidate verified and retained without installation: ' + str(candidate))
            return 0
        # The app creates its own support folder on first launch and refuses
        # one that already exists, so a rollback copy is kept only once it has.
        rollback = rollback_root() if old is not None and support_root().is_dir() else None
        previous = install_candidate(candidate, destination, contract, signing, worker, old_fingerprint, rollback, work)
        print('Installed OpenBots Next from public source build ' + contract['build'] + '.')
        if previous:
            print('Previous application kept for rollback: ' + str(previous))
        if not args.no_open:
            run(['/usr/bin/open', '-a', str(destination)], home=True)
            print('Opening requested. On first launch, existing Google public configuration is saved by the app.')
        return 0
    except Exception as error:
        if work is not None and any(work.glob('previous-*')):
            # A failed recovery left the only copy of the previous app here.
            keep_staging = True
        if isinstance(error, BootstrapError):
            print(str(error), file=sys.stderr)
        else:
            print('Bootstrap failed safely (' + type(error).__name__ + ': ' + str(error)[:300] + '). '
                  'The installed app is unchanged.', file=sys.stderr)
        return 1
    finally:
        if work is not None:
            cleanup = work / 'build-control/cleanup.json'
            if not safe_cleanup and cleanup.is_file() and not args.prepare_only:
                try:
                    safe_cleanup = json.loads(regular(cleanup, 1024)).get('stopped') is True
                except (OSError, ValueError, BootstrapError):
                    pass
            if safe_cleanup and not keep_staging:
                try:
                    clean_owned_work(work, identity)
                except (BootstrapError, OSError):
                    print('Private staging could not be safely removed and was retained: ' + str(work), file=sys.stderr)
            else:
                print('Private build staging retained: ' + str(work), file=sys.stderr)


if __name__ == '__main__':
    raise SystemExit(main())
