"""Pure bootstrap fixtures: no real build, signing, keychain, install, or network."""
import base64
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('bootstrap', Path(__file__).with_name('bootstrap-install.py'))
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)
COMMIT = 'c' * 40
REQUIRED = ('Scripts/build-source-update.sh', 'Scripts/source-update-sign.py', 'Scripts/swiftpm-public.sh',
            'Sources/OpenBotsServices/Resources/source-app-update.py',
            'Sources/OpenBotsServices/Resources/source-app-update-processes.py')


class Failure(Exception):
    pass


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.contract = {'commit': 'a' * 40, 'build': '4001', 'version': '1.1.0', 'team': 'ABCDEFGHIJ', 'google': ''}
        # No fixture may reach Launch Services, the network or the real Xcode.
        self.registrations, self.copies, self.copy_failures = [], [], {}
        for name, value in (('launch_services', lambda flag, app: self.registrations.append((flag, Path(app)))),
                            ('ditto', self.fake_ditto),
                            ('opener', self.no_network), ('LSREGISTER', '/nonexistent/lsregister')):
            patcher = patch.object(bootstrap, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_ditto(self, source, target):
        # Stands in for /usr/bin/ditto. copy_failures maps a call number to
        # 'fail' (nothing copied) or 'partial' (half a bundle left behind).
        self.copies.append((Path(source), Path(target)))
        assert not target.exists(), 'ditto must never merge into an existing folder'
        failure = self.copy_failures.get(len(self.copies))
        if failure == 'fail':
            raise bootstrap.BootstrapError('synthetic copy failure')
        if failure == 'partial':
            (target / 'Contents').mkdir(parents=True)
            raise bootstrap.BootstrapError('synthetic partial copy')
        shutil.copytree(source, target, symlinks=True)

    @staticmethod
    def no_network():
        raise AssertionError('A fixture tried to use the network.')

    def app(self, parent, build='4001', google=''):
        app = parent / bootstrap.APP
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/OpenBots Next').write_bytes(b'synthetic executable: never run')
        info = {'CFBundleIdentifier': bootstrap.BUNDLE, 'CFBundleExecutable': 'OpenBots Next', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': build, 'CFBundleShortVersionString': '1.1.0', 'OpenBotsSourceCommit': 'a' * 40,
            'OpenBotsGoogleOAuthClientID': google, 'OpenBotsGoogleConfigurationVersion': 1,
            'OpenBotsSourceUpdateEnabled': True, 'OpenBotsSourceUpdateFeedURL': bootstrap.FEED,
            'OpenBotsSourceUpdateRepository': bootstrap.REPOSITORY,
            'OpenBotsSourceUpdatePublicKey': base64.b64encode(bytes(range(32))).decode()}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app

    def archive(self, additions=()):
        archive = self.root / 'source.tar'
        with tarfile.open(archive, 'w') as output:
            for name in REQUIRED:
                entry = tarfile.TarInfo('source/' + name); data = b'fixture'
                entry.size = len(data); entry.mode = 0o755
                output.addfile(entry, io.BytesIO(data))
            for name, kind in additions:
                entry = tarfile.TarInfo(name); entry.type = kind; entry.size = 0
                if kind == tarfile.SYMTYPE:
                    entry.linkname = '/outside'
                output.addfile(entry, io.BytesIO())
        return archive

    # A release as the feed publishes it and an archive shaped like codeload's.
    def release_files(self):
        files = {name: (b'fixture ' + name.encode(), '100755' if name.endswith(('.sh', '.py')) else '100644') for name in REQUIRED}
        files['Sources/Example.swift'] = (b'reviewed source', '100644')
        return files

    @staticmethod
    def feed(files, commit=COMMIT, build='4001', version='1.1.0', **overrides):
        payload = {'schema': 1, 'version': version, 'build': build, 'sourceCommit': commit,
                   'files': [{'path': path, 'sha256': hashlib.sha256(data).hexdigest(), 'mode': mode}
                             for path, (data, mode) in sorted(files.items())]}
        payload.update(overrides)
        encoded = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        return json.dumps({'payload': base64.b64encode(encoded).decode(),
                           'signature': base64.b64encode(bytes(64)).decode()}, sort_keys=True).encode()

    def codeload(self, files, commit=COMMIT, root=None, comment=None, compress=True, name='codeload.tar.gz'):
        root = root or 'openbots-' + commit
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT,
                          pax_headers={'comment': comment or commit}) as output:
            folders = sorted({'/'.join(path.split('/')[:i]) for path in files for i in range(1, path.count('/') + 1)})
            for folder in [''] + folders:
                entry = tarfile.TarInfo((root + '/' + folder).rstrip('/') + '/'); entry.type = tarfile.DIRTYPE; entry.mode = 0o775
                output.addfile(entry)
            for path, (data, mode) in sorted(files.items()):
                entry = tarfile.TarInfo(root + '/' + path); entry.size = len(data)
                entry.mode = 0o775 if mode == '100755' else 0o664
                output.addfile(entry, io.BytesIO(data))
        data = gzip.compress(buffer.getvalue()) if compress else buffer.getvalue()
        path = self.root / name
        path.write_bytes(data)
        return path

    @staticmethod
    def fingerprint(app):
        return bootstrap.hashlib.sha256((app / 'Contents/Info.plist').read_bytes()).hexdigest()

    def fake_worker(self):
        return SimpleNamespace(processes=object(), bundle_fingerprint=self.fingerprint,
            copy_bundle=lambda src, dst, check: shutil.copytree(src, dst, symlinks=True),
            permissions_compatible=lambda old, new: old == new,
            write_json=lambda path, value: bootstrap.write_new(path, json.dumps(value).encode()))

    def test_permissions_ignore_codesign_display_lines_around_the_plist(self):
        # codesign writes the entitlements to stdout and "Executable=…" to stderr;
        # run() hands back both, in either order. An upgrade over an installed app
        # failed on 17 October 2026 because the display lines were parsed as XML.
        plist = bootstrap.plistlib.dumps({'com.apple.security.automation.apple-events': True})
        display = b'Executable=/Applications/OpenBots Next.app/Contents/MacOS/OpenBots Next\nIdentifier=x\n'
        for data in (plist + display, display + plist, plist):
            with patch.object(bootstrap, 'run', return_value=data):
                self.assertEqual(bootstrap.permissions(Path('/x')), {'com.apple.security.automation.apple-events': True})
        with patch.object(bootstrap, 'run', return_value=b'Executable=/x\n'):
            self.assertEqual(bootstrap.permissions(Path('/x')), {})
        with patch.object(bootstrap, 'run', return_value=plist[:40] + display), self.assertRaises(bootstrap.BootstrapError):
            bootstrap.permissions(Path('/x'))

    def test_launcher_curl_has_only_allowlisted_environment_and_no_config(self):
        launcher = Path(__file__).parents[1] / 'install.sh'
        logical_lines = re.sub(r'\\\n\s*', ' ', launcher.read_text()).splitlines()
        calls = [line for line in logical_lines if '/usr/bin/curl' in line]
        self.assertEqual(len(calls), 2)
        for line in calls:
            self.assertIn('/usr/bin/env', line)
            tokens = shlex.split(line[line.index('/usr/bin/env'):])
            self.assertEqual(tokens[:2], ['/usr/bin/env', '-i'])
            curl_index = tokens.index('/usr/bin/curl')
            self.assertEqual(dict(token.split('=', 1) for token in tokens[2:curl_index]), {
                'HOME': '/nonexistent', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C'})
            self.assertEqual(tokens[curl_index + 1], '-q')
            self.assertIn("--proto '=https'", line)
            self.assertNotIn('NETRC', line)
        # The launcher reads the release feed, never the moving branch head.
        self.assertIn('/main/docs/updates/source-update.json', calls[0])
        self.assertIn('$bootstrap_commit/Scripts/bootstrap-install.py', calls[1])
        self.assertNotIn('api.github.com', launcher.read_text())
        # The downloaded bootstrap is compared with the feed's SHA-256 before it runs.
        text = launcher.read_text()
        check = text.index('[ "$downloaded_sha256" = "$bootstrap_sha256" ]')
        self.assertLess(text.index('-o "$bootstrap_work/bootstrap-install.py"'), check)
        self.assertLess(check, text.index('/usr/bin/python3 -I -B -S "$bootstrap_work/bootstrap-install.py"'))

    def test_launcher_reads_commit_and_bootstrap_hash_from_the_feed(self):
        launcher = (Path(__file__).parents[1] / 'install.sh').read_text()
        program = re.search(r"feed_values=\$\(/usr/bin/python3 -I -B -S -c '(.*?)'", launcher, re.S).group(1)
        files = self.release_files()
        files['Scripts/bootstrap-install.py'] = (b'reviewed bootstrap', '100755')
        feed = self.root / 'feed.json'
        feed.write_bytes(self.feed(files))
        result = subprocess.run(['/usr/bin/python3', '-I', '-B', '-S', '-c', program, str(feed)],
                                capture_output=True, timeout=30, env={'PATH': '/usr/bin:/bin'})
        self.assertEqual(result.stdout.decode().split(), [COMMIT, hashlib.sha256(b'reviewed bootstrap').hexdigest()])

    def test_legacy_google_id_preserved_without_explicit_input(self):
        value = 'example.apps.googleusercontent.com'
        self.assertEqual(bootstrap.selected_client({'OpenBotsGoogleOAuthClientID': value}, None), value)
        self.assertEqual(bootstrap.selected_client(None, value), value)
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.selected_client({'OpenBotsGoogleOAuthClientID': value}, 'different.apps.googleusercontent.com')

    def test_google_id_can_be_added_later_and_replaced_only_on_request(self):
        new = 'new.apps.googleusercontent.com'
        empty = {'OpenBotsGoogleOAuthClientID': '', 'OpenBotsGoogleConfigurationVersion': 1}
        self.assertEqual(bootstrap.selected_client(empty, new), new)
        self.assertEqual(bootstrap.selected_client({}, new), new)
        existing = {'OpenBotsGoogleOAuthClientID': 'old.apps.googleusercontent.com', 'OpenBotsGoogleConfigurationVersion': 1}
        with self.assertRaisesRegex(bootstrap.BootstrapError, 'OPENBOTS_REPLACE_GOOGLE_CLIENT_ID'):
            bootstrap.selected_client(existing, new)
        self.assertEqual(bootstrap.selected_client(existing, new, replace=True), new)
        self.assertEqual(bootstrap.selected_client(existing, 'old.apps.googleusercontent.com', replace=True),
                         'old.apps.googleusercontent.com')
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.selected_client(existing, None, replace=True)

    def test_empty_saved_configuration_marker_is_respected(self):
        self.assertEqual(bootstrap.selected_client({'OpenBotsGoogleOAuthClientID': '', 'OpenBotsGoogleConfigurationVersion': 1}, None), '')
        for old in ({'OpenBotsGoogleOAuthClientID': 1}, {'OpenBotsGoogleOAuthClientID': 'broken'},
                    {'OpenBotsGoogleConfigurationVersion': True}, {'OpenBotsGoogleConfigurationVersion': 2}):
            with self.subTest(old=old), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.selected_client(old, None)

    def test_downgrade_refused_and_equal_or_newer_allowed(self):
        bootstrap.refuse_downgrade(None, '4001')
        bootstrap.refuse_downgrade({'CFBundleVersion': '4001'}, '4001')
        bootstrap.refuse_downgrade({'CFBundleVersion': '3'}, '4001')
        bootstrap.refuse_downgrade({'CFBundleVersion': '2026.8.30'}, '3008')
        with self.assertRaisesRegex(bootstrap.BootstrapError, 'newer than this release'):
            bootstrap.refuse_downgrade({'CFBundleVersion': '4002'}, '4001')
        for value in (None, 4002, '', 'abc', '1..2'):
            with self.subTest(value=value), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.refuse_downgrade({'CFBundleVersion': value}, '4001')

    def test_existing_signing_team_cannot_be_replaced(self):
        signing = SimpleNamespace(choose_identity=lambda team, path: 'A' * 40, BuildFailure=Failure)
        self.assertEqual(bootstrap.select_team(signing, 'ABCDEFGHIJ', None), 'ABCDEFGHIJ')
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.select_team(signing, 'ABCDEFGHIJ', 'KLMNOPQRST')
        with patch.object(bootstrap, 'available_teams', return_value={'ABCDEFGHIJ', 'KLMNOPQRST'}):
            with self.assertRaisesRegex(bootstrap.BootstrapError, 'OPENBOTS_DEVELOPMENT_TEAM'):
                bootstrap.select_team(signing, None, None)
        with patch.object(bootstrap, 'available_teams', return_value={'ABCDEFGHIJ'}):
            self.assertEqual(bootstrap.select_team(signing, None, None), 'ABCDEFGHIJ')

    def test_no_certificate_and_signing_failures_reach_the_user(self):
        def refuse(arguments, data=None):
            raise Failure('A required local build tool refused the operation.')
        signing = SimpleNamespace(run=refuse, BuildFailure=Failure, choose_identity=lambda team, path: 'A' * 40)
        self.assertEqual(bootstrap.available_teams(signing, self.root / 'login.keychain-db'), set())
        with self.assertRaisesRegex(bootstrap.BootstrapError, 'Set up an Apple Development certificate in Xcode'):
            bootstrap.select_team(signing, None, None)
        def mismatch(team, path):
            raise Failure('No local Apple Development certificate matches the installed app. Check signing in Xcode.')
        signing.choose_identity = mismatch
        with self.assertRaisesRegex(bootstrap.BootstrapError, 'No local Apple Development certificate matches'):
            bootstrap.select_team(signing, 'ABCDEFGHIJ', None)

    def xcode(self, version):
        xcode = self.root / 'Xcode.app'
        (xcode / 'Contents').mkdir(parents=True, exist_ok=True)
        (xcode / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
        return xcode

    def test_xcode_preflight_names_version_and_license_problems(self):
        ok = SimpleNamespace(returncode=0, stdout=b'Xcode 16.3\nBuild version 16E140\n')
        license_text = b'You have not agreed to the Xcode license agreements. Please run sudo xcodebuild -license.'
        cases = (('16.2', ok, 'needs Xcode 16.3 or later \\(found 16.2\\)'),
                 ('15.4.1', ok, 'found 15.4.1'),
                 ('16.4', SimpleNamespace(returncode=69, stdout=license_text), 'Accept the Xcode license'),
                 ('16.4', SimpleNamespace(returncode=1, stdout=b'unexpected'), 'Open Xcode once'))
        for version, result, message in cases:
            with self.subTest(version=version, message=message), patch.object(bootstrap, 'XCODE', self.xcode(version)), \
                    patch.object(bootstrap.subprocess, 'run', return_value=result), \
                    self.assertRaisesRegex(bootstrap.BootstrapError, message):
                bootstrap.xcode_preflight()
        with patch.object(bootstrap, 'XCODE', self.xcode('16.3')), patch.object(bootstrap.subprocess, 'run', return_value=ok) as tool:
            bootstrap.xcode_preflight()
        self.assertEqual(tool.call_args.args[0][1:], ['-version'])
        with patch.object(bootstrap, 'XCODE', self.root / 'Missing.app'), \
                self.assertRaisesRegex(bootstrap.BootstrapError, 'Install full Xcode'):
            bootstrap.xcode_preflight()

    def test_archive_normalizes_modes_and_refuses_unsafe_entries(self):
        bootstrap.extract_source(self.archive(), self.root / 'valid')
        self.assertEqual((self.root / 'valid/Scripts/build-source-update.sh').stat().st_mode & 0o777, 0o755)
        for index, entry in enumerate((('source/../escape', tarfile.REGTYPE), ('source/link', tarfile.SYMTYPE),
                ('source/.git/config', tarfile.REGTYPE), ('source/private.noindex/state', tarfile.REGTYPE),
                ('source/Scripts/build-source-update.sh', tarfile.REGTYPE), ('source/scripts/test', tarfile.REGTYPE),
                ('source/Scripts', tarfile.REGTYPE), ('other-root/file', tarfile.REGTYPE))):
            with self.subTest(entry=entry), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.extract_source(self.archive([entry]), self.root / ('invalid' + str(index)))

    def test_gzip_archive_extracts_with_the_names_main_uses(self):
        # main() downloads to work/source.download and extracts to work/source;
        # the expanded tar must not collide with either and must not remain.
        files = self.release_files()
        release = bootstrap.parse_release(self.feed(files))
        work = self.root / 'work'; work.mkdir()
        shutil.copyfile(self.codeload(files), work / 'source.download')
        bootstrap.extract_source(work / 'source.download', work / 'source', release)
        self.assertEqual((work / 'source/Sources/Example.swift').read_bytes(), b'reviewed source')
        self.assertEqual(sorted(path.name for path in work.iterdir()), ['source', 'source.download'])

    def run_main(self, arguments, files, archive_bytes, feed=None):
        seen = {}
        def download(commit, target):
            seen['download'] = (commit, target.name)
            bootstrap.write_new(target, archive_bytes)
        def modules(source):
            seen['tree'] = sorted(path.relative_to(source).as_posix() for path in source.rglob('*') if path.is_file())
            seen['work'] = sorted(path.name for path in source.parent.iterdir())
            raise bootstrap.BootstrapError('fixture stops before any downloaded code runs')
        stderr = io.StringIO()
        make_temporary = tempfile.mkdtemp
        with patch.object(sys, 'argv', ['bootstrap-install.py'] + arguments), \
                patch.object(bootstrap, 'host_preflight'), \
                patch.object(bootstrap, 'fetch_feed', return_value=feed or self.feed(files)), \
                patch.object(bootstrap, 'download', side_effect=download), \
                patch.object(bootstrap, 'source_modules', side_effect=modules), \
                patch.object(bootstrap.tempfile, 'mkdtemp', side_effect=lambda prefix: make_temporary(prefix=prefix, dir=self.root)), \
                contextlib.redirect_stderr(stderr):
            code = bootstrap.main()
        return code, stderr.getvalue(), seen

    def test_main_downloads_released_commit_and_extracts_gzip(self):
        files = self.release_files()
        archive = self.codeload(files).read_bytes()
        code, stderr, seen = self.run_main(['--commit', COMMIT], files, archive)
        self.assertEqual(code, 1)
        self.assertIn('fixture stops before any downloaded code runs', stderr)
        self.assertEqual(seen['download'], (COMMIT, 'source.download'))
        self.assertEqual(seen['tree'], sorted(files))
        self.assertEqual(seen['work'], ['source'])
        self.assertEqual([path for path in self.root.iterdir() if path.name.startswith('openbots-bootstrap-')], [])
        code, stderr, seen = self.run_main(['--commit', 'd' * 40], files, archive)
        self.assertIn('The published release changed while installing', stderr)
        self.assertNotIn('download', seen)

    def test_main_checks_a_local_gzip_archive_against_the_release(self):
        files = self.release_files()
        good = self.codeload(files, name='good.tar.gz')
        code, stderr, seen = self.run_main(['--archive', str(good)], files, b'')
        self.assertIn('fixture stops before any downloaded code runs', stderr)
        self.assertNotIn('download', seen)
        tampered = dict(files); tampered['Sources/Example.swift'] = (b'tampered source', '100644')
        code, stderr, seen = self.run_main(['--archive', str(self.codeload(tampered, name='bad.tar.gz'))], files, b'')
        self.assertEqual(code, 1)
        self.assertIn('SHA-256', stderr)
        self.assertNotIn('tree', seen)

    def test_release_feed_is_validated_like_the_app_manifest(self):
        files = self.release_files()
        release = bootstrap.parse_release(self.feed(files))
        self.assertEqual((release['commit'], release['build'], release['version']), (COMMIT, '4001', '1.1.0'))
        self.assertEqual(set(release['files']), set(files))
        good = json.loads(self.feed(files))
        payload = json.loads(base64.b64decode(good['payload']))
        def envelope(value, signature=bytes(64)):
            return json.dumps({'payload': base64.b64encode(json.dumps(value).encode()).decode(),
                               'signature': base64.b64encode(signature).decode()}).encode()
        def entry(path, mode='100644'):
            return {'path': path, 'sha256': 'a' * 64, 'mode': mode}
        bad = [b'{"payload": "x", "payload": "y", "signature": ""}', b'[]', b'not json',
               envelope(payload, signature=bytes(63)),
               envelope(dict(payload, schema=True)), envelope(dict(payload, schema=2)),
               envelope(dict(payload, build='0')), envelope(dict(payload, build=4001)),
               envelope(dict(payload, version='1')), envelope(dict(payload, sourceCommit='C' * 40)),
               envelope(dict(payload, extra=1)), envelope(dict(payload, files=[])),
               envelope(dict(payload, files=payload['files'] + [entry('tool', '100777')])),
               envelope(dict(payload, files=payload['files'] + [entry('.git/config')])),
               envelope(dict(payload, files=payload['files'] + [entry('cache.noindex/state')])),
               envelope(dict(payload, files=payload['files'] + [entry('../escape')])),
               envelope(dict(payload, files=payload['files'] + [entry('sources/Example.swift')])),
               envelope(dict(payload, files=payload['files'] + [entry('Scripts/swiftpm-public.sh/inner')])),
               envelope(dict(payload, files=payload['files'] + [payload['files'][0]])),
               envelope(dict(payload, files=[item for item in payload['files'] if item['path'] != 'Scripts/swiftpm-public.sh']))]
        for index, data in enumerate(bad):
            with self.subTest(index=index), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.parse_release(data)

    def test_missing_feed_refuses_instead_of_building_the_branch_head(self):
        def missing():
            def open_(request, timeout):
                raise urllib.error.HTTPError(request.full_url, 404, 'Not Found', {}, None)
            return SimpleNamespace(open=open_)
        with patch.object(bootstrap, 'opener', missing), \
                self.assertRaisesRegex(bootstrap.BootstrapError, 'No published release yet'):
            bootstrap.fetch_feed()

    def test_archive_must_match_release_inventory_exactly(self):
        files = self.release_files()
        release = bootstrap.parse_release(self.feed(files))
        bootstrap.extract_source(self.codeload(files), self.root / 'valid', release)
        self.assertEqual((self.root / 'valid/Scripts/swiftpm-public.sh').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.root / 'valid/Sources/Example.swift').stat().st_mode & 0o777, 0o644)
        extra = dict(files); extra['Sources/Unlisted.swift'] = (b'unlisted', '100644')
        missing = dict(files); del missing['Sources/Example.swift']
        changed = dict(files); changed['Sources/Example.swift'] = (b'changed', '100644')
        mode = dict(files); mode['Sources/Example.swift'] = (b'reviewed source', '100755')
        for index, archive in enumerate((self.codeload(extra, name='1.tgz'), self.codeload(missing, name='2.tgz'),
                                         self.codeload(changed, name='3.tgz'), self.codeload(mode, name='4.tgz'),
                                         self.codeload(files, root='openbots-' + 'd' * 40, name='5.tgz'),
                                         self.codeload(files, comment='d' * 40, name='6.tgz'))):
            with self.subTest(index=index), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.extract_source(archive, self.root / ('invalid' + str(index)), release)

    def test_tree_changed_after_extraction_is_refused(self):
        files = self.release_files()
        release = bootstrap.parse_release(self.feed(files))
        bootstrap.extract_source(self.codeload(files), self.root / 'tree', release)
        (self.root / 'tree/Sources/Example.swift').write_bytes(b'edited after extraction')
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.verify_tree(self.root / 'tree', release['files'])
        (self.root / 'tree/Sources/Example.swift').write_bytes(b'reviewed source')
        bootstrap.verify_tree(self.root / 'tree', release['files'])
        (self.root / 'tree/Sources/Example.swift').chmod(0o755)
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.verify_tree(self.root / 'tree', release['files'])

    def test_candidate_identity_google_and_enabled_channel(self):
        app = self.app(self.root)
        signing = SimpleNamespace(native_inventory=lambda path: ([path / 'Contents/MacOS/OpenBots Next'], []))
        worker = self.fake_worker()
        with patch.object(bootstrap, 'signature', return_value=self.contract['team']):
            bootstrap.verify_candidate(app, self.contract, signing, worker)
            path = app / 'Contents/Info.plist'
            original = plistlib.loads(path.read_bytes())
            for key, value in (('OpenBotsSourceUpdateEnabled', False), ('OpenBotsSourceUpdateFeedURL', 'https://example.invalid/feed'),
                ('OpenBotsGoogleOAuthClientID', 'different.apps.googleusercontent.com'), ('CFBundleVersion', '4000'),
                ('OpenBotsGoogleConfigurationVersion', True), ('OpenBotsSourceCommit', 'b' * 40)):
                changed = dict(original); changed[key] = value; path.write_bytes(plistlib.dumps(changed))
                with self.subTest(key=key), self.assertRaises(bootstrap.BootstrapError):
                    bootstrap.verify_candidate(app, self.contract, signing, worker)
            changed = dict(original); changed['OpenBotsSourceUpdateEnabled'] = False
            path.write_bytes(plistlib.dumps(changed))
            bootstrap.verify_candidate(app, self.contract, signing, worker, require_channel=False)

    def transaction_patches(self, verifier=None):
        return (patch.object(bootstrap, 'stopped'), patch.object(bootstrap, 'signature', return_value=self.contract['team']),
                patch.object(bootstrap, 'permissions', return_value={}),
                patch.object(bootstrap, 'verify_candidate', side_effect=verifier or (lambda app, *a, **k: self.fingerprint(app))))

    def install_fixture(self, old_build='4000', previous_rollback=True):
        apps = self.root / 'Applications'; apps.mkdir()
        rollback = self.root / 'Support/HighChurn.noindex/SourceUpdates/Rollback'
        self.scratch = self.root / 'work'; self.scratch.mkdir(mode=0o700)
        old = self.app(apps, build=old_build) if old_build else apps / bootstrap.APP
        if previous_rollback:
            rollback.mkdir(parents=True, mode=0o700)
            self.app(rollback, build='3000')
        candidate = self.app(self.root / 'build')
        return apps, old, rollback, candidate

    def assert_clean(self, apps, rollback):
        self.assertEqual([path.name for path in apps.iterdir() if path.name != bootstrap.APP], [])
        if rollback.exists():
            self.assertEqual([path.name for path in rollback.iterdir()], [bootstrap.APP])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def install(self, candidate, destination, before, rollback, verifier=None, worker=None):
        first, second, third, fourth = self.transaction_patches(verifier)
        with first as stopped, second, third, fourth:
            result = bootstrap.install_candidate(candidate, destination, self.contract, object(), worker or self.fake_worker(),
                                                 before, rollback, self.scratch)
        return result, stopped

    def refuse_renaming(self, inode):
        # Fails the test if the installed bundle's directory is ever renamed.
        rename, exchange = os.rename, bootstrap.exchange
        def guard(source):
            if Path(source).exists() and Path(source).lstat().st_ino == inode:
                raise AssertionError('The installed bundle was renamed: ' + str(source))
        def guarded_rename(source, target, *args, **kwargs):
            guard(source); return rename(source, target, *args, **kwargs)
        def guarded_exchange(source, target, flags):
            guard(source); guard(target); return exchange(source, target, flags)
        return (patch.object(bootstrap.os, 'rename', guarded_rename), patch.object(bootstrap.os, 'replace', guarded_rename),
                patch.object(bootstrap, 'exchange', guarded_exchange))

    def test_existing_bundle_copied_to_one_rollback_and_never_moved(self):
        apps, old, rollback, candidate = self.install_fixture()
        before, old_inode = self.fingerprint(old), old.stat().st_ino
        first, second, third = self.refuse_renaming(old_inode)
        with first, second, third:
            previous, stopped = self.install(candidate, old, before, rollback)
        self.assertEqual([call.args[0] for call in stopped.call_args_list], [old, old])
        self.assertEqual(previous, rollback / bootstrap.APP)
        self.assertEqual(self.fingerprint(previous), before)
        self.assertEqual(self.fingerprint(old), self.fingerprint(candidate))
        self.assertNotIn(old_inode, {old.stat().st_ino, previous.stat().st_ino})
        # The candidate is copied straight from private staging; nothing is
        # staged inside the Applications folder.
        self.assertEqual(self.copies[1], (candidate, old))
        self.assertTrue(all(apps not in target.parents for _, target in self.copies if target != old))
        self.assert_clean(apps, rollback)
        self.assertIn(('-u', candidate), self.registrations)
        self.assertIn(('-u', previous), self.registrations)
        self.assertEqual(self.registrations[-1], ('-f', old))

    def test_failure_after_removal_restores_the_previous_app_by_copy(self):
        apps, destination, rollback, candidate = self.install_fixture()
        before, inode = self.fingerprint(destination), destination.stat().st_ino
        earlier = self.fingerprint(rollback / bootstrap.APP)

        def verify(app, *args, **kwargs):
            if app == destination:
                raise bootstrap.BootstrapError('Synthetic post-copy failure')
            return self.fingerprint(app)

        first, second, third = self.refuse_renaming(inode)
        with first, second, third, self.assertRaises(bootstrap.BootstrapError):
            self.install(candidate, destination, before, rollback, verify)
        self.assertEqual(self.fingerprint(destination), before)
        self.assertEqual(self.copies[-1][1], destination)
        self.assertIn(('-f', destination), self.registrations)
        self.assertEqual(self.fingerprint(rollback / bootstrap.APP), earlier)
        self.assert_clean(apps, rollback)

    def test_failure_at_each_step_keeps_the_installed_app(self):
        steps = ('rollback copy', 'rollback fingerprint', 'removal midway', 'install copy fails', 'install copy partial')
        for step in steps:
            with self.subTest(step=step), tempfile.TemporaryDirectory() as folder:
                self.root = Path(folder).resolve()
                self.copies, self.copy_failures = [], {}
                apps, destination, rollback, candidate = self.install_fixture()
                before = self.fingerprint(destination)
                earlier = self.fingerprint(rollback / bootstrap.APP)
                worker = self.fake_worker()
                if step == 'rollback copy':
                    self.copy_failures = {1: 'partial'}
                elif step == 'install copy fails':
                    self.copy_failures = {2: 'fail'}
                elif step == 'install copy partial':
                    self.copy_failures = {2: 'partial'}
                elif step == 'rollback fingerprint':
                    worker.bundle_fingerprint = lambda app: 'different' if '.incoming-' in str(app) else self.fingerprint(app)
                remove = bootstrap.remove_owned
                def partial(path):
                    if path == destination and (path / 'Contents/MacOS').exists():
                        shutil.rmtree(path / 'Contents/MacOS')
                        raise OSError('synthetic removal failure')
                    remove(path)
                extra = patch.object(bootstrap, 'remove_owned', partial) if step == 'removal midway' else contextlib.nullcontext()
                with extra, self.assertRaises((OSError, bootstrap.BootstrapError)):
                    self.install(candidate, destination, before, rollback, None, worker)
                self.assertEqual(self.fingerprint(destination), before)
                self.assertTrue((destination / 'Contents/MacOS/OpenBots Next').is_file())
                self.assertEqual(self.fingerprint(rollback / bootstrap.APP), earlier)
                self.assert_clean(apps, rollback)

    def test_unprovable_restore_keeps_the_previous_copy_and_names_it(self):
        apps, destination, rollback, candidate = self.install_fixture()
        before = self.fingerprint(destination)
        self.copy_failures = {3: 'fail'}
        def verify(app, *args, **kwargs):
            if app == destination:
                raise bootstrap.BootstrapError('Synthetic post-copy failure')
            return self.fingerprint(app)
        with self.assertRaisesRegex(bootstrap.BootstrapError, 'Recovery needs attention') as raised:
            self.install(candidate, destination, before, rollback, verify)
        kept = [path for path in rollback.iterdir() if path.name.startswith('.incoming-')]
        self.assertEqual(len(kept), 1)
        self.assertIn('/usr/bin/ditto "' + str(kept[0] / bootstrap.APP) + '"', str(raised.exception))
        self.assertEqual(self.fingerprint(kept[0] / bootstrap.APP), before)

    def test_first_install_creates_no_rollback_and_cleans_up_on_failure(self):
        apps, destination, rollback, candidate = self.install_fixture(old_build=None, previous_rollback=False)
        previous, _ = self.install(candidate, destination, None, rollback)
        self.assertIsNone(previous)
        self.assertEqual(self.fingerprint(destination), self.fingerprint(candidate))
        self.assertFalse(rollback.exists())
        self.assert_clean(apps, rollback)
        self.assertEqual(self.registrations[-1], ('-f', destination))
        shutil.rmtree(destination)

        def verify(app, *args, **kwargs):
            if app == destination:
                raise bootstrap.BootstrapError('Synthetic post-copy failure')
            return self.fingerprint(app)
        with self.assertRaises(bootstrap.BootstrapError):
            self.install(candidate, destination, None, rollback, verify)
        self.assertEqual(list(apps.iterdir()), [])

    def test_installed_app_without_support_folder_is_replaced_without_rollback(self):
        apps, old, rollback, candidate = self.install_fixture(previous_rollback=False)
        before = self.fingerprint(old)
        previous, _ = self.install(candidate, old, before, None)
        self.assertIsNone(previous)
        self.assertEqual(self.fingerprint(old), self.fingerprint(candidate))
        self.assertFalse(rollback.parent.exists())
        self.assert_clean(apps, rollback)
        shutil.rmtree(old); self.app(apps, build='4000')

        def verify(app, *args, **kwargs):
            if app == old:
                raise bootstrap.BootstrapError('Synthetic post-copy failure')
            return self.fingerprint(app)
        # The temporary copy in private scratch restores the app, then goes.
        with self.assertRaises(bootstrap.BootstrapError):
            self.install(candidate, old, before, None, verify)
        self.assertEqual(self.fingerprint(old), before)
        self.assert_clean(apps, rollback)

    def test_running_destination_blocks_before_staging(self):
        apps = self.root / 'Applications'; apps.mkdir()
        old = self.app(apps, build='4000')
        candidate = self.app(self.root / 'build')
        with patch.object(bootstrap, 'stopped', side_effect=bootstrap.BootstrapError('Running')):
            with self.assertRaises(bootstrap.BootstrapError):
                bootstrap.install_candidate(candidate, old, self.contract, object(), self.fake_worker(), self.fingerprint(old),
                                            self.root / 'Rollback', self.root)
        self.assertEqual(list(apps.iterdir()), [old])
        self.assertFalse((self.root / 'Rollback').exists())

    def test_clean_work_refuses_path_replacement(self):
        owned = self.root / 'work'; owned.mkdir()
        info = owned.stat(); identity = (info.st_dev, info.st_ino)
        retained = self.root / 'retained'; owned.rename(retained)
        owned.symlink_to(retained, target_is_directory=True)
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.clean_owned_work(owned, identity)
        self.assertTrue(retained.exists())

    def test_parent_death_cleans_owned_cohort_and_removes_exact_job(self):
        stage = self.root / 'stage'; stage.mkdir(mode=0o700)
        nonce = 'b' * 32
        bootstrap.write_new(stage / 'bootstrap.json', json.dumps({'nonce': nonce, 'source': str(self.root), 'contract': self.contract}).encode())
        launch = {'nonce': nonce, 'controllerIdentity': {'pid': 123}, 'hostIdentity': {'pid': 123}}
        events = []
        # These represent ordinary and immediately detached descendants. The
        # bootstrap delegates both to production cohort ownership, never PPID/PGID.
        descendants = {124, 125}
        worker = SimpleNamespace(controller_identity={'pid': 123}, api=SimpleNamespace(alive=lambda _: False),
            owner=SimpleNamespace(coalition=77, assert_alone=lambda: self.assertEqual(descendants, set())),
            admit=lambda: None, run=lambda *a, **k: (_ for _ in ()).throw(bootstrap.BootstrapError('Parent died')),
            stop_children=lambda: (events.append('stop-cohort'), descendants.clear()))
        module = SimpleNamespace(Worker=lambda *args: worker, private_json=lambda *a, **k: launch,
            write_json=lambda path, value: events.append(value),
            processes=SimpleNamespace(service_name=lambda n: 'exact-' + n, launchctl=lambda args: events.append(args)))
        with patch.object(bootstrap, 'source_modules', return_value=(object(), module)), patch.object(bootstrap.signal, 'signal'):
            self.assertEqual(bootstrap.owned_build(stage, nonce), 1)
        self.assertIn('stop-cohort', events)
        self.assertEqual(events[-1], ['bootout', 'exact-' + nonce])
        self.assertTrue(events[-2]['childrenStopped'])
        self.assertIn(b'Parent died', (stage / 'build.log').read_bytes())

    def test_failed_build_output_is_kept_in_a_private_bounded_log(self):
        stage = self.root / 'stage'; stage.mkdir(mode=0o700)
        nonce = 'b' * 32
        bootstrap.write_new(stage / 'bootstrap.json', json.dumps({'nonce': nonce, 'source': str(self.root), 'contract': self.contract}).encode())
        launch = {'nonce': nonce, 'controllerIdentity': {'pid': 123}, 'hostIdentity': {'pid': 123}}
        output = b'x' * (2 * bootstrap.MAX_LOG) + b'\nerror: No signing certificate "Apple Development" found\n'
        worker = SimpleNamespace(controller_identity={'pid': 123}, api=SimpleNamespace(alive=lambda _: True),
            owner=SimpleNamespace(coalition=77, assert_alone=lambda: None), admit=lambda: None,
            run=lambda *a, **k: (65, output), stop_children=lambda: None)
        module = SimpleNamespace(Worker=lambda *args: worker, private_json=lambda *a, **k: launch,
            write_json=lambda path, value: None, processes=SimpleNamespace())
        with patch.object(bootstrap, 'source_modules', return_value=(object(), module)), patch.object(bootstrap.signal, 'signal'):
            self.assertEqual(bootstrap.owned_build(stage, nonce), 1)
        (stage / 'job-stderr.log').write_bytes(b'launchd stderr line\n')
        log = self.root / 'Logs/OpenBots Next/bootstrap-build.log'
        self.assertEqual(bootstrap.publish_build_log(stage, log), log)
        data = log.read_bytes()
        self.assertLessEqual(len(data), bootstrap.MAX_LOG)
        self.assertIn(b'No signing certificate', data)
        self.assertIn(b'exited with status 65', data)
        self.assertIn(b'launchd stderr line', data)
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(log.parent.stat().st_mode & 0o777, 0o700)
        self.assertIn('No signing certificate', bootstrap.log_excerpt(log))

    def test_build_controller_cancel_reaps_acknowledged_cohort(self):
        stage = self.root / 'stage'; stage.mkdir(mode=0o700)
        controller = {'pid': os.getpid(), 'coalition': 10}
        child = {'pid': 99999, 'coalition': 20}
        events = []
        api = SimpleNamespace(identity=lambda pid: controller if pid == os.getpid() else child,
            members=lambda c: {child['pid']: child}, active=lambda c: 1, alive=lambda i: True)
        module = self.fake_worker()
        def write_json(path, value):
            bootstrap.write_new(path, json.dumps(value).encode())
        def launch(arguments):
            definition = plistlib.loads((stage / 'build-job.plist').read_bytes())
            self.assertEqual(definition['StandardErrorPath'], str(stage / 'job-stderr.log'))
            config = json.loads((stage / 'bootstrap.json').read_bytes())
            write_json(stage / 'started.json', {'nonce': config['nonce'], 'population': 1, 'coalition': 20, 'identity': child})
            (stage / 'job-stderr.log').write_bytes(b'xcodebuild: error: synthetic failure\n')
            (stage / 'cancel').touch()
            return SimpleNamespace(returncode=0)
        module.write_json = write_json
        module.private_json = lambda path, **kwargs: json.loads(path.read_bytes())
        module.cancellation_file = lambda s: (s / 'cancel').touch()
        module.processes = SimpleNamespace(Metadata=lambda: api, service_name=lambda n: 'gui/1/' + n,
            service_absent=lambda s: True, launchctl=launch, same_identity=lambda a, b: a == b,
            stop_entire_coalition=lambda a, c: events.append(('stop', c)), remove_job=lambda s, c, a: events.append(('remove', c)))
        log = self.root / 'Logs/OpenBots Next/bootstrap-build.log'
        with patch.object(bootstrap.signal, 'signal', return_value=None):
            with self.assertRaises(bootstrap.BootstrapError) as raised:
                bootstrap.supervised_build(self.root, stage, self.contract, module, log)
        self.assertEqual(events, [('stop', 20), ('remove', 20)])
        self.assertTrue(json.loads((stage / 'cleanup.json').read_bytes())['stopped'])
        self.assertIn('Build log: ' + str(log), str(raised.exception))
        self.assertIn('synthetic failure', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
