"""Exercise distribution gates without Apple credentials or network access."""
import datetime
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('testflight', Path(__file__).resolve().parents[1] / 'testflight.py')
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


class DistributionSigningTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.profile_path = Path(self.folder.name) / 'AppStore.provisionprofile'
        self.profile_path.touch()
        self.certificate = b'synthetic certificate for matching only'
        self.application = 'Apple Distribution: Example (TEAM123456)'
        self.installer = '3rd Party Mac Developer Installer: Example (TEAM123456)'
        self.profile = {
            'TeamIdentifier': ['TEAM123456'], 'ApplicationIdentifierPrefix': ['PREFIX1234'],
            'Platform': ['OSX'], 'ExpirationDate': datetime.datetime.utcnow() + datetime.timedelta(days=30),
            'DeveloperCertificates': [self.certificate],
            'Entitlements': {'com.apple.application-identifier': 'PREFIX1234.com.leoaokma.photons',
                             'com.apple.developer.team-identifier': 'TEAM123456'},
        }
        self.values = {'APP_SIGN_IDENTITY': self.application, 'INSTALLER_SIGN_IDENTITY': self.installer,
                       'PROVISIONING_PROFILE': str(self.profile_path)}
        self.addCleanup(patch.stopall)
        patch.object(distribution, 'setting', side_effect=lambda key: self.values.get(key, '')).start()
        patch.object(distribution, 'run', side_effect=self.command).start()

    def command(self, *args, **kwargs):
        if args[:2] == ('security', 'cms'):
            return plistlib.dumps(self.profile)
        self.assertEqual(args[:2], ('security', 'find-identity'))
        digest = hashlib.sha1(self.certificate).hexdigest().upper()
        return ('1) ' + digest + ' "' + self.application + '"\n2) ' + digest + ' "'
                + self.installer + '"\n').encode()

    def check(self):
        return distribution.signing_inputs('com.leoaokma.photons')

    def test_app_id_prefix_may_differ_from_team(self):
        self.assertEqual(self.check()[3]['ApplicationIdentifierPrefix'], ['PREFIX1234'])

    def test_missing_credentials_are_reported_together(self):
        self.values.clear()
        with self.assertRaises(ValueError) as error:
            self.check()
        for key in ('APP_SIGN_IDENTITY', 'INSTALLER_SIGN_IDENTITY', 'PROVISIONING_PROFILE'):
            self.assertIn(key, str(error.exception))

    def test_developer_id_certificate_is_not_app_store_distribution(self):
        self.values['APP_SIGN_IDENTITY'] = 'Developer ID Application: Example (TEAM123456)'
        with self.assertRaisesRegex(ValueError, 'APP_SIGN_IDENTITY'):
            self.check()

    def test_development_profile_is_rejected(self):
        self.profile['ProvisionedDevices'] = ['device-id']
        with self.assertRaisesRegex(ValueError, 'not development'):
            self.check()

    def test_expired_profile_is_rejected(self):
        self.profile['ExpirationDate'] = datetime.datetime.utcnow() - datetime.timedelta(seconds=1)
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.check()

    def test_wildcard_profile_is_rejected(self):
        self.profile['Entitlements']['com.apple.application-identifier'] = 'PREFIX1234.*'
        with self.assertRaisesRegex(ValueError, 'exactly match'):
            self.check()

    def test_wrong_team_is_rejected(self):
        self.profile['TeamIdentifier'] = ['OTHERTEAM1']
        self.profile['Entitlements']['com.apple.developer.team-identifier'] = 'OTHERTEAM1'
        with self.assertRaisesRegex(ValueError, 'belong to the profile team'):
            self.check()

    def test_certificate_must_be_in_profile(self):
        self.profile['DeveloperCertificates'] = [b'another certificate']
        with self.assertRaisesRegex(ValueError, 'not included in the profile'):
            self.check()

    def test_ios_profile_is_rejected(self):
        self.profile['Platform'] = ['iOS']
        with self.assertRaisesRegex(ValueError, 'not for macOS'):
            self.check()

    def test_upload_requires_distribution_package(self):
        with patch.object(distribution, 'PKG', Path(self.folder.name) / 'missing.pkg'):
            with self.assertRaisesRegex(ValueError, 'no signed .pkg exists'):
                distribution.transport('upload')


if __name__ == '__main__':
    unittest.main()
