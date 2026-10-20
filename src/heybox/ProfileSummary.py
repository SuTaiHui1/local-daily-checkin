"""Numeric-only profile summary; importing this module performs no I/O."""

import math
import re


PROFILE_PATH = '/account/info/'


def _nonnegative_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float):
        return value if math.isfinite(value) and value >= 0 else None
    if isinstance(value, str) and re.fullmatch(r'[0-9]+', value.strip()):
        try:
            return int(value.strip())
        except ValueError:
            return None
    if isinstance(value, str) and re.fullmatch(
            r'\+?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?',
            value.strip()):
        try:
            parsed = float(value.strip())
            return parsed if math.isfinite(parsed) and parsed >= 0 else None
        except (ValueError, OverflowError):
            return None
    return None


def _field_metadata(info, key):
    if key not in info:
        return {'present': False, 'type': 'missing'}
    value = info[key]
    kinds = ((type(None), 'null'), (bool, 'boolean'), (int, 'integer'),
             (float, 'float'), (str, 'string'), (dict, 'object'), (list, 'array'))
    kind = next((label for cls, label in kinds if isinstance(value, cls)), 'other')
    return {'present': True, 'type': kind}


def _level_info(result):
    if not isinstance(result, dict):
        return {}
    if isinstance(result.get('result'), dict):
        result = result['result']
    # account/info -> HomeDataObj.account_detail.level_info
    detail = result.get('account_detail')
    if isinstance(detail, dict) and isinstance(detail.get('level_info'), dict):
        return detail['level_info']
    # task/list_v2 -> TaskResultObj.user.level_info
    user = result.get('user')
    if isinstance(user, dict) and isinstance(user.get('level_info'), dict):
        return user['level_info']
    return {}


def parse_profile(result):
    """Return numeric facts plus presence/type metadata for four allowed fields.

    exp/max_exp is the official progress display. Its cumulative/reset semantics
    are not assumed. Missing or malformed values remain None, never zero.
    """
    info = _level_info(result)
    summary = {
        'level': _nonnegative_number(info.get('level')),
        'exp': _nonnegative_number(info.get('exp')),
        'max_exp': _nonnegative_number(info.get('max_exp')),
        'exp_to_next_level': None,
        'h_coin_balance': _nonnegative_number(info.get('coin')),
        'field_metadata': {key: _field_metadata(info, key)
                           for key in ('level', 'exp', 'max_exp', 'coin')},
    }
    exp, maximum = summary['exp'], summary['max_exp']
    if exp is not None and maximum is not None and maximum > 0 and maximum >= exp:
        # Official UserTaskFragmentV2.b5(): parseInt(max_exp) - parseInt(exp).
        summary['exp_to_next_level'] = maximum - exp
    return summary
