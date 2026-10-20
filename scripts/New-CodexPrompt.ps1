param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.json'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$settings=Get-LocalDailyConfig -ConfigPath $ConfigPath
$runner=Join-Path $PSScriptRoot 'Run-Daily.ps1'
$configAbsolute=[IO.Path]::GetFullPath($ConfigPath)
$prompt=@"
在当前聊天创建一个每天电脑本地时间20:00（时区$($settings.Config.schedule.timeZone)）运行的Codex本机定时任务。
每次仅运行一次：powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "$runner" -ConfigPath "$configAbsolute" -Scheduled
等待结束，读取 "$($settings.StateRoot)\reports\Combined-YYYYMMDD.json" 和同名.md，核对Date是实际执行当天，按Markdown中的B站和小黑盒两部分一次合并汇报。
保留模块自己的互斥、暂停、当日完成检查；已完成就跳过。B站当天手动/自动累计最多5枚，Lv6停止升级投币；小黑盒只签到及三项获准的模拟分享，不外发社交消息。
不自动重试，不补历史日期，不绕过-Scheduled。一个模块暂停或失败不妨碍另一模块独立检查；只依据当日安全业务结果报告，退出码0不是成功证据，缺失写未确认。
每日报告任务结果与经验、等级和剩余经验/预计天数、余额、签到奖励与记录时间；B站去向简写为“UP主｜视频简写｜数量”。预计天数明确为估算。
所有凭据和执行只在本机；不读取/输出凭据、设备标识、签名或原始响应，不使用第三方签名、云端账号任务、Windows计划任务，不改代理/驱动，不再另建单平台的重复调度。
正常完成、当天已完成跳过和失败/暂停均按上述实际结果汇报，不追加接口补齐报表。电脑须开机联网、当前用户登录且Codex运行。此任务不应在GitHub Actions运行。
"@
Write-Output $prompt
