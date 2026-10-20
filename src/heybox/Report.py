"""Thin read-only report over today's already-filtered local business record."""
import json
from Paths import STATE_ROOT

LABELS = {'sign': '签到', '1': '分享帖子', '19': '分享游戏详情', '31': '分享游戏评价'}

def display(value):
    return str(value) if value is not None else '未确认'

def export_report(invocation):
    date = invocation['Date']
    daily_file = STATE_ROOT/'logs'/('Daily-'+date.replace('-', '')+'.json')
    record = json.loads(daily_file.read_text(encoding='utf-8')) if daily_file.exists() else {}
    if record.get('Date') != date:
        record = {}
    tasks = []
    for key, label in LABELS.items():
        task = record.get('Tasks', {}).get(key, {})
        result = task.get('Result', '未执行或未确认')
        if invocation['Status'] == 'SkipCompleted':
            result = '今天已完成，本次跳过'
        elif invocation['Status'] == 'Paused':
            result = '因暂停本次未执行'
        tasks.append({'Key': key, 'Label': label, 'Result': result,
                      'DailyExperience': task.get('DailyExperience') if task.get('PlatformState') == 'finish' else None})
    profile = record.get('Profile', {})
    rewards = record.get('SignRewards', {})
    summary = [
        {'Label': '今日常规任务经验', 'Value': display(record.get('DailyTaskExperience'))},
        {'Label': '当前等级', 'Value': display(profile.get('level'))},
        {'Label': '当前经验进度', 'Value': display(profile.get('exp'))+'/'+display(profile.get('max_exp'))},
        {'Label': '距下一级经验', 'Value': display(profile.get('exp_to_next_level'))},
        {'Label': '预计升级天数', 'Value': display(record.get('EstimatedDaysToNextLevel'))},
        {'Label': 'H币余额', 'Value': display(profile.get('h_coin_balance'))},
        {'Label': '今日签到H币奖励', 'Value': display(rewards.get('sign_in_coin'))},
        {'Label': '连续签到天数', 'Value': display(rewards.get('sign_in_streak'))},
    ]
    report = {'Date': date, 'ObservedAt': invocation['InvocationObservedAt'],
              'Status': invocation['Status'], 'Reason': record.get('SafeReason'),
              'Tasks': tasks, 'Summary': summary, 'Donations': [],
              'SnapshotObservedAt': record.get('CompletedAt') or record.get('TaskCompletedAt'),
              'ProfileObservedAt': profile.get('ObservedAt'),
              'NewObservation': invocation.get('NetworkRequests', 0) > 0,
              'ShareMode': 'UserAuthorizedSimulatedRegistration', 'ExternalSocialMessagesSent': 0,
              'RecordFile': str(daily_file) if record else None}
    path = STATE_ROOT/'logs'/('Report-'+date.replace('-', '')+'.json')
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return path
