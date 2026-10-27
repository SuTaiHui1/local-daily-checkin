"""Local evidence-bound recovery permits; no platform or credential access."""
import hashlib
import json
from datetime import date as calendar_date
from pathlib import Path
import re

ID_PATTERN = r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}'


def valid_recovery_id(value):
    return isinstance(value, str) and re.fullmatch(ID_PATTERN, value) is not None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def require_hash(value):
    if not isinstance(value,str) or not re.fullmatch(r'[A-Fa-f0-9]{64}',value):
        raise ValueError('Recovery evidence hash must be SHA256')
    return value.upper()


def safe_log_path(logs, name):
    path = logs/name
    if path.resolve().parent != logs.resolve():
        raise ValueError('Recovery evidence must remain in the same logs directory')
    return path


def day_records(root, date):
    records=[]
    for path in (root/'logs').glob('Daily-'+date.replace('-','')+'*.json'):
        if not re.fullmatch(r'Daily-[0-9]{8}(?:-recovery-'+ID_PATTERN+r')?\.json',path.name):continue
        safe_log_path(root/'logs', path.name)
        value=json.loads(path.read_text(encoding='utf-8-sig'))
        if value.get('Date')==date:records.append((path,value))
    return sorted(records,key=lambda pair:(pair[1].get('CompletedAt') or pair[1].get('StartedAt') or '',bool(pair[1].get('RecoveryId')),pair[0].name))


def current_day_record(root,date):
    records=day_records(root,date)
    return records[-1] if records else (None,None)


def known_finished_tasks(root,date):
    return {key for _,record in day_records(root,date)
            for key,task in record.get('Tasks',{}).items()
            if key in ('sign','1','19','31') and task.get('PlatformState')=='finish'}


def validate_permit(root,date,recovery_id):
    if not valid_recovery_id(recovery_id):raise ValueError('RecoveryId format invalid')
    logs=root/'logs'
    permit_path=safe_log_path(logs,'RecoveryPermit-'+date.replace('-','')+'-'+recovery_id+'.json')
    permit=json.loads(permit_path.read_text(encoding='utf-8-sig'))
    if not isinstance(permit,dict) or permit.get('Date')!=date or permit.get('RecoveryId')!=recovery_id or permit.get('Status')!='ReadyAfterDiagnosis':
        raise ValueError('Recovery permit date, identity or state mismatch')
    allowed=permit.get('AllowedTasks')
    if not isinstance(allowed,list) or not allowed or any(not isinstance(k,str) or k not in ('sign','1','19','31') for k in allowed) or len(set(allowed))!=len(allowed):
        raise ValueError('Recovery permit tasks invalid')
    if permit.get('AllowResubmitWaiting') is not True:
        raise ValueError('Recovery permit does not allow waiting-task resubmission after diagnosis')
    prior_name=permit.get('PriorRecordFile','')
    if not isinstance(prior_name,str) or not re.fullmatch(r'Daily-[0-9]{8}(?:-recovery-'+ID_PATTERN+r')?\.json',prior_name):
        raise ValueError('Recovery prior record must be a direct daily log filename')
    prior_path=safe_log_path(logs,prior_name)
    if digest(prior_path)!=require_hash(permit.get('PriorRecordSHA256')):raise ValueError('Recovery prior record changed')
    prior=json.loads(prior_path.read_text(encoding='utf-8-sig'))
    if not isinstance(prior,dict):raise ValueError('Recovery prior record must be an object')
    prior_date=prior.get('Date')
    if not isinstance(prior_date,str) or calendar_date.fromisoformat(prior_date).isoformat()!=prior_date or prior_date>date:
        raise ValueError('Recovery requires a real current or prior date')
    if not prior_name.startswith('Daily-'+prior_date.replace('-','')):
        raise ValueError('Recovery record date and filename mismatch')
    latest_path,_=current_day_record(root,date)
    if latest_path is not None and latest_path!=prior_path:
        raise ValueError('Recovery permit must bind the latest same-day attempt')
    evidence_name=permit.get('RepairEvidenceFile','')
    if not isinstance(evidence_name,str) or not re.fullmatch(r'RepairEvidence-[A-Za-z0-9_-]+\.json',evidence_name):
        raise ValueError('Recovery requires a direct nonprivate repair-evidence log')
    evidence_path=safe_log_path(logs,evidence_name)
    evidence_sha=digest(evidence_path)
    if evidence_sha!=require_hash(permit.get('RepairEvidenceSHA256')):raise ValueError('Recovery repair evidence changed')
    evidence=json.loads(evidence_path.read_text(encoding='utf-8-sig'))
    if not isinstance(evidence,dict) or evidence.get('Status')!='ValidatedDiagnosis' or not evidence.get('Diagnosis') or not evidence.get('Validation'):
        raise ValueError('Recovery requires diagnosed cause or state and validated next action')
    for _,old in day_records(root,date):
        if old.get('RepairEvidenceSHA256')==evidence_sha:
            raise ValueError('Recovery evidence already consumed; new diagnosis or observation required')
    if 'ArchivedPauseFile' in permit:
        name=permit['ArchivedPauseFile']
        if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,150}\.txt',name):
            raise ValueError('Archived pause must be a direct log filename')
        if digest(safe_log_path(logs,name))!=require_hash(permit.get('ArchivedPauseSHA256')):raise ValueError('Archived pause evidence changed')
    return {**permit,'PermitFile':str(permit_path),'PermitSHA256':digest(permit_path),
            'RepairEvidenceSHA256':evidence_sha,'PriorRecordFile':str(prior_path),
            'SameDaySignRewards':prior.get('SignRewards',{}) if prior.get('Date')==date else {},
            'KnownFinishedTasks':sorted(known_finished_tasks(root,date))}
