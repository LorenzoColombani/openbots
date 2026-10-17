"""Local build signing guards; no real certificate/key/build operations."""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('source_build_signing',
    Path(__file__).resolve().parents[2] / 'Scripts/source-update-sign.py')
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class BuildSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = argparse.Namespace(commit='a' * 40, build='3008', version='1.1.0', team='ABCDEFGHIJ',
            google_client_id='', identity='B' * 40, keychain=str(self.root / 'login.keychain-db'))

    def app(self):
        app = self.root / 'OpenBots Next.app'
        binary = app / 'Contents/MacOS/OpenBots Next'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'synthetic fixture; never executable')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': signing.BUNDLE_ID, 'CFBundleExecutable': 'OpenBots Next',
            'CFBundleVersion': self.args.build, 'CFBundleShortVersionString': self.args.version,
            'OpenBotsSourceCommit': self.args.commit, 'OpenBotsGoogleOAuthClientID': '',
            'OpenBotsGoogleConfigurationVersion': 1}))
        self.args.app = str(app)
        return app

    def test_arguments_are_bounded_and_cannot_be_tool_options(self):
        signing.validate_arguments(self.args)
        for name, value in [('commit', '--help'), ('build', '2026.10.15'), ('build', '03008'),
                            ('team', 'wrong'), ('google_client_id', 'not-a-client-secret'),
                            ('google_client_id', 'a' * 513 + '.apps.googleusercontent.com')]:
            args = argparse.Namespace(**vars(self.args)); setattr(args, name, value)
            with self.subTest(name=name), self.assertRaises(signing.BuildFailure):
                signing.validate_arguments(args)

    def test_only_narrow_signing_tools_get_real_home(self):
        with patch.object(signing.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'', stderr=b'')) as tool:
            signing.run(['/usr/bin/security', 'find-identity'])
            self.assertEqual(tool.call_args.kwargs['env']['HOME'], str(Path.home()))
            signing.run(['/usr/bin/openssl', 'x509'])
            self.assertEqual(tool.call_args.kwargs['env']['HOME'], '/nonexistent')
            self.assertNotIn('SSH_AUTH_SOCK', tool.call_args.kwargs['env'])

    def test_toolchain_requires_supported_full_xcode(self):
        for version in ('16.3', '16.4', '26.0'):
            with patch.object(signing, 'run', return_value=('Xcode ' + version + '\nBuild version test\n').encode()):
                signing.validate_toolchain()
        for output in (b'Xcode 16.2\n', b'Xcode 15.4\n', b'unknown\n'):
            with patch.object(signing, 'run', return_value=output), self.assertRaises(signing.BuildFailure):
                signing.validate_toolchain()

    def test_failed_tool_does_not_echo_private_output(self):
        with patch.object(signing.subprocess, 'run', return_value=SimpleNamespace(returncode=1,
                stdout=b'private-account-value', stderr=b'/Users/fixture/credentials')):
            with self.assertRaises(signing.BuildFailure) as error:
                signing.run(['/usr/bin/security', 'find-identity'])
            self.assertNotIn('private', str(error.exception))
            self.assertNotIn('/Users', str(error.exception))

    def test_certificate_selection_matches_team_and_usable_identity(self):
        Path(self.args.keychain).write_bytes(b'placeholder; never opened')
        identities = ('  1) ' + 'B' * 40 + ' "Apple Development: Example"\n').encode()
        certificates = b'-----BEGIN CERTIFICATE-----\nsynthetic\n-----END CERTIFICATE-----'
        metadata = ('subject=CN=Example,OU=ABCDEFGHIJ,O=Example\nSHA1 Fingerprint=' + ':'.join(['BB'] * 20) + '\n').encode()
        with patch.object(signing, 'run', side_effect=[identities, certificates, metadata]):
            self.assertEqual(signing.choose_identity(self.args.team, self.args.keychain), 'B' * 40)
        with patch.object(signing, 'run', side_effect=[identities, certificates, metadata.replace(b'ABCDEFGHIJ', b'ZZZZZZZZZZ')]):
            with self.assertRaises(signing.BuildFailure):
                signing.choose_identity(self.args.team, self.args.keychain)

    def test_inventory_refuses_escaping_link_and_hardlink(self):
        app = self.app()
        outside = self.root / 'outside'; outside.write_bytes(b'outside')
        alias = app / 'Contents/alias'; alias.symlink_to(outside)
        with self.assertRaises(signing.BuildFailure): signing.native_inventory(app)
        alias.unlink()
        os.link(app / 'Contents/MacOS/OpenBots Next', app / 'Contents/linked')
        with self.assertRaises(signing.BuildFailure): signing.native_inventory(app)

    def test_plist_refuses_wrong_source_google_or_marker(self):
        app = self.app(); path = app / 'Contents/Info.plist'
        original = plistlib.loads(path.read_bytes())
        for key, value in [('OpenBotsSourceCommit', 'c' * 40), ('OpenBotsGoogleOAuthClientID', 'other.apps.googleusercontent.com'),
                            ('OpenBotsGoogleConfigurationVersion', True), ('CFBundleIdentifier', 'org.example.other')]:
            with self.subTest(key=key):
                changed = dict(original); changed[key] = value; path.write_bytes(plistlib.dumps(changed))
                with self.assertRaises(signing.BuildFailure): signing.validate_plist(app, self.args)

    def test_signs_every_binary_then_enclosing_app_and_verifies_team(self):
        app = self.app()
        helper = app / 'Contents/MacOS/helper'; helper.write_bytes(b'\xcf\xfa\xed\xfe' + b'never executed')
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return b'TeamIdentifier=ABCDEFGHIJ\nCodeDirectory flags=0x10000(runtime)\n' if '--display' in args else b''
        with patch.object(signing, 'choose_identity', return_value=self.args.identity), patch.object(signing, 'run', side_effect=run):
            signing.sign(self.args)
        targets = [Path(call[-1]) for call in calls if '--force' in call]
        self.assertIn(helper, targets)
        self.assertEqual(targets[-1], app)
        self.assertTrue(all('--keychain' in call and '--options' in call for call in calls if '--force' in call))

    def test_build_directories_reject_link_before_touching_target(self):
        (self.root / 'project.yml').write_text('name: Example')
        (self.root / 'Package.swift').write_text('// synthetic')
        target = self.root / 'outside'; target.mkdir()
        (self.root / '.build.noindex').symlink_to(target, target_is_directory=True)
        with self.assertRaises(signing.BuildFailure): signing.prepare_directories(self.root)
        self.assertEqual(list(target.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
