function New-CoinDonationReport {
  param([string]$DailyLog,$CoinLogData,[scriptblock]$ResolveVideo)
  $name=[IO.Path]::GetFileName($DailyLog)
  if($name -notmatch '^Daily-(\d{8})-\d{6}\.txt$'){throw 'InvalidDailyLogName'}
  $date=[datetime]::ParseExact($Matches[1],'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
  $native=[Collections.Generic.List[object]]::new()
  $title=$null
  foreach($line in (Get-Content -LiteralPath $DailyLog -Encoding UTF8)) {
    if($line -match '^\[(\d{2}:\d{2}:\d{2})\s+\w+\]\s+【视频】(.*)$'){$title=$Matches[2]}
    elseif($title -and $line -match '^\[(\d{2}:\d{2}:\d{2})\s+\w+\]\s+投币成功，经验\+10') {
      $native.Add([pscustomobject]@{Title=$title;Coins=1;SuccessTime=($date+' '+$Matches[1])})
      $title=$null
    }
  }
  $rows=[Collections.Generic.List[object]]::new()
  $risk=$false
  $requests=0
  $cache=@{}
  if($CoinLogData -and $ResolveVideo) {
    foreach($entry in $CoinLogData.list) {
      if(([string]$entry.time) -notlike ($date+' *') -or [decimal]$entry.delta -notin @(-1,-2) -or $entry.reason -notmatch '^给视频\s+(BV[0-9A-Za-z]{10})\s+打赏$'){continue}
      $bvid=$Matches[1]
      $rows.Add([ordered]@{Title=$null;Coins=(-[decimal]$entry.delta);SuccessTime=$null;UpName=$null;Bvid=$bvid;VideoUrl=('https://www.bilibili.com/video/'+$bvid);LedgerTime=[string]$entry.time;Verified=$false;NativeTitleMatched=$false;Reason='VideoMetadataNotQueried'})
    }
    foreach($row in $rows) {
      try {
        if(-not $cache.ContainsKey($row.Bvid)) {
          if($requests -ge 5){$row.Reason='MetadataQueryLimit';continue}
          $requests++
          $cache[$row.Bvid]=$null
          $cache[$row.Bvid]=& $ResolveVideo $row.Bvid
        }
        $video=$cache[$row.Bvid]
        if($video.bvid -cne $row.Bvid -or -not $video.title -or -not $video.owner.name){$row.Reason='VideoMetadataMismatch';continue}
        $row.Title=([string]$video.title -replace '[\r\n\t]',' ').Trim()
        $row.UpName=([string]$video.owner.name -replace '[\r\n\t]',' ').Trim()
        $row.NativeTitleMatched=@($native | Where-Object {$_.Title -ceq $video.title}).Count -gt 0
        $row.Verified=$true
        $row.Reason=$null
      } catch {
        $row.Reason=if($_.Exception.Message -eq 'PlatformVerificationRequired'){'PlatformVerificationRequired'}else{'VideoMetadataUnavailable'}
        if($row.Reason -eq 'PlatformVerificationRequired'){$risk=$true;break}
      }
    }
  }
  $scope='ObservedDailyPlatformSpending'
  if(-not $rows.Count) {
    $scope='NativeLogOnly'
    foreach($item in $native){$rows.Add([ordered]@{Title=$item.Title;Coins=1;SuccessTime=$item.SuccessTime;UpName=$null;Bvid=$null;VideoUrl=$null;LedgerTime=$null;Verified=$false;NativeTitleMatched=$true;Reason='NoDailyLedgerRecord'})}
  }
  if($risk){foreach($row in $rows){if($row.Reason -eq 'VideoMetadataNotQueried'){$row.Reason='SkippedAfterRisk'}}}
  $verified=@($rows | Where-Object {$_.Verified}).Count
  $ledgerCoins=if($scope -eq 'ObservedDailyPlatformSpending'){($rows | ForEach-Object {$_.Coins} | Measure-Object -Sum).Sum}else{$null}
  [pscustomobject]@{Date=$date;DailyRunLog=$name;ObservedAt=(Get-Date).ToString('o');Scope=$scope;NativeSuccessCoins=$native.Count;ObservedDailyLedgerCoins=$ledgerCoins;VerifiedRows=$verified;MetadataRequests=$requests;RiskControlEncountered=$risk;NativeSuccessfulVideos=$native.ToArray();Donations=$rows.ToArray()}
}