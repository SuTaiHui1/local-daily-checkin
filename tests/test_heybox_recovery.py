"""Synthetic offline recovery checks. No real client, credentials, Java or HTTP."""
from contextlib import ExitStack
from datetime import datetime, timezone, timedelta
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import MagicMock, patch

SOURCE = Path(__file__).resolve().parents[1]/'src'/'heybox'
sys.path.insert(0, str(SOURCE))
from DailyLogic import EXP_ICON, KEYS, game_comment_target, rewards_confirmed, decision
from RecoveryLogic import current_day_record, digest, known_finished_tasks, validate_permit

DAY = '2030-01-02'


def tasks(waiting=(), missing=()):
    return {key: {'PlatformState': 'waiting' if key in waiting else 'finish',
                  'DailyExperience': None if key in missing else (100 if key == 'sign' else 10)}
            for key in KEYS}


def platform(waiting=(), missing=()):
    return {'task_list': [{'tasks': [
        {'type': 'sign' if key == 'sign' else 'share',
         'report_extra': {'task_id': key}, 'title': 'fixture',
         'state': task['PlatformState'],
         'award_desc_v2': [] if key in missing else [
             {'icon': EXP_ICON, 'desc': '+'+str(task['DailyExperience'])}]}
        for key, task in tasks(waiting, missing).items()]}],
        'user': {'level_info': {'level': '4', 'exp': '10', 'max_exp': '100', 'coin': '40'}}}


def review(linkid='123', **extra):
    return {'linkid': linkid, 'appid': '730', 'link_tag': '3', **extra}


def write(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')
    return path


class CommentTargetChecks(unittest.TestCase):
    def test_uses_only_real_top_level_review(self):
        result = {'user': {'linkid': '999'}, 'links': [review('123')]}
        self.assertEqual(game_comment_target(result, '730')['LinkId'], '123')

    def test_no_recursive_identifier_fallback(self):
        for value in ({'nested': {'links': [review()]}}, {'links': [{'user': review()}]}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                game_comment_target(value, '730')

    def test_excludes_wrong_kind_game_deleted_private_and_unshareable(self):
        rejected = [review('1', appid='570'), review('2', link_tag='1'),
                    review('3', is_deleted=1), review('4', is_only_me_view='1'),
                    review('5', can_not_share_tips='not shareable'), review('6')]
        self.assertEqual(game_comment_target({'links': rejected+[review('7')]}, '730', {'6'})['LinkId'], '7')

    def test_invalid_identifier_is_not_a_target(self):
        for identifier in (True, 0, '-1', '12/34', '1'*20):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                game_comment_target({'links': [review(identifier)]}, '730')

    def test_completed_state_is_not_missing_reward_confirmation(self):
        record = {'Date': DAY, 'Tasks': tasks(missing=('31',))}
        self.assertFalse(rewards_confirmed(record['Tasks']))
        self.assertEqual(decision(datetime(2030, 1, 2, 20), record), 'RewardConfirmationPending')

    def test_invalid_reward_is_never_confirmed(self):
        for value in (None, True, -1, float('nan'), float('inf'), 'missing'):
            candidate = tasks()
            candidate['31']['DailyExperience'] = value
            with self.subTest(value=value):
                self.assertFalse(rewards_confirmed(candidate))


class RecoveryPermitChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root/'logs'
        self.logs.mkdir()
        self.prior = write(self.logs/'Daily-20300102.json', {
            'Date': DAY, 'CompletedAt': DAY+'T20:00:01+08:00',
            'Tasks': tasks(waiting=('31',)), 'SignRewards': {'sign_in_coin': 10}})
        self.evidence = write(self.logs/'RepairEvidence-fixture.json', {
            'Status': 'ValidatedDiagnosis', 'Diagnosis': 'Synthetic selector defect',
            'Validation': 'Synthetic replacement target passes selector checks'})
        self.permit = {
            'Date': DAY, 'RecoveryId': 'fixture', 'Status': 'ReadyAfterDiagnosis',
            'PriorRecordFile': self.prior.name, 'PriorRecordSHA256': digest(self.prior),
            'RepairEvidenceFile': self.evidence.name, 'RepairEvidenceSHA256': digest(self.evidence),
            'AllowedTasks': ['31'], 'AllowResubmitWaiting': True}

    def validate(self):
        write(self.logs/'RecoveryPermit-20300102-fixture.json', self.permit)
        return validate_permit(self.root, DAY, 'fixture')

    def test_valid_permit_inherits_same_day_finished_and_sign_rewards(self):
        result = self.validate()
        self.assertEqual(set(result['KnownFinishedTasks']), {'sign', '1', '19'})
        self.assertEqual(result['SameDaySignRewards'], {'sign_in_coin': 10})

    def test_original_record_bytes_survive_validation(self):
        before = self.prior.read_bytes()
        self.validate()
        self.assertEqual(self.prior.read_bytes(), before)

    def test_changed_prior_record_refuses_permission(self):
        self.prior.write_text('{}', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.validate()

    def test_changed_repair_evidence_refuses_permission(self):
        self.evidence.write_text('{}', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.validate()

    def test_missing_validation_refuses_permission(self):
        write(self.evidence, {'Status': 'ValidatedDiagnosis', 'Diagnosis': 'fixture'})
        self.permit['RepairEvidenceSHA256'] = digest(self.evidence)
        with self.assertRaises(ValueError):
            self.validate()

    def test_permit_date_identity_and_status_must_match(self):
        for key, value in (('Date', '2030-01-01'), ('RecoveryId', 'different'), ('Status', 'Unconfirmed')):
            with self.subTest(key=key), patch.dict(self.permit, {key: value}), self.assertRaises(ValueError):
                self.validate()

    def test_only_explicit_waiting_task_scope_is_accepted(self):
        for allowed in ([], ['31', '31'], ['other']):
            with self.subTest(allowed=allowed), patch.dict(self.permit, {'AllowedTasks': allowed}), self.assertRaises(ValueError):
                self.validate()
        self.permit['AllowResubmitWaiting'] = False
        with self.assertRaises(ValueError):
            self.validate()

    def test_prior_and_repair_paths_cannot_escape_logs(self):
        for key, value in (('PriorRecordFile', '../Daily-20300102.json'),
                           ('RepairEvidenceFile', '../RepairEvidence-fixture.json')):
            with self.subTest(key=key), patch.dict(self.permit, {key: value}), self.assertRaises(ValueError):
                self.validate()

    def test_latest_same_day_attempt_must_be_bound(self):
        latest = write(self.logs/'Daily-20300102-recovery-new.json', {
            'Date': DAY, 'RecoveryId': 'new', 'StartedAt': DAY+'T20:02:00+08:00',
            'Tasks': tasks(waiting=('31',))})
        self.assertEqual(current_day_record(self.root, DAY)[0], latest)
        with self.assertRaises(ValueError):
            self.validate()

    def test_new_id_does_not_reuse_consumed_repair_evidence(self):
        value = json.loads(self.prior.read_text())
        value['RepairEvidenceSHA256'] = digest(self.evidence)
        write(self.prior, value)
        self.permit['PriorRecordSHA256'] = digest(self.prior)
        with self.assertRaises(ValueError):
            self.validate()

    def test_old_day_is_causal_evidence_only(self):
        self.prior.unlink()
        self.prior = write(self.logs/'Daily-20300101.json', {
            'Date': '2030-01-01', 'Tasks': tasks(), 'SignRewards': {'sign_in_coin': 999}})
        self.permit.update(PriorRecordFile=self.prior.name, PriorRecordSHA256=digest(self.prior))
        result = self.validate()
        self.assertEqual(result['SameDaySignRewards'], {})
        self.assertEqual(result['KnownFinishedTasks'], [])

    def test_future_and_filename_mismatched_records_are_rejected(self):
        for date in ('2030-01-03', '2030-01-01', 'unknown'):
            write(self.prior, {'Date': date})
            self.permit['PriorRecordSHA256'] = digest(self.prior)
            with self.subTest(date=date), self.assertRaises(ValueError):
                self.validate()

    def test_pause_archive_hash_is_checked(self):
        pause = self.logs/'pause-fixture.txt'
        pause.write_text('Synthetic pause reason', encoding='utf-8')
        self.permit.update(ArchivedPauseFile=pause.name, ArchivedPauseSHA256=digest(pause))
        self.validate()
        pause.write_text('changed', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.validate()

    def test_malformed_hashes_and_task_scope_are_refused(self):
        for key in ('PriorRecordSHA256', 'RepairEvidenceSHA256'):
            for value in (None, 123, [], 'not-a-sha256'):
                with self.subTest(key=key, value=value), patch.dict(self.permit, {key: value}), self.assertRaises(ValueError):
                    self.validate()
        for value in ([['31']], [True], [None]):
            with self.subTest(value=value), patch.dict(self.permit, {'AllowedTasks': value}), self.assertRaises(ValueError):
                self.validate()

    def test_previously_finished_task_is_remembered_across_regression(self):
        write(self.logs/'Daily-20300102-recovery-regression.json', {
            'Date': DAY, 'RecoveryId': 'regression', 'StartedAt': DAY+'T20:02:00+08:00',
            'Tasks': tasks(waiting=('1', '31'))})
        self.assertIn('1', known_finished_tasks(self.root, DAY))


class DailyFlowChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'logs').mkdir()
        client = types.ModuleType('PhoneClient')
        client.ROOT = self.root
        client.PRIVATE = self.root/'unused-private'
        client.JAVA = Path('unused-java')
        client.now = lambda: DAY+'T20:10:00+08:00'
        def forbidden(*args, **kwargs):
            raise AssertionError('Offline test attempted real client access')
        for name in ('phone_data', 'signed_params', 'get_once', 'post_report_once', 'safe_message'):
            setattr(client, name, forbidden)
        spec = importlib.util.spec_from_file_location('offline_heybox_run', SOURCE/'RunDaily.py')
        self.daily = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'PhoneClient': client}):
            spec.loader.exec_module(self.daily)
        self.record = {'Date': DAY, 'StartedAt': client.now(), 'Status': 'Started',
                       'Tasks': {}, 'Profile': {}, 'SignRewards': {}, 'Requests': [], 'ActionsSubmitted': []}

    def invoke_main(self, args=('--scheduled',), hour=20, run_effect=None):
        current = datetime(2030, 1, 2, hour, 10, tzinfo=timezone(timedelta(hours=8)))
        clock = types.SimpleNamespace(now=lambda: types.SimpleNamespace(astimezone=lambda: current))
        kernel = types.SimpleNamespace(CreateMutexW=MagicMock(return_value=1),
                                       ReleaseMutex=MagicMock(), CloseHandle=MagicMock())
        shell = types.SimpleNamespace(shell32=types.SimpleNamespace(IsUserAnAdmin=lambda: False))
        with ExitStack() as stack:
            stack.enter_context(patch.object(self.daily, 'datetime', clock))
            stack.enter_context(patch.object(self.daily.ctypes, 'windll', shell, create=True))
            stack.enter_context(patch.object(self.daily.ctypes, 'WinDLL', return_value=kernel, create=True))
            stack.enter_context(patch.object(self.daily.ctypes, 'get_last_error', return_value=0, create=True))
            stack.enter_context(patch.object(sys, 'argv', ['RunDaily.py', *args]))
            run = stack.enter_context(patch.object(self.daily, 'run', side_effect=run_effect))
            emit = stack.enter_context(patch.object(self.daily, 'emit'))
            self.daily.main()
        return run, emit.call_args.args[0]

    def test_main_latest_completed_recovery_skips_without_mutation(self):
        original = write(self.root/'logs/Daily-20300102.json', {
            'Date': DAY, 'CompletedAt': DAY+'T20:00:00+08:00', 'Tasks': tasks(waiting=('31',))})
        latest = write(self.root/'logs/Daily-20300102-recovery-fixture.json', {
            'Date': DAY, 'CompletedAt': DAY+'T20:05:00+08:00', 'Tasks': tasks(), 'RecoveryId': 'fixture'})
        before = {path: path.read_bytes() for path in (original, latest)}
        run, result = self.invoke_main()
        run.assert_not_called()
        self.assertEqual(result['Status'], 'SkipCompleted')
        self.assertEqual(result['RecordFile'], str(latest))
        self.assertEqual(result['NetworkRequests'], 0)
        self.assertEqual(result['ActionsSubmittedThisInvocation'], 0)
        self.assertEqual(before, {path: path.read_bytes() for path in before})

    def test_status_prints_latest_local_record_without_launch_or_requests(self):
        record = {'Date': DAY, 'StartedAt': DAY+'T20:05:00+08:00',
                  'Tasks': tasks(waiting=('31',)), 'RecoveryId': 'fixture'}
        write(self.root/'logs/Daily-20300102-recovery-fixture.json', record)
        current = datetime(2030, 1, 2, 20, tzinfo=timezone(timedelta(hours=8)))
        clock = types.SimpleNamespace(now=lambda: types.SimpleNamespace(astimezone=lambda: current))
        with patch.object(self.daily, 'datetime', clock), patch.object(sys, 'argv', ['RunDaily.py', '--status']), patch.object(sys, 'stdout', new_callable=io.StringIO) as output, patch.object(self.daily, 'run') as run, patch.object(self.daily.ctypes, 'WinDLL', side_effect=AssertionError('Status must not launch'), create=True):
            self.daily.main()
        self.assertEqual(json.loads(output.getvalue()), record)
        run.assert_not_called()

    def test_main_manual_attempt_uses_latest_recovery_record(self):
        latest = write(self.root/'logs/Daily-20300102-recovery-fixture.json', {
            'Date': DAY, 'StartedAt': DAY+'T20:05:00+08:00', 'Tasks': tasks(waiting=('31',)), 'RecoveryId': 'fixture'})
        run, result = self.invoke_main(('--run',))
        run.assert_not_called()
        self.assertEqual(result['Status'], 'SkipAttempted')
        self.assertEqual(result['RecordFile'], str(latest))

    def test_main_before_schedule_never_starts_or_creates_attempt(self):
        run, result = self.invoke_main(hour=19)
        run.assert_not_called()
        self.assertEqual(result['Status'], 'SkipBeforeTodaySchedule')
        self.assertFalse(list((self.root/'logs').glob('Daily-*.json')))

    def test_main_pause_preserves_original_and_never_starts(self):
        original = write(self.root/'logs/Daily-20300102.json', {'Date': DAY, 'Tasks': tasks(waiting=('31',))})
        self.daily.PAUSE.write_text('Synthetic diagnostic pause', encoding='utf-8')
        before = original.read_bytes()
        run, result = self.invoke_main(('--scheduled', '--recovery-id', 'fixture'))
        run.assert_not_called()
        self.assertEqual(result['Status'], 'Paused')
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual(self.daily.PAUSE.read_text(), 'Synthetic diagnostic pause')

    def test_main_invalid_permit_does_not_consume_attempt(self):
        write(self.root/'logs/RecoveryPermit-20300102-fixture.json', [])
        run, result = self.invoke_main(('--scheduled', '--recovery-id', 'fixture'))
        run.assert_not_called()
        self.assertEqual(result['Status'], 'RecoveryPermitUnconfirmed')
        self.assertFalse(list((self.root/'logs').glob('Daily-*.json')))

    def test_main_valid_recovery_appends_record_and_keeps_original(self):
        original = write(self.root/'logs/Daily-20300102.json', {
            'Date': DAY, 'CompletedAt': DAY+'T20:00:00+08:00', 'Tasks': tasks(waiting=('31',))})
        evidence = write(self.root/'logs/RepairEvidence-fixture.json', {
            'Status': 'ValidatedDiagnosis', 'Diagnosis': 'Synthetic target defect', 'Validation': 'Synthetic selector check'})
        write(self.root/'logs/RecoveryPermit-20300102-fixture.json', {
            'Date': DAY, 'RecoveryId': 'fixture', 'Status': 'ReadyAfterDiagnosis',
            'PriorRecordFile': original.name, 'PriorRecordSHA256': digest(original),
            'RepairEvidenceFile': evidence.name, 'RepairEvidenceSHA256': digest(evidence),
            'AllowedTasks': ['31'], 'AllowResubmitWaiting': True})
        before = original.read_bytes()
        def finish(record):
            self.assertTrue(self.daily.record_path(record).exists())
            self.assertEqual(record['RecoveryAllowedTasks'], ['31'])
            self.assertEqual(record['KnownFinishedTasks'], ['1', '19', 'sign'])
            record.update(Tasks=tasks(), Status='ConfirmedDailyTasks', RecoveryState='Confirmed')
        run, result = self.invoke_main(('--scheduled', '--recovery-id', 'fixture'), run_effect=finish)
        run.assert_called_once()
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual(Path(result['RecordFile']).name, 'Daily-20300102-recovery-fixture.json')
        self.assertEqual(result['Status'], 'ConfirmedDailyTasks')

    def test_main_first_failure_is_preserved_and_not_retried(self):
        def fail(record):
            record['ActionsSubmitted'].append('31')
            raise self.daily.StopDaily('Synthetic unconfirmed result')
        run, first = self.invoke_main(run_effect=fail)
        run.assert_called_once()
        path = Path(first['RecordFile'])
        before = path.read_bytes()
        self.assertEqual(first['Status'], 'StoppedOrUnconfirmed')
        self.assertEqual(first['ActionsSubmittedThisInvocation'], 1)
        run, second = self.invoke_main()
        run.assert_not_called()
        self.assertEqual(second['Status'], 'Paused')
        self.assertEqual(path.read_bytes(), before)

    def test_only_missing_allowed_review_is_submitted_and_target_saved(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=['31'], KnownFinishedTasks=['sign', '1', '19'])
        requests = []
        def request(record, path, extra=None, form=None):
            requests.append(path)
            if path == '/bbs/app/link/game/comments':
                return {'links': [review()]}
            return platform(waiting=('31',)) if len(requests) == 1 else platform()
        with patch.object(self.daily, 'request', side_effect=request), patch.object(self.daily, 'report_events') as submit, patch.object(self.daily.time, 'sleep'):
            self.daily.run(self.record)
        self.assertEqual(self.record['ActionsSubmitted'], ['31'])
        self.assertEqual(self.record['ShareTargets']['31']['LinkId'], '123')
        self.assertEqual(self.record['Status'], 'ConfirmedDailyTasks')
        self.assertEqual(self.record['RecoveryState'], 'Confirmed')
        submit.assert_called_once()
        self.assertNotIn('/task/sign_v3/sign', requests)
        self.assertEqual(self.daily.record_path(self.record).name, 'Daily-20300102-recovery-fixture.json')

    def test_finish_never_replayed_in_recovery(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=list(KEYS))
        with patch.object(self.daily, 'request', return_value=platform()) as request, patch.object(self.daily, 'report_events') as submit:
            self.daily.run(self.record)
        self.assertEqual(request.call_count, 1)
        submit.assert_not_called()
        self.assertEqual(self.record['ActionsSubmitted'], [])

    def test_finish_without_reward_only_reconciles_and_stays_unconfirmed(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=['31'])
        with patch.object(self.daily, 'request', return_value=platform(missing=('31',))) as request, patch.object(self.daily, 'report_events') as submit:
            with self.assertRaises(self.daily.StopDaily):
                self.daily.run(self.record)
        self.assertEqual(request.call_count, 1)
        submit.assert_not_called()
        self.assertEqual(self.record['ActionsSubmitted'], [])

    def test_known_finished_regression_is_not_resubmitted(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=['31'], KnownFinishedTasks=['31'])
        with patch.object(self.daily, 'request', return_value=platform(waiting=('31',))) as request, patch.object(self.daily, 'report_events') as submit:
            with self.assertRaises(self.daily.StopDaily):
                self.daily.run(self.record)
        self.assertEqual(request.call_count, 1)
        submit.assert_not_called()
        self.assertEqual(self.record['Tasks']['31']['Result'], 'PreviouslyConfirmedNoReplay')

    def test_waiting_outside_recovery_scope_is_not_submitted(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=['31'])
        with patch.object(self.daily, 'request', return_value=platform(waiting=('1',))) as request, patch.object(self.daily, 'report_events') as submit:
            with self.assertRaises(self.daily.StopDaily):
                self.daily.run(self.record)
        self.assertEqual(request.call_count, 1)
        submit.assert_not_called()
        self.assertEqual(self.record['Tasks']['1']['Result'], 'OutsideRecoveryScope')

    def test_unconfirmed_prior_targets_are_excluded(self):
        for identifier, state in (('123', 'waiting'), ('456', 'finish')):
            write(self.root/'logs'/('Daily-20291231-recovery-'+identifier+'.json'), {
                'ActionsSubmitted': ['31'], 'Tasks': {'31': {'PlatformState': state}},
                'ShareTargets': {'31': {'LinkId': identifier}}})
        self.assertEqual(self.daily.unconfirmed_game_comment_ids(), {'123'})

    def test_no_eligible_target_stops_before_submission(self):
        self.record.update(RecoveryId='fixture', RecoveryAllowedTasks=['31'])
        with patch.object(self.daily, 'request', side_effect=[platform(waiting=('31',)), {'links': [review(is_deleted=1)]}]), patch.object(self.daily, 'report_events') as submit:
            with self.assertRaises(self.daily.StopDaily):
                self.daily.run(self.record)
        submit.assert_not_called()
        self.assertEqual(self.record['ActionsSubmitted'], [])


class ReportChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root/'logs'
        self.logs.mkdir()
        paths = types.ModuleType('Paths')
        paths.STATE_ROOT = self.root
        spec = importlib.util.spec_from_file_location('offline_heybox_report', SOURCE/'Report.py')
        self.report = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'Paths': paths}):
            spec.loader.exec_module(self.report)
        self.original = write(self.logs/'Daily-20300102.json', {
            'Date': DAY, 'Tasks': tasks(waiting=('31',)), 'DailyTaskExperience': 120,
            'CompletedAt': DAY+'T20:00:00+08:00'})
        self.latest = write(self.logs/'Daily-20300102-recovery-fixture.json', {
            'Date': DAY, 'RecoveryId': 'fixture', 'Tasks': tasks(), 'DailyTaskExperience': 130,
            'CompletedAt': DAY+'T20:10:00+08:00', 'Profile': {'level': 4}})
        self.invocation = {'Date': DAY, 'Status': 'ConfirmedDailyTasks',
                           'InvocationObservedAt': DAY+'T20:10:01+08:00',
                           'RecordFile': str(self.latest), 'NetworkRequests': 3,
                           'ActionsSubmittedThisInvocation': 1}

    def export(self):
        path = self.report.export_report(self.invocation)
        return json.loads(path.read_text(encoding='utf-8'))

    def test_recovery_record_produces_four_complete_rows_and_130(self):
        result = self.export()
        self.assertEqual(len(result['PublicTasks']), 4)
        self.assertEqual(sum(row['DailyExperience'] for row in result['PublicTasks']), 130)
        self.assertEqual(result['SummarySource'], str(self.latest.resolve()))
        self.assertEqual(result['RecordFile'], str(self.latest.resolve()))
        self.assertEqual(result['ActionsSubmittedThisInvocation'], 1)
        self.assertTrue(result['NewObservation'])
        self.assertEqual(result['PublicTasks'], result['Tasks'])
        self.assertEqual(result['PublicSummary'], result['Summary'])

    def test_completed_skip_has_zero_new_operations_and_prior_observation_time(self):
        self.invocation.update(Status='SkipCompleted', NetworkRequests=0, ActionsSubmittedThisInvocation=0)
        result = self.export()
        self.assertFalse(result['NewObservation'])
        self.assertEqual(result['ActionsSubmittedThisInvocation'], 0)
        self.assertEqual(result['SummaryObservedAt'], DAY+'T20:10:00+08:00')
        self.assertTrue(all(row['Result'] == '今天已完成，本次跳过' for row in result['PublicTasks']))

    def test_explicit_original_record_is_not_silently_replaced_by_recovery(self):
        self.invocation['RecordFile'] = str(self.original)
        result = self.export()
        self.assertIsNone(result['PublicTasks'][-1]['DailyExperience'])
        self.assertEqual(result['RecordFile'], str(self.original.resolve()))

    def test_record_outside_logs_is_not_loaded(self):
        outside = write(self.root/'Daily-20300102.json', {'Date': DAY, 'Tasks': tasks()})
        self.invocation['RecordFile'] = str(outside)
        result = self.export()
        self.assertIsNone(result['RecordFile'])
        self.assertTrue(all(row['DailyExperience'] is None for row in result['PublicTasks']))

    def test_old_day_record_is_not_loaded_as_today(self):
        old = write(self.logs/'Daily-20300101.json', {'Date': '2030-01-01', 'Tasks': tasks()})
        self.invocation['RecordFile'] = str(old)
        self.assertIsNone(self.export()['RecordFile'])

    def test_invalid_record_does_not_inherit_skip_completed_claim(self):
        self.invocation.update(Status='SkipCompleted', NetworkRequests=0, RecordFile=str(self.root/'outside.json'))
        result = self.export()
        self.assertTrue(all(row['Result'] == '未执行或未确认' for row in result['PublicTasks']))

    def test_observation_time_is_query_time_not_later_record_save(self):
        record = json.loads(self.latest.read_text())
        record['Profile']['ObservedAt'] = DAY+'T20:09:59+08:00'
        write(self.latest, record)
        result = self.export()
        self.assertEqual(result['SummaryObservedAt'], DAY+'T20:09:59+08:00')
        self.assertEqual(result['SnapshotObservedAt'], DAY+'T20:09:59+08:00')


if __name__ == '__main__':
    unittest.main()
