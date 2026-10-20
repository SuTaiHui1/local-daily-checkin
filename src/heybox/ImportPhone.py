"""Import an authorized USB phone session via the official exported provider.

Default is a synthetic parser self-check. --read is deliberately explicit.
No root, private-file access, network client, retries, or raw provider output.
"""
from datetime import datetime
from pathlib import Path
import argparse
import json
import re
import subprocess

from Paths import STATE_ROOT as ROOT, PRIVATE
import os
ADB = Path(os.environ.get('HEYBOX_ADB', 'adb.exe'))
COLUMNS = ('heybox_id', 'pkey', 'device_id', 'x_xhh_tokenid')


def parse_row(raw):
    text = raw.decode('utf-8', 'strict').strip()
    if len(text) > 32768:
        raise ValueError('Unexpected provider result size')
    pattern = (r'Row: 0 heybox_id=(.*?), pkey=(.*?), '
               r'device_id=(.*?), x_xhh_tokenid=(.*)')
    match = re.fullmatch(pattern, text)
    if not match:
        raise ValueError('Provider did not return the expected single login row')
    values = dict(zip(COLUMNS, match.groups()))
    if not values['heybox_id'].isdigit() or any(
        not v or v.lower() == 'null' or '\n' in v or '\r' in v
        for v in values.values()
    ):
        raise ValueError('Official provider session is incomplete')
    return values


def run(*args):
    result = subprocess.run([str(ADB), '-P', '5039', *args],
                            capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError('Local ADB operation failed; no raw output retained')
    return result.stdout


def protect_folder():
    PRIVATE.mkdir(parents=True,exist_ok=True)
    sid_query = subprocess.run(
        ['whoami.exe', '/user', '/fo', 'csv', '/nh'],
        capture_output=True, check=True, timeout=10)
    sid = re.search(rb'S-1-5-[0-9-]+', sid_query.stdout)
    if not sid:
        raise ValueError('Current user SID unavailable')
    result = subprocess.run(
        ['icacls.exe', str(PRIVATE), '/inheritance:r', '/grant:r',
         '*' + sid.group().decode() + ':(OI)(CI)F',
         '*S-1-5-18:(OI)(CI)F'], capture_output=True, timeout=10)
    if result.returncode:
        raise ValueError('Private directory ACL setup failed')


def import_phone():
    # ADB -d selects USB only and fails if multiple USB targets are attached.
    # It cannot silently select an emulator or a TCP-connected device.
    if run('-d', 'get-state').strip() != b'device':
        raise ValueError('Exactly one authorized USB phone is required')
    version_raw = run('-d', 'shell', 'dumpsys', 'package',
                      'com.max.xiaoheihe')
    version = re.search(rb'\bversionName=([0-9.]+)', version_raw)
    build = re.search(rb'\bversionCode=([0-9]+)', version_raw)
    if not version or not build:
        raise ValueError('Official phone App version could not be confirmed')
    metadata = json.loads((PRIVATE/'resource-manifest.json').read_text(encoding='utf-8'))
    if version.group(1).decode()!=metadata['AppVersion'] or build.group(1).decode()!=metadata['Build']:
        raise ValueError('Phone App does not match qualified resources')
    # Capture in memory. This output contains credentials and must never print.
    values = parse_row(run('-d', 'shell', 'content', 'query', '--uri',
                           'content://com.max.xiaoheihe.statusprovider/login'))
    snapshot = {
        'ObservedAt': datetime.now().astimezone().isoformat(),
        'Source': 'OfficialExportedHeyboxProviderViaAuthorizedUsbAdb',
        'AppVersion': version.group(1).decode(), 'Build': build.group(1).decode(),
        'HeyboxId': values['heybox_id'], 'Pkey': values['pkey'],
        'DeviceId': values['device_id'],
        'SdkDeviceToken': values['x_xhh_tokenid'],
        # Official HeyBoxApplication initialization, not guessed device data.
        'DebugInfo': values['device_id'] + values['heybox_id'],
        'Model': run('-d', 'shell', 'getprop',
                     'ro.product.model').decode('utf-8').strip(),
        'OsVersion': run('-d', 'shell', 'getprop',
                         'ro.build.version.release').decode().strip(),
    }
    protect_folder()
    target = PRIVATE / 'phone-session.json'
    if target.exists():
        raise ValueError('Existing phone session preserved; import not overwritten')
    target.write_text(json.dumps(snapshot, ensure_ascii=False), encoding='utf-8')
    safe = {
        'ObservedAt': snapshot['ObservedAt'], 'Imported': True,
        'AppVersion': snapshot['AppVersion'],
        'SdkDeviceTokenPresent': True, 'DebugInfoFromOfficialFormula': True,
        'RootUsed': False, 'PrivateFilesRead': False,
        'BusinessRequestSentByThisScript': False,
    }
    (ROOT / 'logs/phone-provider-import.json').write_text(
        json.dumps(safe, indent=2), encoding='utf-8')
    return safe


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--read', action='store_true')
    parser.add_argument('--state-root')
    args = parser.parse_args()
    if not args.read:
        sample = (b'Row: 0 heybox_id=123, pkey=synthetic==, '
                  b'device_id=synthetic-device, x_xhh_tokenid=synthetic-token')
        assert parse_row(sample)['pkey'] == 'synthetic=='
        for invalid in (b'No result found.', b'Row: 0 heybox_id=0',
                        sample.replace(b'synthetic-token', b'null')):
            try:
                parse_row(invalid)
            except ValueError:
                pass
            else:
                raise AssertionError('Invalid row accepted')
        print(json.dumps({'SyntheticParserCheck': 'Passed', 'AdbStarted': False,
                          'PhoneRead': False, 'NetworkRequested': False}))
    else:
        try:
            print(json.dumps(import_phone()))
        except Exception:
            # Do not let subprocess errors echo a sensitive argument/response.
            raise SystemExit('Phone import stopped; no credentials printed. Check USB authorization, App login, and local ACL prerequisites; no automatic retry.')
