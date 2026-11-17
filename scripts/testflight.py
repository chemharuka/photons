#!/usr/bin/env python3
"""Prepare a local beta, then sign/package/validate/upload after Apple enrollment.

Credentials stay in Keychain or Apple's private-key directory, never in this repo.
See docs/testflight.md. No command enrolls an account or invites testers.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / '.build/testflight'
APP = OUT / 'Photons Studio.app'
PKG = OUT / 'Photons-Studio.pkg'
HELPERS = ('ansel-denoise-swift', 'hdrmerge-swift', 'photons-panorama-worker')


def run(*args, capture=False, env=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE if capture else None, env=env)
    return result.stdout if capture else None


def read_plist(path):
    return plistlib.loads(Path(path).read_bytes())


def write_plist(path, value):
    Path(path).write_bytes(plistlib.dumps(value, sort_keys=True))


def setting(name):
    return os.environ.get('PHOTONS_' + name, '')


def signing_inputs(bundle_id):
    """Reject wrong-team, development, expired, wildcard, and mismatched profiles."""
    failures = []
    identity, installer = setting('APP_SIGN_IDENTITY'), setting('INSTALLER_SIGN_IDENTITY')
    profile_path = Path(setting('PROVISIONING_PROFILE')).expanduser()
    for value, policy, label, prefixes in (
        (identity, 'codesigning', 'PHOTONS_APP_SIGN_IDENTITY',
         ('Apple Distribution:', '3rd Party Mac Developer Application:')),
        (installer, 'basic', 'PHOTONS_INSTALLER_SIGN_IDENTITY',
         ('3rd Party Mac Developer Installer:',))):
        available = run('security', 'find-identity', '-v', '-p', policy, capture=True).decode()
        if not value or not value.startswith(prefixes) or ('"' + value + '"') not in available:
            failures.append(label + ': install a valid Mac App Store identity with its private key')
    profile = None
    if not setting('PROVISIONING_PROFILE') or not profile_path.is_file():
        failures.append('PHOTONS_PROVISIONING_PROFILE: select a Mac App Store Connect .provisionprofile')
    else:
        profile = plistlib.loads(run('security', 'cms', '-D', '-i', profile_path, capture=True))
        ent = profile.get('Entitlements', {})
        team = (profile.get('TeamIdentifier') or [''])[0]
        app_id = ent.get('com.apple.application-identifier', '')
        prefixes = profile.get('ApplicationIdentifierPrefix', [])
        if not prefixes or app_id != prefixes[0] + '.' + bundle_id:
            failures.append('Profile application identifier must exactly match ' + bundle_id)
        if not team or ent.get('com.apple.developer.team-identifier') != team:
            failures.append('Profile team identifier is missing or inconsistent')
        if any(value and '(' + team + ')' not in value for value in (identity, installer)):
            failures.append('Application and installer certificates must belong to the profile team')
        if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.utcnow():
            failures.append('Provisioning profile is expired')
        if 'OSX' not in profile.get('Platform', []):
            failures.append('Provisioning profile is not for macOS')
        if (profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
                or ent.get('com.apple.security.get-task-allow') or ent.get('get-task-allow')):
            failures.append('Use App Store distribution, not development or Developer ID provisioning')
        allowed_certs = {hashlib.sha1(c).hexdigest().upper() for c in profile.get('DeveloperCertificates', [])}
        available = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True).decode()
        matches = [line for line in available.splitlines() if '"' + identity + '"' in line]
        if not identity or not any(any(digest in line for digest in allowed_certs) for line in matches):
            failures.append('Application signing certificate is not included in the profile')
    if failures:
        raise ValueError('\n'.join(failures))
    return identity, installer, profile_path, profile


def sign_bundle(identity, entitlements, *, app_store_resigning=False):
    resources = APP / 'Contents/Resources'
    for name in HELPERS:
        executable = resources / 'bin' / name
        run('codesign', '--force', '--sign', identity, '--timestamp=none',
            '--entitlements', ROOT / 'scripts/Photons-Helper.entitlements', executable)
        checksum = executable.with_name(name + '.sha256')
        if app_store_resigning:
            # Xcode and Apple re-sign Mach-O files. A whole-file checksum would become stale;
            # the platform code signature verifies delivered code instead. Model hashes stay.
            checksum.unlink(missing_ok=True)
        else:
            digest = hashlib.sha256(executable.read_bytes()).hexdigest()
            checksum.write_text(digest + '  ' + name + '\n')
    # Signing changes binary hashes; regenerate the corresponding-source records afterward.
    run('python3', ROOT / 'scripts/bundle-gpl-sources.py', APP,
        *(['--app-store-resigning'] if app_store_resigning else []))
    for bundle in resources.glob('*.bundle'):
        run('codesign', '--force', '--sign', identity, '--timestamp=none', bundle)
    run('codesign', '--force', '--sign', identity, '--timestamp=none', '--entitlements', entitlements, APP)
    run('codesign', '--verify', '--deep', '--strict', APP)


def prepare(args):
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', args.bundle_id):
        raise ValueError('Use an explicit reverse-DNS bundle identifier')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        raise ValueError('Version must contain three numeric components, for example 0.3.0')
    if not re.fullmatch(r'[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}', args.build):
        raise ValueError('Build must follow CFBundleVersion limits, for example 4 or 4.1')
    OUT.mkdir(parents=True, exist_ok=True)
    # A newly prepared app must never reuse a signed package from an older build.
    PKG.unlink(missing_ok=True)
    if not args.skip_build:
        for package in (ROOT, ROOT / 'Vendor/hdrmerge-swift', ROOT / 'Vendor/ansel-denoise-swift'):
            run('swift', 'build', '--package-path', package, '-c', 'release')
    run(ROOT / 'scripts/bundle-app.sh', 'release', env=dict(os.environ, PHOTONS_APP=str(APP)))
    resources = APP / 'Contents/Resources'
    for name in HELPERS:
        if not (resources / 'bin' / name).is_file():
            raise ValueError('Missing bundled helper: ' + name)
    if not (resources / 'bin/models/denoise-quarter-single-v1.anselnn').is_file():
        raise ValueError('Missing denoise model; supply PHOTONS_ANSEL_MODEL before preparing')
    info_path = APP / 'Contents/Info.plist'
    info = read_plist(info_path)
    info.update(CFBundleIdentifier=args.bundle_id, CFBundleName='Photons Studio',
                CFBundleDisplayName='Photons Studio', CFBundleShortVersionString=args.version,
                CFBundleVersion=args.build, LSArchitecturePriority=['arm64'],
                LSMinimumSystemVersion='14.0', CFBundleLocalizations=['en', 'zh-Hans'],
                CFBundleSupportedPlatforms=['MacOSX'])
    # Current build uses hashing for local cache/source integrity, not non-exempt encryption.
    info['ITSAppUsesNonExemptEncryption'] = False
    info['NSHumanReadableCopyright'] = 'Photons contributors. See bundled licenses and third-party notices.'
    sdk = run('xcrun', '--sdk', 'macosx', '--show-sdk-version', capture=True).decode().strip()
    sdk_build = run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version', capture=True).decode().strip()
    xcode = run('xcodebuild', '-version', capture=True).decode().splitlines()
    numbers = xcode[0].split()[-1].split('.')
    info.update(CFBundleDevelopmentRegion='en', DTPlatformName='macosx', DTPlatformVersion=sdk, DTPlatformBuild=sdk_build,
                DTSDKName='macosx' + sdk, DTSDKBuild=sdk_build,
                DTXcode=numbers[0] + (numbers[1] if len(numbers) > 1 else '0')
                    + (numbers[2] if len(numbers) > 2 else '0'),
                DTXcodeBuild=xcode[1].split()[-1], DTCompiler='com.apple.compilers.llvm.clang.1_0',
                BuildMachineOSBuild=run('sw_vers', '-buildVersion', capture=True).decode().strip())
    write_plist(info_path, info)
    shutil.copy2(ROOT / 'scripts/PrivacyInfo.xcprivacy', resources)
    sign_bundle('-', ROOT / 'scripts/Photons-Sandbox.entitlements')
    # PHOTONS_ANSEL_MODEL selects the input copied by the bundler. The sandbox check must
    # exercise that bundled copy, not try to open the build machine's ungranted source path.
    diagnostic_env = dict(os.environ)
    diagnostic_env.pop('PHOTONS_ANSEL_MODEL', None)
    report = json.loads(run(APP / 'Contents/MacOS/Photons', '--sandbox-check', capture=True, env=diagnostic_env))
    if report.get('sandbox') is not True or report.get('panorama', {}).get('workerSucceeded') is not True:
        raise ValueError('Sandbox diagnostics did not pass')
    (OUT / 'sandbox-check.json').write_text(json.dumps(report, indent=2) + '\n')
    symbols = OUT / 'dSYMs'
    symbols.mkdir(exist_ok=True)
    for binary in [APP / 'Contents/MacOS/Photons'] + [resources / 'bin' / name for name in HELPERS]:
        destination = symbols / (binary.name + '.dSYM')
        if destination.exists():
            shutil.rmtree(destination)
        run('dsymutil', binary, '-o', destination)
    print('Prepared local sandbox beta:', APP)
    print('AD-HOC SIGNED ONLY. Run package with Apple distribution credentials before uploading.')


def package():
    if not APP.is_dir():
        raise ValueError('Run prepare first')
    info = read_plist(APP / 'Contents/Info.plist')
    identity, installer, profile_path, profile = signing_inputs(info['CFBundleIdentifier'])
    PKG.unlink(missing_ok=True)
    ent = read_plist(ROOT / 'scripts/Photons-Sandbox.entitlements')
    authorized = profile['Entitlements']
    for key in ('com.apple.application-identifier', 'com.apple.developer.team-identifier', 'beta-reports-active'):
        if key in authorized:
            ent[key] = authorized[key]
    for key, value in ent.items():
        if key in authorized and authorized[key] != value:
            raise ValueError('Profile disallows entitlement: ' + key)
    ent_path = OUT / 'AppStore.entitlements'
    write_plist(ent_path, ent)
    shutil.copy2(profile_path, APP / 'Contents/embedded.provisionprofile')
    sign_bundle(identity, ent_path, app_store_resigning=True)
    run('productbuild', '--component', APP, '/Applications', '--sign', installer, PKG)
    run('pkgutil', '--check-signature', PKG)
    print('Signed distribution package:', PKG)


def transport(action):
    if not PKG.is_file():
        raise ValueError('Run package with distribution credentials first; no signed .pkg exists')
    if setting('ASC_KEY_ID') and setting('ASC_ISSUER_ID'):
        auth = ['--api-key', setting('ASC_KEY_ID'), '--api-issuer', setting('ASC_ISSUER_ID')]
    elif setting('APPLE_ID') and setting('PASSWORD_KEYCHAIN_ITEM'):
        auth = ['-u', setting('APPLE_ID'), '-p', '@keychain:' + setting('PASSWORD_KEYCHAIN_ITEM')]
    else:
        raise ValueError('Set PHOTONS_ASC_KEY_ID + PHOTONS_ASC_ISSUER_ID, or PHOTONS_APPLE_ID + '
                         'PHOTONS_PASSWORD_KEYCHAIN_ITEM; alternatively open the .pkg in Transporter')
    # This toolchain supports the current altool validation syntax (Xcode 27.2).
    run('xcrun', 'altool', '--validate-app', PKG, *auth)
    if action == 'upload':
        run('xcrun', 'altool', '--upload-package', PKG, '--wait', *auth)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preflight', 'prepare', 'package', 'validate', 'upload'))
    parser.add_argument('--bundle-id', default=setting('BUNDLE_ID') or 'com.leoaokma.photons')
    parser.add_argument('--version', default=setting('VERSION') or '0.3.0')
    parser.add_argument('--build', default=setting('BUILD_NUMBER') or '5')
    parser.add_argument('--skip-build', action='store_true', help='Use already built release executables')
    args = parser.parse_args()
    try:
        if args.action == 'prepare':
            prepare(args)
        elif args.action == 'preflight':
            run('xcodebuild', '-version')
            signing_inputs(args.bundle_id)
            print('Local signing inputs match. App Store Connect enrollment/app record must also be ready.')
        elif args.action == 'package':
            package()
        else:
            transport(args.action)
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print('testflight: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
