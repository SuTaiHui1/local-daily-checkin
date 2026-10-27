"""Bounded local daily attempts with evidence-based agent recovery, no social publication."""
import argparse
import ctypes
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from PhoneClient import ROOT, PRIVATE, JAVA, phone_data, signed_params, get_once, post_report_once, safe_message, now
from DailyLogic import KEYS, snapshot, complete, rewards_confirmed, pending, decision, totals, share_events, number, game_comment_target
from RecoveryLogic import current_day_record, known_finished_tasks, validate_permit, valid_recovery_id

PAUSE=ROOT/'heybox-paused.txt'


class StopDaily(Exception):pass


def save(path,value):
    temp=path.with_suffix('.tmp')
    temp.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
    os.replace(temp,path)


def load(path):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else None


def emit(value):
    value={**value,'InvocationObservedAt':now()}
    from Report import export_report
    value.setdefault('ActionsSubmittedThisInvocation',0)
    value['ReportFile']=str(export_report(value))
    save(ROOT/'logs/last-invocation.json',value)
    print(json.dumps(value,ensure_ascii=True))


def request(record,path,extra=None,form=None):
    if PAUSE.exists():raise StopDaily('Local pause pending diagnosis; current attempt stopped')
    if now()[:10]!=record['Date']:raise StopDaily('Local date changed; no historical processing')
    data=phone_data()
    params={**signed_params(data,path),**(extra or {})}
    if PAUSE.exists():raise StopDaily('Local pause created during signing; no request')
    if now()[:10]!=record['Date']:raise StopDaily('Local date changed during signing; no historical request')
    step={'Endpoint':path,'StartedAt':now(),'Retries':0}
    record['Requests'].append(step);save(record_path(record),record)
    try:
        http,payload=post_report_once(data,params,form) if form else get_once(data,path,params)
    except Exception:
        step['Status']='NetworkOrFormatUnconfirmed';raise StopDaily('Network or response format unconfirmed; current attempt stopped for diagnosis and recovery')
    step['HttpStatus']=http
    status=payload.get('status') if isinstance(payload,dict) else None
    step['BusinessStatus']=status if isinstance(status,str) and re.fullmatch(r'[A-Za-z0-9_-]{1,40}',status) else 'Unconfirmed'
    if http!=200 or status!='ok':
        if isinstance(payload,dict):
            step['BusinessCodes']={k:payload[k] for k in ('code','errno','error_code') if type(payload.get(k)) is int}
            step['SafeReason']=safe_message(payload.get('msg') or payload.get('message'),data,params)
        raise StopDaily(step.get('SafeReason') or 'Official request rejected or unconfirmed; current attempt stopped for diagnosis')
    step['CompletedAt']=now();save(record_path(record),record)
    return payload.get('result')


def record_path(record):
    suffix='-recovery-'+record['RecoveryId'] if record.get('RecoveryId') else ''
    return ROOT/('logs/Daily-'+record['Date'].replace('-','')+suffix+'.json')


def first_link(result):
    stack=[result];seen=0
    while stack and seen<2000:
        item=stack.pop();seen+=1
        if isinstance(item,dict):
            for key in ('linkid','link_id'):
                value=str(item.get(key,''))
                if re.fullmatch(r'[1-9][0-9]{0,18}',value):return value
            stack.extend(reversed(list(item.values())))
        elif isinstance(item,list):stack.extend(reversed(item))
    raise StopDaily('No real public share target found; no invented identifier')


def unconfirmed_game_comment_ids():
    """Keep known unresolved review targets out of future daily selections."""
    excluded=set()
    for path in (ROOT/'logs').glob('Daily-*.json'):
        old=load(path)
        if '31' not in old.get('ActionsSubmitted',[]):continue
        if old.get('Tasks',{}).get('31',{}).get('PlatformState')=='finish':continue
        linkid=old.get('ShareTargets',{}).get('31',{}).get('LinkId')
        if re.fullmatch(r'[1-9][0-9]{0,18}',str(linkid)):excluded.add(str(linkid))
    for path in (ROOT/'logs').glob('GameCommentTargetEvidence-*.json'):
        old=load(path)
        if old.get('Status')!='SubmittedRewardUnconfirmed':continue
        linkid=old.get('Target',{}).get('LinkId')
        if re.fullmatch(r'[1-9][0-9]{0,18}',str(linkid)):excluded.add(str(linkid))
    return excluded


def report_events(record,events):
    payload=json.dumps({'events':events},separators=(',',':'))
    eventfile=PRIVATE/'daily-events.json';envelopefile=PRIVATE/'daily-envelope.json'
    eventfile.write_text(payload,encoding='utf-8')
    builder=PRIVATE/'build'
    result=subprocess.run([str(JAVA),'-cp',str(builder),'ReportBuilder','build',
        str(PRIVATE/'report-material.properties'),str(PRIVATE/'report-public-key.der'),
        str(eventfile),str(envelopefile)],capture_output=True,timeout=30)
    if result.returncode:raise StopDaily('Local report construction failed; no submission')
    envelope=load(envelopefile)
    if not envelope or set(envelope)!={'data','key','sid','time'} or envelope['sid']!=hashlib.md5((envelope['key']+envelope['time']).encode()).hexdigest()+hashlib.md5(envelope['data'].encode()).hexdigest():
        raise StopDaily('Local report integrity unconfirmed; no submission')
    request(record,'/account/data_report/',{'type':'104','time_':envelope['time'],'session_id':str(uuid.uuid4())},
            {k:envelope[k] for k in ('data','key','sid')})


def run(record):
    from ProfileSummary import parse_profile
    result=request(record,'/task/list_v2/')
    tasks=snapshot(result)
    record['Profile']={**parse_profile(result),'ObservedAt':now()}
    record['BeforeProfile']=record['Profile'].copy()
    record['Tasks']=tasks
    todo=pending(tasks)
    known=set(record.get('KnownFinishedTasks',[]))
    allowed=set(record.get('RecoveryAllowedTasks',KEYS))
    todo=[key for key in todo if key in allowed and key not in known]
    for key,task in tasks.items():
        task['Result']='TodayAlreadyComplete' if task['PlatformState']=='finish' else ('PreviouslyConfirmedNoReplay' if key in known else ('NotExecuted' if key in todo else 'OutsideRecoveryScope'))
    save(record_path(record),record)
    if 'sign' in todo:
        record['ActionsSubmitted'].append('sign');save(record_path(record),record)
        request(record,'/task/sign_v3/sign')
        time.sleep(3)
        state=request(record,'/task/sign_v3/get_sign_state')
        dayindex=int((time.time()+8*3600)//86400)
        if not isinstance(state,dict) or state.get('state')!='ok' or state.get('signed_date')!=dayindex:
            raise StopDaily('Today sign-in result unconfirmed; reconcile platform state before evidence-based recovery')
        record['SignRewards']={k:number(state.get(k)) for k in ('sign_in_exp','sign_in_coin','sign_in_streak')}
        tasks['sign']['PlatformState']='finish';tasks['sign']['Result']='Success'
        save(record_path(record),record)
    shares=[k for k in ('1','19','31') if k in todo]
    if shares:
        targets={'19':'730'}  # Existing real public game, accepted in the local verification.
        if '1' in shares:targets['1']=first_link(request(record,'/bbs/app/feeds',{'pull':1}))
        if '31' in shares:
            comments=request(record,'/bbs/app/link/game/comments',{'appid':'730','api_version':'4','offset':0,'limit':5})
            excluded=unconfirmed_game_comment_ids()
            try:target=game_comment_target(comments,'730',excluded)
            except ValueError:raise StopDaily('No eligible public game comment found; no share submission')
            record.setdefault('ShareTargets',{})['31']=target
            record['ExcludedUnconfirmedGameCommentTargets']=len(excluded)
            save(record_path(record),record)
            targets['31']=target['LinkId']
        events=share_events(shares,targets,int(time.time()))
        record['ActionsSubmitted'].extend(shares);save(record_path(record),record)
        report_events(record,events)
        if '19' in shares:request(record,'/task/shared/',{'shared_type':'game'})
    if todo:
        time.sleep(3)
        result=request(record,'/task/list_v2/')
        final=snapshot(result)
        record['Profile']={**parse_profile(result),'ObservedAt':now()}
        for key,task in final.items():
            task['Result']=('Success' if task['PlatformState']=='finish' else 'Unconfirmed') if key in todo else ('TodayAlreadyComplete' if task['PlatformState']=='finish' else ('PreviouslyConfirmedNoReplay' if key in known else 'OutsideRecoveryScope'))
        record['Tasks']=tasks=final
    if not complete(tasks):raise StopDaily('Daily tasks unconfirmed for task keys: '+','.join(pending(tasks))+'; awaiting diagnosis and evidence-based recovery')
    if not rewards_confirmed(tasks):raise StopDaily('All task states finish but reward amounts remain unconfirmed; only reward reconciliation is needed')
    record['Status']='ConfirmedDailyTasks';record['TaskCompletedAt']=now()
    if record.get('RecoveryId'):record['RecoveryState']='Confirmed'
    save(record_path(record),record)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--scheduled',action='store_true')
    parser.add_argument('--run',action='store_true')
    parser.add_argument('--state-root')
    parser.add_argument('--status',action='store_true')
    parser.add_argument('--recovery-id')
    args=parser.parse_args()
    if args.recovery_id and (not args.scheduled or args.run or args.status or not valid_recovery_id(args.recovery_id)):
        parser.error('RecoveryId requires the ordinary scheduled task-only entry')
    if not (args.scheduled or args.run or args.status):parser.error('Select scheduled execution or status')
    (ROOT/'logs').mkdir(parents=True,exist_ok=True)
    if datetime.now().astimezone().utcoffset().total_seconds()!=8*3600:
        raise SystemExit('Asia/Shanghai UTC+08 local timezone required; no requests sent')
    date=now()[:10];path=ROOT/('logs/Daily-'+date.replace('-','')+'.json')
    if args.status:
        print(json.dumps(current_day_record(ROOT,date)[1] or {'Date':date,'Status':'NoTodayRecord'},ensure_ascii=True));return
    if ctypes.windll.shell32.IsUserAnAdmin():
        emit({'Date':date,'Status':'RefusedElevatedExecution','NetworkRequests':0})
        raise SystemExit('Use LaunchDaily.ps1 ordinary-user launcher')
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_bool,ctypes.c_wchar_p]
    kernel.CreateMutexW.restype=ctypes.c_void_p
    kernel.ReleaseMutex.argtypes=[ctypes.c_void_p];kernel.CloseHandle.argtypes=[ctypes.c_void_p]
    mutex=kernel.CreateMutexW(None,True,'Local\\HeyboxDailyLocal')
    if not mutex:raise SystemExit('Local mutex unavailable; no execution')
    already=ctypes.get_last_error()==183
    if already:
        kernel.CloseHandle(mutex);emit({'Date':date,'Status':'SkipRunning','NetworkRequests':0});return
    try:
        latest_path,record=current_day_record(ROOT,date)
        if args.scheduled and datetime.now().astimezone().hour<20:
            emit({'Date':date,'Status':'SkipBeforeTodaySchedule','NetworkRequests':0});return
        if record and rewards_confirmed(record.get('Tasks',{})):
            if latest_path is None:
                save(path,record);latest_path=path
            emit({'Date':date,'Status':'SkipCompleted','NetworkRequests':0,'ActionsSubmittedThisInvocation':0,'RecordFile':str(latest_path) if latest_path else None});return
        if PAUSE.exists():
            # Never print arbitrary pause-file content, which might contain old diagnostics.
            emit({'Date':date,'Status':'Paused','RecoveryState':'AwaitingDiagnosisAndRepair','NetworkRequests':0,'RecordFile':str(latest_path) if latest_path else None});return
        recovery=None
        if args.recovery_id:
            recovery_path=ROOT/('logs/Daily-'+date.replace('-','')+'-recovery-'+args.recovery_id+'.json')
            if recovery_path.exists():
                emit({'Date':date,'Status':'SkipAttempted','RecoveryId':args.recovery_id,'NetworkRequests':0,'RecordFile':str(recovery_path)});return
            try:recovery=validate_permit(ROOT,date,args.recovery_id)
            except (ValueError,OSError,TypeError,KeyError):
                emit({'Date':date,'Status':'RecoveryPermitUnconfirmed','RecoveryState':'AwaitingDiagnosisAndRepair','NetworkRequests':0});return
            record=None
        if args.scheduled and recovery is None:
            action=decision(datetime.now().astimezone(),record,True)
            if action!='RunToday':
                if action=='SkipCompleted' and record and not path.exists():save(path,record)
                emit({'Date':date,'Status':action,'RecoveryState':'AwaitingDiagnosisAndRepair' if action in ('SkipAttempted','RewardConfirmationPending') else None,'NetworkRequests':0,'ActionsSubmittedThisInvocation':0,'RecordFile':str(latest_path) if latest_path else None});return
        if record:
            emit({'Date':date,'Status':'SkipAttempted','NetworkRequests':0,'RecordFile':str(latest_path)});return
        if record is None:
            record={'Date':date,'StartedAt':now(),'Status':'Started','Tasks':{},'Profile':{},'SignRewards':{},
                    'Requests':[],'ActionsSubmitted':[],'ExternalSocialMessagesSent':0,
                    'ShareMode':'UserAuthorizedSimulatedRegistration','AutomaticRetries':0}
            if recovery is not None:
                record.update({'RecoveryId':args.recovery_id,'RecoveryAllowedTasks':recovery['AllowedTasks'],
                               'SignRewards':recovery['SameDaySignRewards'],
                               'KnownFinishedTasks':recovery['KnownFinishedTasks'],'PriorRecordFile':recovery['PriorRecordFile'],
                               'PriorRecordSHA256':recovery['PriorRecordSHA256'],'PermitFile':recovery['PermitFile'],
                               'PermitSHA256':recovery['PermitSHA256'],'RepairEvidenceFile':recovery['RepairEvidenceFile'],
                               'RepairEvidenceSHA256':recovery['RepairEvidenceSHA256'],'RecoveryState':'ReconcileCurrentPlatformStateFirst'})
                path=record_path(record)
            with path.open('x',encoding='utf-8') as f:json.dump(record,f)
        record['ExecutionElevated']=False
        previous_requests=len(record.get('Requests',[]))
        try:
            run(record)
        except StopDaily as exc:
            record['SafeReason']=str(exc)[:200]
            record['Status']='RewardUnconfirmed' if complete(record.get('Tasks',{})) else 'StoppedOrUnconfirmed'
            PAUSE.write_text(now()+' '+record['SafeReason'],encoding='utf-8')
            record['LocalPaused']=True
            record['RecoveryState']='AwaitingDiagnosisAndRepair'
        except Exception:
            record['SafeReason']='Local processing failed; diagnostic text withheld; awaiting diagnosis and repair'
            record['Status']='StoppedOrUnconfirmed';record['LocalPaused']=True
            PAUSE.write_text(now()+' Local processing failed; inspect filtered daily record before evidence-based recovery.',encoding='utf-8')
            record['RecoveryState']='AwaitingDiagnosisAndRepair'
        record.update(totals(record.get('Tasks',{}),record.get('Profile',{})))
        record['CompletedAt']=now();save(path,record)
        emit({'Date':date,'Status':record['Status'],'RecordFile':str(path),
              'RecoveryId':record.get('RecoveryId'),'RecoveryState':record.get('RecoveryState'),
              'NetworkRequests':len(record.get('Requests',[]))-previous_requests,
              'ActionsSubmittedThisInvocation':len(record.get('ActionsSubmitted',[]))})
    finally:
        kernel.ReleaseMutex(mutex);kernel.CloseHandle(mutex)


if __name__=='__main__':main()
