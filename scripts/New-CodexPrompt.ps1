param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.json'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$settings=Get-LocalDailyConfig -ConfigPath $ConfigPath
$runner=Join-Path $PSScriptRoot 'Run-Daily.ps1'
$configAbsolute=[IO.Path]::GetFullPath($ConfigPath)
$prompt=@"
在当前聊天创建一个每天电脑本地时间20:00（时区$($settings.Config.schedule.timeZone)）运行的Codex本机定时任务。
每天先运行一次：powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "$runner" -ConfigPath "$configAbsolute" -Scheduled
根入口先做B站本地BrowserShare Prepare，再独立处理小黑盒。B站ReadyForBrowser只表示等待官方浏览器分享，不是任务完成；读取本机 "$($settings.StateRoot)\bilibili\Logs\browser-last-invocation.json"，Nonce仅用于本地助手命令，不在汇报中展示。
浏览器操作严格按 "$($settings.Repository)\docs\bilibili-browser.md"：确认是本人已绑定的官方账户，先观察官方当天分享奖励；已有5则按文档ConfirmAlready，不再点击。未完成先ClaimSubmit，只有ReadyForOneClick才通过官方页面点击分享一次；不调用网页私有接口、不发给联系人、不外发消息。保存真实可见的奖励0→5证据后ConfirmSubmitted；页面、账户或奖励不能确认就Fail并保留暂停，不用默认成功码填空。
只有助手返回ReadyForNative后才再次调用同一根入口继续尚未完成的B站原生任务；小黑盒已完成则本地跳过，不重复提交。这次调用是完成前置交接，不是失败重试。已经有分享claim或提交标记却未确认时不再点击，先诊断。
等待结束，读取 "$($settings.StateRoot)\reports\Combined-YYYYMMDD.json" 和同名.md，核对Date是实际执行当天，按Markdown中的B站和小黑盒两部分一次合并汇报。报告只读可用 -ReportOnly；不为补表重跑业务。
保留模块自己的互斥、暂停、当日完成检查；已完成就跳过。B站当天手动/自动累计最多5枚，Lv6停止升级投币；小黑盒只签到及三项获准的模拟分享，不外发社交消息。
不自动重试，不补历史日期，不绕过-Scheduled。一个模块暂停、等待浏览器或失败不妨碍另一模块独立检查；只依据当日安全业务结果报告，退出码0不是成功证据，缺失写未确认。
恢复必须先有本人有效授权、明确原因/修复证据和新的一次性Recovery permit；遵循模块恢复契约，只处理未完成项。B站 -BilibiliRecoveryId 与小黑盒 -HeyboxRecoveryId 分开且只能配合-Scheduled。未知投币结果只能受限只读核对，不补投；保留首次失败、attempt、旧记录和已消耗许可，不删除暂停来重跑。此提示本身不授予自动修复或无限恢复权限。
每日报告任务结果与经验、等级和剩余经验/预计天数、余额、签到奖励与记录时间；B站去向简写为“UP主｜视频简写｜数量”。预计天数明确为估算。
所有凭据和执行只在本机；不读取/输出凭据、设备标识、签名或原始响应，不使用第三方签名、云端账号任务、Windows计划任务，不改代理/驱动，不再另建单平台的重复调度。
正常完成、当天已完成跳过和失败/暂停均按上述实际结果汇报，不追加接口补齐报表。本轮新增与当天累计分开；复用快照保留原查询时间，不称新查询；小黑盒提交尝试数不等于成功奖励数。电脑须开机联网、当前用户登录、Codex运行且官方浏览器可用；20:00是计划时间，宿主唤醒可能延迟，不保证准点。此任务不应在GitHub Actions运行。
"@
Write-Output $prompt
