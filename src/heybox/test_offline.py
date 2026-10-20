"""Synthetic fixtures only. No credentials, ADB, Java, or HTTP."""
from datetime import datetime
import unittest
from DailyLogic import decision, complete, share_events, totals
from ProfileSummary import parse_profile

def fixture(state='finish'):
    return {key: {'PlatformState':state, 'DailyExperience':100 if key=='sign' else 10}
            for key in ('sign','1','19','31')}

class OfflineChecks(unittest.TestCase):
    def test_same_day_completed_skips(self):
        self.assertEqual(decision(datetime(2030,1,2,20), {'Date':'2030-01-02','Tasks':fixture()}),'SkipCompleted')

    def test_missed_today_can_run(self):
        self.assertEqual(decision(datetime(2030,1,2,21), None),'RunToday')

    def test_previous_day_never_runs_before_schedule(self):
        self.assertEqual(decision(datetime(2030,1,2,10), {'Date':'2030-01-01','Tasks':fixture('waiting')}),'SkipBeforeTodaySchedule')

    def test_attempted_day_does_not_retry(self):
        self.assertEqual(decision(datetime(2030,1,2,21), {'Date':'2030-01-02','Tasks':fixture('waiting')}),'SkipAttempted')

    def test_only_pending_share_emits(self):
        events=share_events(['19'],{'19':'730'},1700000000)
        self.assertEqual(len(events),3)
        self.assertEqual(events[0]['path'],'/game/detail/share')
        self.assertEqual(events[0]['addition'],{'app_id':'730'})
        self.assertEqual(events[-1]['addition']['src'],'game_detail')

    def test_unknown_profile_never_becomes_zero(self):
        self.assertIsNone(parse_profile({})['exp_to_next_level'])
        result=totals(fixture(), {'exp_to_next_level':261})
        self.assertEqual(result['DailyTaskExperience'],130)
        self.assertEqual(result['EstimatedDaysToNextLevel'],3)

if __name__ == '__main__':
    unittest.main()
