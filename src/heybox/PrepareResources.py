"""Offline import of personally obtained resources. No App API is called.

This intentionally cannot fabricate the server-issued ShaderManager payload.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

from Paths import PRIVATE

LIBRARIES = {
    'libglesv3_1.so': '5ff6850b0b682418bf62be178acb481119be042a7297c1f3bdf47666dca86344',
    'libnative-lib.so': '5d8699f237ab12582f3d9b22c23c3edb91f9f65bca3ac1211c36e25fdb069489',
}
SUPPLIED = ('shader-code.bin', 'report-material.properties', 'report-public-key.der')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--state-root')
    args = parser.parse_args()
    # Import only files explicitly named here; never recursively copy a deployment.
    if PRIVATE.joinpath('resource-manifest.json').exists():
        raise ValueError('Existing deployment preserved; choose a new empty state directory')
    provenance = json.loads((args.resources/'provenance.json').read_text(encoding='utf-8-sig'))
    if provenance.get('ShaderVersion') != 14 or not provenance.get('ResourceOrigin'):
        raise ValueError('Version 14 resources with personally verified origin required')
    for filename in SUPPLIED:
        file = args.resources / filename
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError('Required personally obtained signing resource missing')
    # Silence third-party parser diagnostics; they may contain APK internals.
    from loguru import logger
    logger.disable('androguard')
    from androguard.core.apk import APK
    apk = APK(str(args.apk))
    if (apk.get_package() != 'com.max.xiaoheihe' or apk.get_androidversion_name() != '1.3.397'
            or apk.get_androidversion_code() != '1138'):
        raise ValueError('Only App 1.3.397 build 1138 has been qualified; no automatic upgrade')
    files = {}
    with zipfile.ZipFile(args.apk) as archive:
        for filename, expected in LIBRARIES.items():
            content = archive.read('lib/arm64-v8a/' + filename)
            if sha(content) != expected:
                raise ValueError('Native library differs from the qualified official App')
            files[filename] = content
    for filename in SUPPLIED:
        files[filename] = (args.resources / filename).read_bytes()
    files['app-metadata.apk'] = args.apk.read_bytes()
    # Metadata and hashes are private; no resource or original provenance text is printed.
    PRIVATE.mkdir(parents=True, exist_ok=True)
    for filename, content in files.items():
        (PRIVATE/filename).write_bytes(content)
    metadata = {'AppVersion': '1.3.397', 'Build': '1138', 'Channel': 'heybox',
                'ShaderVersion': 14, 'Files': {name: sha(data) for name, data in files.items()}}
    (PRIVATE/'resource-manifest.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    print('{"ResourcesImported":true,"NetworkRequests":0}')

if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Offline resource import stopped; APK and compatible private resources are required. No diagnostic values printed.')
