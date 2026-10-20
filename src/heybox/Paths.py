"""Private deployment state never lives in the source checkout."""
import json
import os
from pathlib import Path
import sys

CODE_ROOT = Path(__file__).resolve().parent
REPOSITORY = CODE_ROOT.parents[1]

def state_root():
    args = sys.argv
    explicit = args[args.index('--state-root') + 1] if '--state-root' in args else None
    value = explicit or os.environ.get('HEYBOX_STATE_ROOT')
    path = Path(os.path.expandvars(value)) if value else Path(os.environ['LOCALAPPDATA']) / 'LocalDailyCheckin' / 'heybox'
    path = path.resolve()
    if path == REPOSITORY or REPOSITORY in path.parents:
        raise ValueError('Heybox state must be outside the repository')
    return path

STATE_ROOT = state_root()
PRIVATE = STATE_ROOT / 'private'

def java_executable():
    settings = PRIVATE / 'installation.json'
    if not settings.exists():
        return Path('java.exe')
    return Path(json.loads(settings.read_text(encoding='utf-8-sig'))['JavaExecutable'])
