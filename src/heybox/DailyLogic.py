"""Small, offline decisions for the four approved Heybox daily tasks."""
import math
import re
from datetime import datetime

KEYS=('sign','1','19','31')
EXP_ICON='b9aca51c41694ca32f36f4a16d980c40'


def number(value):
    if isinstance(value,bool):return None
    try:
        x=float(value)
        return (int(x) if x.is_integer() else x) if math.isfinite(x) and x>=0 else None
    except (TypeError,ValueError,OverflowError):return None


def snapshot(result):
    if not isinstance(result,dict):raise ValueError('Unexpected task result')
    out={}
    for group in result.get('task_list',[]):
        if not isinstance(group,dict):continue
        for task in group.get('tasks',[]):
            if not isinstance(task,dict):continue
            key='sign' if task.get('type')=='sign' else str((task.get('report_extra') or {}).get('task_id'))
            if key not in KEYS:continue
            if key in out:raise ValueError('Duplicate daily task definition')
            awards=task.get('award_desc_v2') or []
            exp=None
            for award in awards:
                if isinstance(award,dict) and EXP_ICON in str(award.get('icon','')):
                    exp=number(str(award.get('desc','')).lstrip('+'))
            out[key]={'Task':str(task.get('title',''))[:100],
                      'PlatformState':task.get('state'),'DailyExperience':exp}
    if set(out)!=set(KEYS):raise ValueError('Expected four daily tasks missing')
    if any(t['PlatformState'] not in ('finish','waiting') for t in out.values()):
        raise ValueError('Unrecognized daily task state')
    return out


def complete(tasks):
    return set(tasks)==set(KEYS) and all(tasks[k].get('PlatformState')=='finish' for k in KEYS)


def rewards_confirmed(tasks):
    """Completed states and four valid reward amounts are separate facts."""
    return complete(tasks) and all(number(tasks[k].get('DailyExperience')) is not None for k in KEYS)


def pending(tasks):
    if set(tasks)!=set(KEYS):raise ValueError('Daily task state incomplete')
    return [k for k in KEYS if tasks[k]['PlatformState']=='waiting']


def game_comment_target(result, appid, excluded=()):
    """Select an actual shareable review from GameCommentsObj.links only."""
    links=result.get('links') if isinstance(result,dict) else None
    if not isinstance(links,list):raise ValueError('Game comment list missing')
    for index,item in enumerate(links):
        if not isinstance(item,dict):continue
        linkid=item.get('linkid')
        if isinstance(linkid,bool) or not re.fullmatch(r'[1-9][0-9]{0,18}',str(linkid)):continue
        linkid=str(linkid)
        if str(item.get('appid'))!=str(appid) or str(item.get('link_tag'))!='3':continue
        if item.get('is_deleted') in ('1',1,True) or item.get('is_only_me_view') in ('1',1,True):continue
        if item.get('can_not_share_tips') or linkid in excluded:continue
        return {'LinkId':linkid,'AppId':str(appid),'LinkTag':'3','SourcePath':'links['+str(index)+']'}
    raise ValueError('No eligible game comment')


def decision(current,record,scheduled=True):
    day=current.date().isoformat()
    if scheduled and current.hour<20:return 'SkipBeforeTodaySchedule'
    if record and record.get('Date')==day:
        if rewards_confirmed(record.get('Tasks',{})):return 'SkipCompleted'
        if complete(record.get('Tasks',{})):return 'RewardConfirmationPending'
        return 'SkipAttempted'
    return 'RunToday'


def totals(tasks,profile):
    confirmed=[t.get('DailyExperience') for t in tasks.values() if t.get('PlatformState')=='finish']
    available=[tasks[k].get('DailyExperience') for k in KEYS] if set(tasks)==set(KEYS) else []
    gained=sum(confirmed) if confirmed and all(x is not None for x in confirmed) else None
    rate=sum(available) if len(available)==4 and all(x is not None for x in available) else None
    remaining=number(profile.get('exp_to_next_level'))
    estimate=math.ceil(remaining/rate) if remaining is not None and rate and rate>0 else None
    return {'DailyTaskExperience':gained,'EstimatedDailyExperience':rate,
            'EstimatedDaysToNextLevel':estimate,
            'ForecastBasis':'Today advertised experience of the four approved tasks, completed every future day; excludes other activity and future reward changes'}


def share_events(waiting,targets,unix_time):
    events=[]
    for key in ('1','19','31'):
        if key not in waiting:continue
        target=targets[key]
        if key=='19':
            events.append({'time':str(unix_time),'type':'4','path':'/game/detail/share',
                           'addition':{'app_id':target}})
        addition={'src':{'1':'link','19':'game_detail','31':'game_comment'}[key],
                  'plat':'WechatSession'}
        addition.update({'appid':target,'app_id':target} if key=='19' else {'link_id':target})
        for typ,action in (('4','tap'),('3','success')):
            events.append({'time':str(unix_time),'type':typ,
                           'path':'/share/behavior/'+action,'addition':addition.copy()})
    return events
