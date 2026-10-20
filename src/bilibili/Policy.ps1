# LocalDailyCheckin original adapter. BiliBiliToolPro is installed separately under GPL-3.0.
function Assert-BilibiliConfig {
    param($Config)
    $daily=$Config.DailyTaskConfig
    if ($null -eq $daily -or $daily.NumberOfCoins -ne 5 -or $daily.NumberOfProtectedCoins -ne 0 -or $daily.SaveCoinsWhenLv6 -ne $true -or $daily.SelectLike -ne $false -or $daily.IsDonateCoinForArticle -ne $false -or $daily.IsWatchVideo -ne $true -or $daily.IsShareVideo -ne $true) {
        throw 'DailyPolicyMismatch'
    }
    if ($Config.Security.IntervalMethodTypes -ne 'POST' -or $Config.Security.IntervalSecondsBetweenRequestApi -lt 20 -or $Config.Security.WebProxy) { throw 'SecurityPolicyMismatch' }
    foreach($property in $Config.PSObject.Properties) {
        if($property.Name -ne 'DailyTaskConfig' -and $null -ne $property.Value -and $property.Value.PSObject.Properties['IsEnable'] -and $property.Value.IsEnable) { throw 'ExtraTaskEnabled' }
    }
    $sinks=@($Config.Serilog.WriteTo)
    if($sinks.Count -ne 1 -or $sinks[0].Name -ne 'Console' -or $Config.Serilog.MinimumLevel.Default -ne 'Information') { throw 'LoggingPolicyMismatch' }
}
function Test-BilibiliRiskLine {
    param([string]$Line)
    return $Line -match '(?<!\d)-352(?!\d)|验证码|风控|风险控制|登录失败|登录失效|登录凭证.*失效|Cookie.*(失效|过期)|cookie.*expired|HTTP\s*(403|412)'
}
function ConvertTo-SafeBilibiliLogLine {
    param([string]$Line)
    # Raw requests, credentials, account identifiers and terminal QR blocks never reach persisted logs.
    if($Line -match '(?i)https?://|SESSDATA|bili_jct|DedeUserID|refresh_token|access_token|qrcode_key|变量值|Cookie|Token|响应体|请求体|Headers|Set-Cookie|用户名|昵称|Uid|用户Id|账号|帐号|^[ █▄▀?]+$') { return $null }
    # Every persisted native business line must carry the console template prefix.
    if($Line -notmatch '^\[\d{2}:\d{2}:\d{2}\s+(INF|WRN|ERR|FTL)\]\s+') { return $null }
    # Persist known business records only; unknown exceptions and multiline payloads are omitted.
    if($Line -match '(FlowCompleted DailyTask|登录成功|观看|分享|投币|硬币余额|今日已投|目标欲投|还需再投|【视频】|停止投币等级|已完成|跳过|经验\+|^-?\d+$)') { return $Line }
    return $null
}
function Protect-BilibiliState {
    param([string]$Path)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach($sid in @($identity,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$inherit,'None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
