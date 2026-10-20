"""Minimal local client using the real, authorized phone session. No retries."""
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess

import requests

from Paths import CODE_ROOT, STATE_ROOT, PRIVATE, java_executable
ROOT = STATE_ROOT
JAVA = java_executable()
STATE_PATH = '/task/sign_v3/get_sign_state'
UA = ('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/41.0.2272.118 Safari/537.36 ApiMaxJia/1.0')


def phone_data():
    data = json.loads((PRIVATE / 'phone-session.json').read_text(encoding='utf-8'))
    fields = ('HeyboxId', 'Pkey', 'DeviceId', 'SdkDeviceToken', 'DebugInfo',
              'Model', 'OsVersion', 'AppVersion')
    if not all(isinstance(data.get(k), str) and data[k] for k in fields):
        raise ValueError('Required official phone fields missing')
    if data['DebugInfo'] != data['DeviceId'] + data['HeyboxId']:
        raise ValueError('Official initialization formula mismatch')
    metadata = json.loads((PRIVATE / 'resource-manifest.json').read_text(encoding='utf-8'))
    if (metadata.get('AppVersion') != data['AppVersion'] or metadata.get('Build') != data.get('Build')
            or metadata.get('AppVersion') != '1.3.397' or metadata.get('Build') != '1138'
            or metadata.get('ShaderVersion') != 14 or metadata.get('Channel') != 'heybox'):
        raise ValueError('App resources are outside the qualified compatibility set')
    for filename, expected in metadata.get('Files', {}).items():
        if filename not in ('app-metadata.apk', 'libglesv3_1.so', 'libnative-lib.so',
                            'shader-code.bin', 'report-material.properties', 'report-public-key.der'):
            raise ValueError('Unexpected resource manifest entry')
        import hashlib
        if hashlib.sha256((PRIVATE / filename).read_bytes()).hexdigest() != expected:
            raise ValueError('Local resource integrity mismatch')
    if len(metadata.get('Files', {})) != 6:
        raise ValueError('Complete private resource manifest required')
    return data


def signed_params(data, path):
    config = {'path': '/' + path.strip('/') + '/', 'account': data['HeyboxId'],
              'model': data['Model'], 'os_version': data['OsVersion'],
              'version': data['AppVersion'], 'debug_info': data['DebugInfo']}
    cp = ';'.join((str(PRIVATE / 'build'), str(PRIVATE / 'lib/*')))
    process = subprocess.run(
        [str(JAVA), '-Djava.io.tmpdir=' + str(PRIVATE / 'java-tmp'),
         '-Dorg.slf4j.simpleLogger.defaultLogLevel=error', '-cp', cp,
         'PhoneNativeRunner', str(PRIVATE)],
        input=json.dumps(config).encode(), capture_output=True, timeout=45)
    if process.returncode:
        raise ValueError('Local native computation failed; child output withheld')
    signed = json.loads(process.stdout)
    if (set(signed) != {'_time', 'nonce', 'hkey', '_rnd'}
            or not re.fullmatch(r'[A-Za-z0-9]{32}', signed['nonce'])
            or not re.fullmatch(r'[0-9A-F]{1,8}', signed['hkey'])
            or not re.fullmatch(r'14:[0-9A-F]{1,8}', signed['_rnd'])):
        raise ValueError('Local signature format unconfirmed')
    return {'heybox_id': data['HeyboxId'], 'imei': data['DeviceId'],
            'device_info': data['Model'], 'os_type': 'Android',
            'x_os_type': 'Android', 'x_client_type': 'mobile',
            'os_version': data['OsVersion'], 'version': data['AppVersion'],
            'build': data['Build'], 'channel': 'heybox', 'x_app': 'heybox',
            'time_zone': 'Asia/Shanghai', **signed}


def safe_message(value, data, params):
    if not isinstance(value, str):
        return None
    secrets = [data[k] for k in ('HeyboxId', 'Pkey', 'DeviceId',
                                'SdkDeviceToken', 'DebugInfo')]
    secrets += [str(params[k]) for k in ('_time', 'nonce', 'hkey', '_rnd')]
    for secret in sorted(secrets, key=len, reverse=True):
        value = value.replace(secret, '[private]')
    value = re.sub(r'https?://\S+', '[url]', value)
    if re.search(r'cookie|pkey|token|nonce|hkey|_rnd|imei|headers|params|request|response', value, re.I):
        return 'Sensitive diagnostic withheld'
    return value[:200]


def get_once(data, path, params):
    with requests.Session() as session:
        session.headers.update({'User-Agent': UA, 'Accept': 'application/json',
                                'Referer': 'http://api.maxjia.com/'})
        session.cookies.update({'pkey': data['Pkey'],
                                'x_xhh_tokenid': data['SdkDeviceToken']})
        response = session.get('https://api.xiaoheihe.cn' + path, params=params,
                               timeout=20, allow_redirects=False)
        return response.status_code, response.json()


def post_report_once(data, params, form):
    with requests.Session() as session:
        session.headers.update({'User-Agent': UA, 'Accept': 'application/json',
                                'Referer': 'http://api.maxjia.com/'})
        session.cookies.update({'pkey': data['Pkey'],
                                'x_xhh_tokenid': data['SdkDeviceToken']})
        response = session.post('https://data.xiaoheihe.cn/account/data_report/',
                                params=params, data=form, timeout=20,
                                allow_redirects=False)
        return response.status_code, response.json()


def now():
    return datetime.now().astimezone().isoformat()
