function Get-Level6Forecast {
  param([long]$Remaining,[decimal]$CoinBalance,[int]$CoinTarget,[decimal]$ProtectedCoins,[bool]$WatchEnabled,[bool]$ShareEnabled=$false)
  $dailyBase=5+5*[int]$WatchEnabled+5*[int]$ShareEnabled
  $target=[Math]::Max(0,[Math]::Min(5,$CoinTarget))
  $available=[Math]::Max(0,[Math]::Floor($CoinBalance)-[Math]::Max(0,$ProtectedCoins))
  $fullDaily=$dailyBase+10*$target
  $idealDays=[int][Math]::Ceiling([Math]::Max(0,$Remaining)/$fullDaily)
  $days=0
  while($dailyBase*$days+10*[Math]::Min($target*$days,$available+$days) -lt $Remaining){$days++}
  [pscustomobject]@{EstimatedDaysToLv6=$days;EstimatedDaysWithEnoughCoins=$idealDays;EstimatedFullDailyExperience=$fullDaily}
}
