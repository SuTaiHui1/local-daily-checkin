"""Offline publication boundary checks. Never imports the live task modules."""
from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_TOP = {
    '.github', '.gitignore', '.gitattributes', '.editorconfig',
    'README.md', 'README.en.md', 'LICENSE', 'NOTICE', 'NOTICE.md',
    'THIRD_PARTY_NOTICES.md', 'SECURITY.md', 'CONTRIBUTING.md',
    'CHANGELOG.md', 'AGENTS.md', 'CODE_OF_CONDUCT.md', 'pyproject.toml',
    'requirements.txt', 'requirements-dev.txt', 'config.example.json',
    'bilibili', 'heybox', 'src', 'scripts', 'tests', 'docs', 'examples',
    'licenses', 'config', 'templates', 'VERSION', 'publish-manifest.json',
}
PRIVATE_DIRS = {
    'private-phone', 'private-runtime', 'private', 'logs', 'state', 'data',
    'runtime', '.venv', 'venv', 'node_modules', 'downloads', 'android-sdk',
    'java-tmp', '.build', 'target', '__pycache__',
}
BINARY_SUFFIXES = {
    '.apk', '.so', '.jar', '.class', '.pyc', '.pyo', '.dll', '.exe',
    '.zip', '.7z', '.tar', '.gz', '.bin', '.db', '.sqlite', '.sqlite3',
    '.pfx', '.p12', '.pem', '.key', '.der', '.dmp', '.png', '.jpg', '.jpeg',
}
PRIVATE_NAMES = {
    'phone-session.json', 'cookies.json', 'cookies.txt', 'cookie.txt',
    'appsettings.json', 'shader-code.bin', 'NativeSigner.java',
    'daily-paused.txt', 'automation.toml',
}


def inspect_item(name: str, data: bytes) -> list[str]:
    """Return path/rule names only: matched credential material is never emitted."""
    path = Path(name.replace('\\', '/'))
    issues = []
    if path.parts and path.parts[0] not in ALLOWED_TOP:
        issues.append('top-level path is not allowed')
    if any(part.lower() in PRIVATE_DIRS for part in path.parts):
        issues.append('private/runtime directory')
    if path.name in PRIVATE_NAMES or (path.name.startswith('.env') and not path.name.endswith('.example')):
        issues.append('private or unlicensed source filename')
    if path.suffix.lower() in BINARY_SUFFIXES:
        issues.append('binary/resource/cache file')
    if b'\x00' in data:
        issues.append('binary content')
    try:
        content = data.decode('utf-8-sig')
    except UnicodeDecodeError:
        return issues + ['non UTF-8 content']
    # Concrete home folders, including escaped JSON/Python Windows paths.
    if re.search(r'[A-Za-z]:[\\/]+Users[\\/]+(?!<|YOUR_|USERNAME|\$|%)[A-Za-z0-9_.-]+', content, re.I):
        issues.append('personal absolute home path')
    if re.search(r'(?im)^\s*(?:Cookie|Authorization):\s*(?:Bearer\s+)?\S{16,}', content):
        issues.append('credential header literal')
    if re.search(r'(?i)(?:SESSDATA|bili_jct|DedeUserID|pkey|sdkdevicetoken|x_xhh_tokenid)[\"\x27]?\s*[=:]\s*[\"\x27]?[A-Za-z0-9%._~+/=-]{24,}', content):
        issues.append('credential value literal')
    if re.search(r'(?i)(?:HeyboxId|DeviceId|DebugInfo|IMEI)\s*[\"\x27]?\s*:\s*[\"\x27](?:\d{7,}|[0-9a-f]{24,})[\"\x27]', content):
        issues.append('account/device identifier literal')
    if re.search(r'(?m)^-----BEGIN (?:RSA )?PRIVATE KEY-----\s*$', content):
        issues.append('private key')
    if path.suffix == '.py':
        try:
            ast.parse(content, filename=name)
        except SyntaxError:
            issues.append('Python syntax')
    if path.suffix == '.json':
        try:
            json.loads(content)
        except ValueError:
            issues.append('JSON syntax')
    if '.github/workflows/' in name.replace('\\', '/'):
        # Workflow tests may download test tooling, but never execute account tasks.
        if re.search(r'(?i)(?:Launch|Run-Daily|Invoke-Daily|Install|Import-Phone|Prepare-Heybox)\.ps1|api\.(?:bilibili|xiaoheihe)\.', content):
            issues.append('live account/deployment action in CI')
        if re.search(r'(?im)^\s*schedule\s*:', content):
            issues.append('scheduled workflow')
    return issues


def scan(root: Path, history: bool = True) -> list[str]:
    issues = []
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if '.git' in rel.parts:
            continue
        # Interpreter caches are not publication files; Git checks below reject tracked ones.
        if '__pycache__' in rel.parts and not path.is_symlink():
            continue
        if path.is_symlink():
            issues.append(f'{rel.as_posix()}: symbolic link is not publishable')
        elif path.is_file():
            issues.extend(f'{rel.as_posix()}: {rule}' for rule in inspect_item(rel.as_posix(), path.read_bytes()))
    if history and (root / '.git').exists():
        def git(*args):
            return subprocess.run(['git', '-C', str(root), *args], capture_output=True, check=False)
        tracked = git('ls-files', '-z')
        if tracked.returncode:
            issues.append('git: cannot inspect tracked files')
        else:
            for name in tracked.stdout.decode('utf-8').split('\0'):
                if name:
                    staged = git('show', ':' + name)
                    if staged.returncode:
                        issues.append(f'git index {name}: unreadable object')
                    else:
                        issues.extend(f'git index {name}: {rule}' for rule in inspect_item(name, staged.stdout))
        commits = git('rev-list', '--all')
        if commits.returncode == 0:
            seen = set()
            for commit in commits.stdout.decode('ascii').splitlines():
                tree = git('ls-tree', '-r', '-z', commit)
                if tree.returncode:
                    issues.append('git: cannot inspect committed tree')
                    continue
                for entry in tree.stdout.split(b'\0'):
                    if not entry:
                        continue
                    meta, raw_name = entry.split(b'\t', 1)
                    mode, kind, oid = meta.split()
                    name = raw_name.decode('utf-8')
                    if (oid, name) in seen:
                        continue
                    seen.add((oid, name))
                    if mode == b'120000' or kind != b'blob':
                        issues.append(f'git history {name}: non-regular file')
                        continue
                    blob = git('cat-file', 'blob', oid.decode('ascii'))
                    if blob.returncode:
                        issues.append(f'git history {name}: unreadable object')
                    else:
                        issues.extend(f'git history {name}: {rule}' for rule in inspect_item(name, blob.stdout))
    return sorted(set(issues))


class ScannerFixtures(unittest.TestCase):
    def test_synthetic_secrets_and_private_resources_rejected(self):
        cases = [
            ('heybox/NativeSigner.java', b'// not licensed for redistribution'),
            ('private-phone/session.json', b'{}'),
            ('heybox/resources/lib.so', b'\x00FAKE'),
            ('config/live.json', ('{"pkey":"' + 'synthetic' * 8 + '"}').encode()),
            ('docs/path.md', b'C:' + b'\\Users\\' + b'EXAMPLE_PERSON\\private'),
        ]
        for name, content in cases:
            with self.subTest(name=name):
                self.assertTrue(inspect_item(name, content))

    def test_synthetic_examples_and_syntax(self):
        self.assertEqual(inspect_item('config.example.json', b'{"Pkey":"<provided-locally>"}'), [])
        self.assertEqual(inspect_item('docs/setup.md', b'%LOCALAPPDATA%/LocalDailyCheckin'), [])
        self.assertIn('Python syntax', inspect_item('src/bad.py', b'def ('))
        self.assertIn('JSON syntax', inspect_item('config/bad.json', b'{'))

    def test_tree_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'unexpected.txt').write_text('fixture', encoding='utf-8')
            self.assertTrue(any('top-level' in issue for issue in scan(root, history=False)))

    def test_deleted_private_data_is_detected_in_git_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], capture_output=True, check=True)
            git('init', '-q')
            (root / 'phone-session.json').write_text('{}', encoding='utf-8')
            git('add', '.')
            git('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'synthetic fixture')
            (root / 'phone-session.json').unlink()
            git('add', '-u')
            git('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'remove fixture')
            self.assertTrue(any('git history phone-session.json' in issue for issue in scan(root)))

    def test_staged_secret_detected_after_worktree_is_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', '-C', str(root), 'init', '-q'], capture_output=True, check=True)
            (root / 'config').mkdir()
            path = root / 'config' / 'example.json'
            path.write_text(json.dumps({'pkey': 'synthetic' * 8}), encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', '.'], capture_output=True, check=True)
            path.write_text('{}', encoding='utf-8')
            self.assertTrue(any('git index config/example.json: credential' in issue for issue in scan(root)))

    def test_actual_public_bundle(self):
        issues = scan(ROOT)
        self.assertEqual(issues, [], '\n'.join(issues))


class DeploymentDocumentation(unittest.TestCase):
    def test_resource_requirements_match_source(self):
        # Read public source as data: never import the live signing/task modules.
        source = (ROOT / 'src/heybox/PrepareResources.py').read_text(encoding='utf-8-sig')
        tree = ast.parse(source)
        values = {}
        for item in tree.body:
            if isinstance(item, ast.Assign) and isinstance(item.targets[0], ast.Name):
                if item.targets[0].id in ('LIBRARIES', 'SUPPLIED'):
                    values[item.targets[0].id] = ast.literal_eval(item.value)
        resource_doc = (ROOT / 'docs/heybox-resources.md').read_text(encoding='utf-8')
        for filename, digest in values['LIBRARIES'].items():
            self.assertIn(filename, resource_doc)
            self.assertIn(digest, resource_doc)
        for filename in values['SUPPLIED']:
            self.assertIn(filename, resource_doc)
        for pinned in ('1.3.397', '1138'):
            self.assertIn(pinned, source)
            self.assertIn(pinned, resource_doc)
        installer = (ROOT / 'scripts/Install-Heybox.ps1').read_text(encoding='utf-8-sig')
        commit = re.search(r"\$upstreamCommit='([a-f0-9]{40})'", installer).group(1)
        self.assertIn(commit, resource_doc)
        report_builder = (ROOT / 'src/heybox/ReportBuilder.java').read_text(encoding='utf-8-sig')
        for key in re.findall(r'material\(p, "([a-z_]+)"\)', report_builder):
            self.assertIn(key + '_b64', resource_doc)

    def test_ai_entrypoints_and_relative_links_resolve(self):
        for filename in ('AGENTS.md', 'README.md', 'docs/ai-deployment.md', 'docs/heybox-resources.md'):
            path = ROOT / filename
            content = path.read_text(encoding='utf-8-sig')
            for target in re.findall(r'\]\(([^)]+)\)', content):
                if '://' not in target and not target.startswith('#'):
                    self.assertTrue((path.parent / target.split('#', 1)[0]).is_file(), (filename, target))
        ai_doc = (ROOT / 'docs/ai-deployment.md').read_text(encoding='utf-8')
        self.assertIn('BLOCKED_HEYBOX_RESOURCES', ai_doc)
        self.assertIn('SCHEDULE_NOT_CREATED', ai_doc)
        self.assertIn('-Scheduled', ai_doc)
        version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
        self.assertIn(version, (ROOT / 'README.md').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
