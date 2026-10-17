#!/usr/bin/env python3
"""Targeted local source-build signing. Never reads or exports a private key."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

BUNDLE_ID = 'com.lorenzocolombani.openbotsnext.preview'
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


class BuildFailure(Exception):
    pass


def require(value, message):
    if not value:
        raise BuildFailure(message)


def run(arguments, data=None, limit=2 * 1024 * 1024):
    # Security.framework resolves the login identity through the user's home
    # even with an explicit Keychain. Only the narrow metadata/signing tools get
    # that home; the compiler and dependency operations remain isolated.
    signing_tool = arguments[0] in {'/usr/bin/security', '/usr/bin/codesign'}
    tool_home = str(Path.home()) if signing_tool else '/nonexistent'
    try:
        result = subprocess.run(arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=60, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                                                 'HOME': tool_home, 'LANG': 'C', 'OPENSSL_CONF': '/dev/null'})
    except (OSError, subprocess.TimeoutExpired):
        raise BuildFailure('A required local build tool could not finish.') from None
    require(result.returncode == 0 and len(result.stdout) <= limit and len(result.stderr) <= limit,
            'A required local build tool refused the operation.')
    return result.stdout + (result.stderr if arguments[0] == '/usr/bin/codesign' else b'')


def validate_arguments(args):
    require(re.fullmatch(r'[a-f0-9]{40}', args.commit or '') is not None, 'Invalid source revision.')
    require(re.fullmatch(r'[1-9][0-9]{0,17}', args.build or '') is not None, 'Invalid ordered build number.')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', args.version or '') is not None, 'Invalid release version.')
    require(re.fullmatch(r'[A-Z0-9]{10}', args.team or '') is not None, 'A matching local development signing team is required.')
    value = args.google_client_id
    require(value == '' or (len(value.encode()) <= 512 and
            re.fullmatch(r'[A-Za-z0-9.-]+\.apps\.googleusercontent\.com', value) is not None),
            'Invalid Google public client configuration.')


def choose_identity(team, keychain):
    require(re.fullmatch(r'[A-Z0-9]{10}', team) is not None, 'Invalid local development team.')
    path = Path(keychain)
    require(path.is_file() and not path.is_symlink() and path.stat().st_uid == os.getuid(),
            'The login Keychain is unavailable.')
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', str(path)]).decode('utf-8', 'strict')
    valid = set(re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"Apple Development:', identities, re.M))
    require(valid, 'Set up a local Apple Development certificate in Xcode before building updates.')
    # Public certificate metadata only. Neither command requests key material.
    certificates = run(['/usr/bin/security', 'find-certificate', '-a', '-c', 'Apple Development', '-p', str(path)])
    blocks = re.findall(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S)
    require(len(blocks) <= 64, 'The local signing certificate inventory needs review.')
    for certificate in blocks:
        metadata = run(['/usr/bin/openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253',
                        '-fingerprint', '-sha1'], data=certificate).decode('utf-8', 'strict')
        subject = next((line.removeprefix('subject=') for line in metadata.splitlines() if line.startswith('subject=')), '')
        fingerprint = next((line.split('=', 1)[1].replace(':', '') for line in metadata.splitlines()
                            if 'Fingerprint=' in line), '')
        if re.search(r'(?:^|,)OU=' + re.escape(team) + r'(?:,|$)', subject) and fingerprint.upper() in {v.upper() for v in valid}:
            return fingerprint.upper()
    raise BuildFailure('No local Apple Development certificate matches the installed app. Check signing in Xcode.')


def validate_toolchain():
    output = run(['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild', '-version']).decode('utf-8', 'strict')
    match = re.search(r'^Xcode ([0-9]+)\.([0-9]+)(?:\.[0-9]+)?$', output, re.M)
    require(match is not None and tuple(map(int, match.groups())) >= (16, 3),
            'Full Xcode 16.3 or newer is required to build updates.')


def native_inventory(app):
    require(app.is_dir() and not app.is_symlink() and app.name == 'OpenBots Next.app', 'Invalid candidate application.')
    files, containers = [], [app]
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            require(path.resolve().is_relative_to(app.resolve()), 'A build output link escapes the candidate.')
            continue
        info = path.lstat()
        require(info.st_uid == os.getuid(), 'Build output has unexpected ownership.')
        if stat.S_ISDIR(info.st_mode):
            if path.suffix in {'.framework', '.app', '.xpc'}:
                containers.append(path)
        elif stat.S_ISREG(info.st_mode):
            require(info.st_nlink == 1, 'Build output contains an unexpected hard link.')
            with path.open('rb') as handle:
                if handle.read(4) in MACHO:
                    files.append(path)
        else:
            raise BuildFailure('Build output contains an unsupported entry.')
    require(files and len(files) <= 128, 'The native build inventory is invalid.')
    require(app / 'Contents/MacOS/OpenBots Next' in files, 'The application executable is missing.')
    return files, sorted(containers, key=lambda item: len(item.parts), reverse=True)


def validate_plist(app, args):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE_ID and info.get('CFBundleExecutable') == 'OpenBots Next',
            'The candidate is not this application.')
    require(info.get('CFBundleVersion') == args.build and info.get('CFBundleShortVersionString') == args.version
            and info.get('OpenBotsSourceCommit') == args.commit, 'The candidate does not match the reviewed source release.')
    require(info.get('OpenBotsGoogleOAuthClientID', '') == args.google_client_id,
            'The candidate did not preserve local Google configuration.')
    require(type(info.get('OpenBotsGoogleConfigurationVersion')) is int and info['OpenBotsGoogleConfigurationVersion'] == 1,
            'The candidate cannot preserve saved Google configuration.')


def sign(args):
    validate_arguments(args)
    require(re.fullmatch(r'[A-Fa-f0-9]{40}', args.identity or '') is not None, 'Invalid signing identity reference.')
    require(choose_identity(args.team, args.keychain) == args.identity.upper(), 'The local signing identity changed.')
    app = Path(args.app)
    validate_plist(app, args)
    binaries, containers = native_inventory(app)
    for path in binaries + containers:
        run(['/usr/bin/codesign', '--force', '--sign', args.identity, '--keychain', args.keychain,
             '--options', 'runtime', '--timestamp=none', '--preserve-metadata=identifier,entitlements', str(path)])
    after, _ = native_inventory(app)
    require(after == binaries, 'The native build inventory changed while signing.')
    for path in after:
        run(['/usr/bin/codesign', '--verify', '--strict', str(path)])
        metadata = run(['/usr/bin/codesign', '--display', '--verbose=4', str(path)]).decode('utf-8', 'strict')
        require('TeamIdentifier=' + args.team + '\n' in metadata and '(runtime)' in metadata,
                'The candidate does not preserve the installed signing team and hardened runtime.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    validate_plist(app, args)


def prepare_directories(source):
    root = Path(source).resolve(strict=True)
    require((root / 'project.yml').is_file() and (root / 'Package.swift').is_file(), 'Invalid source layout.')
    for relative in ('.build.noindex', '.build.noindex/source-update', '.build.noindex/source-update/build-home',
                     '.build.noindex/source-update/tmp', '.build.noindex/source-update/ModuleCache'):
        path = root / relative
        if not path.exists():
            path.mkdir(mode=0o700)
        require(not path.is_symlink() and path.is_dir() and path.stat().st_uid == os.getuid(),
                'The source build directory is not private and owned.')
        path.chmod(0o700)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for command in ('arguments', 'sign'):
        item = subs.add_parser(command)
        for name in ('commit', 'build', 'version', 'team', 'google-client-id'):
            item.add_argument('--' + name, required=True)
        if command == 'sign':
            for name in ('app', 'identity', 'keychain'):
                item.add_argument('--' + name, required=True)
    item = subs.add_parser('choose')
    item.add_argument('--team', required=True); item.add_argument('--keychain', required=True)
    item = subs.add_parser('prepare-directories'); item.add_argument('--source', required=True)
    subs.add_parser('toolchain')
    args = parser.parse_args()
    try:
        if args.command == 'arguments': validate_arguments(args)
        elif args.command == 'choose': print(choose_identity(args.team, args.keychain))
        elif args.command == 'prepare-directories': prepare_directories(args.source)
        elif args.command == 'toolchain': validate_toolchain()
        else: sign(args)
    except (BuildFailure, OSError, ValueError, UnicodeError, plistlib.InvalidFileException) as error:
        message = str(error) if isinstance(error, BuildFailure) else 'Local source-build preparation failed.'
        print(message, file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
