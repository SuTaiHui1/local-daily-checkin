"""Thin read-only report over today's already-filtered local business record."""
import json
from pathlib import Path
import re
from Paths import STATE_ROOT
from DailyLogic import number
from RecoveryLogic import ID_PATTERN, current_day_record

LABELS = {'sign': '签到', '1': '分享帖子', '19': '分享游戏详情', '31': '分享游戏评价'}

def display(value):
    return str(value) if value is not None else '未确认'


def invocation_record(invocation):
    """Resolve only a same-day safe daily record within this deployment's logs."""
    date = invocation['Date']
    logs = (STATE_ROOT/'logs').resolve()
    value = invocation.get('RecordFile')
    if value:
        daily_file = Path(value)
        if not daily_file.is_absolute():
            daily_file = logs/daily_file
        daily_file = daily_file.resolve()
        pattern = 'Daily-'+date.replace('-', '')+r'(?:-recovery-'+ID_PATTERN+r')?\.json'
        if daily_file.parent != logs or not re.fullmatch(pattern, daily_file.name):
            return None, {}
        record = json.loads(daily_file.read_text(encoding='utf-8-sig')) if daily_file.exists() else {}
    else:
        daily_file, record = current_day_record(STATE_ROOT, date)
        record = record or {}
    if record.get('Date') != date:
        return None, {}
    return daily_file, record


def export_report(invocation):
    date = invocation['Date']
    daily_file, record = invocation_record(invocation)
    tasks = []
    for key, label in LABELS.items():
        task = record.get('Tasks', {}).get(key, {})
        result = task.get('Result', '未执行或未确认')
        if invocation['Status'] == 'SkipCompleted' and task.get('PlatformState') == 'finish':
            result = '今天已完成，本次跳过'
        elif invocation['Status'] == 'Paused':
            result = '因暂停本次未执行'
        tasks.append({'Key': key, 'Label': label, 'Result': result,
                      'DailyExperience': number(task.get('DailyExperience')) if task.get('PlatformState') == 'finish' else None})
    profile = record.get('Profile', {})
    rewards = record.get('SignRewards', {})
    summary = [
        {'Label': '今日四项任务经验', 'Value': display(record.get('DailyTaskExperience'))},
        {'Label': '当前等级', 'Value': display(profile.get('level'))},
        {'Label': '当前经验进度', 'Value': display(profile.get('exp'))+'/'+display(profile.get('max_exp'))},
        {'Label': '距下一级经验', 'Value': display(profile.get('exp_to_next_level'))},
        {'Label': '下一等级', 'Value': display(number(profile.get('level'))+1 if number(profile.get('level')) is not None else None)},
        {'Label': '预计升级天数（估算）', 'Value': display(record.get('EstimatedDaysToNextLevel'))},
        {'Label': 'H币余额', 'Value': display(profile.get('h_coin_balance'))},
        {'Label': '今日签到H币奖励', 'Value': display(rewards.get('sign_in_coin'))},
        {'Label': '连续签到天数', 'Value': display(rewards.get('sign_in_streak'))},
    ]
    report = {'Date': date, 'ObservedAt': invocation['InvocationObservedAt'],
              'Status': invocation['Status'], 'Reason': record.get('SafeReason'),
              'Tasks': tasks, 'Summary': summary, 'Donations': [],
              'PublicTasks': tasks, 'PublicSummary': summary, 'CoinDonations': [],
              'InvocationStatus': invocation['Status'],
              'ActionsSubmittedThisInvocation': invocation.get('ActionsSubmittedThisInvocation', 0),
              'RecoveryId': invocation.get('RecoveryId'),
              'RecoveryState': invocation.get('RecoveryState'),
              'SummarySource': str(daily_file) if record else None,
              'SummaryObservedAt': profile.get('ObservedAt') or record.get('TaskCompletedAt') or record.get('CompletedAt'),
              'SnapshotObservedAt': profile.get('ObservedAt') or record.get('TaskCompletedAt') or record.get('CompletedAt'),
              'ProfileObservedAt': profile.get('ObservedAt'),
              'NewObservation': invocation.get('NetworkRequests', 0) > 0,
              'ShareMode': 'UserAuthorizedSimulatedRegistration', 'ExternalSocialMessagesSent': 0,
              'RecordFile': str(daily_file) if record else None}
    path = STATE_ROOT/'logs'/('Report-'+date.replace('-', '')+'.json')
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return path
