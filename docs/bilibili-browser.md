# B站官方浏览器分享与本地确认

先按 [B站安装说明](bilibili.md) 安装修复构建并用本人账号登录。安装、浏览器绑定和平台每日任务分别验收。本文所有命令中的 `$bili` 是部署者自己的仓库外 B站状态目录，`$nonce` 必须来自本次 `Prepare`，不得照抄别人的记录。

## 绑定同一个账户

在已登录的官方个人中心和原生登录结果中实际核对账户一致。取得官方页面可见的本人个人空间链接，格式为 `https://space.bilibili.com/数字UID`。然后执行：

```powershell
$bili = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'
$profileUrl = Read-Host '粘贴已核对的本人官方个人空间链接'
& "$bili\Bind-BrowserProfile.ps1" -StateRoot $bili -ProfileUrl $profileUrl -AccountMatchConfirmed
```

该命令不请求平台，只把规范化链接的 SHA256 保存在本机运行清单中，不打印 UID 或链接。它不能代替实际账户核对。已有绑定只接受相同账户，不能用它覆盖另一账户的状态。账户、会话或安装需要迁移时保留原记录，单独处理，不删除尝试/暂停记录。

## 每日步骤

正常入口是 `scripts/Run-Daily.ps1 -ConfigPath <本机配置> -Scheduled`。协调器先调用本地 `Prepare`，只有本地结果要求浏览器操作时才按下列流程操作；B站等待浏览器期间小黑盒仍独立推进。完成浏览器确认后再调用同一协调器，已经完成的模块会跳过。

也可在已获授权的当天任务中直接获得本地准备结果：

```powershell
$prepared = & "$bili\BrowserShare.ps1" -Action Prepare | ConvertFrom-Json
```

`ReadyForBrowser` 才表示允许继续本次浏览器核对。保存返回的 `Nonce` 为 `$nonce`。`SkipCompleted`、`SkipAttempted`、`Paused`、`SkipBeforeTodaySchedule`、`BrowserAccountBindingRequired` 等结果不得被当成点击授权。不要重复 `Prepare` 来生成新尝试。`ReadyForNative` 表示已有合格浏览器证据；`ReadyForReadOnly` 只供有合法恢复许可的只读核对使用。

只在本人已登录的 [B站官方个人中心](https://account.bilibili.com/account/home) 查看当天任务与经验。重新核对可见账户与已绑定账户相同。未登录、账号不符、验证码、页面变化或奖励不明时走下文 `Fail`，不绕过验证。

### 页面已显示分享经验 5

不点击。保存一份由这次实际页面观察形成的 JSON 到 `$bili\Logs\BrowserShareReward-YYYYMMDD-<本次Nonce>.json`，字段如下。日期与时间均使用实际北京时间，时间包含 `+08:00`；账号哈希从本机运行清单读取并与实际可见链接重新计算的值核对一致。

| 字段 | 实际值要求 |
|---|---|
| Date | 当天 `YYYY-MM-DD` |
| Nonce | 本次 Prepare 返回值 |
| RecoveryId | 普通流程为空字符串；恢复时为同一许可 ID |
| Source | `OfficialAccountPageObservedByCodex` |
| AccountMatches | 真实核对后为布尔 `true` |
| ProfileLinkSHA256 | 本机已绑定且与当前可见链接一致的小写 SHA256 |
| ShareExperience | 页面实际显示的数字 `5` |
| SubmittedClicks | 数字 `0` |
| ObservedAt | Prepare 之后本次页面观察的实际时间 |

```powershell
$nonce = $prepared.Nonce
$evidenceName = 'BrowserShareReward-' + $prepared.Date.Replace('-','') + '-' + $nonce + '.json'
# 先把实际观察记录保存到 Logs 下的 $evidenceName，再执行确认。
& "$bili\BrowserShare.ps1" -Action ConfirmAlready -Nonce $nonce -RewardEvidenceFile $evidenceName
```

### 页面显示分享经验 0

先记录页面观察时间、分享经验 `0`、当前总经验及当前账户哈希。点击前必须声明这次唯一提交：

```powershell
& "$bili\BrowserShare.ps1" -Action ClaimSubmit -Nonce $nonce
```

只有返回 `ReadyForOneClick` 才能在官方页面操作一次授权的分享入口，不发送站外消息、不点赞、不额外投币。随后只观察官方页面是否从分享经验 `0` 变为 `5`。界面未确认时停止，不多点或盲目重发。保存相同命名的证据 JSON，共同字段沿用上表；用以下字段替代 `ShareExperience`：

| 字段 | 实际值要求 |
|---|---|
| BeforeShareExperience / AfterShareExperience | 数字 `0` / `5` |
| BeforeCurrentExperience / AfterCurrentExperience | 页面实际总经验；后值不得小于前值 |
| SubmittedClicks | 数字 `1` |
| BeforeObservedAt | Prepare 后、ClaimSubmit 前的实际观察时间 |
| ObservedAt | ClaimSubmit 后观察到奖励的实际时间 |

```powershell
& "$bili\BrowserShare.ps1" -Action ConfirmSubmitted -Nonce $nonce -RewardEvidenceFile $evidenceName
```

只接受同日、同次、同账户且时间顺序正确的证据。该版本以官方页面奖励变化验证分享，`ResponseBusinessCode` 保持空值，绝不把未看到的响应填为 `0`。证据文件、Nonce、账户哈希均只留在本机，不提交到 GitHub。

## 失败与恢复

```powershell
& "$bili\BrowserShare.ps1" -Action Fail -Nonce $nonce -Reason RewardUnconfirmed
```

支持的原因还有 `BrowserUnavailable`、`NotLoggedIn`、`AccountMismatch`、`PlatformRejected`、`UiChanged`、`LocalEvidenceUnconfirmed`。失败生成暂停记录，已确认动作与尝试证据保留。只读报告不能用来补跑任务或补查平台。

恢复必须先有部署者实际授权和新的诊断/修复证据。项目作者的连续恢复授权不属于其他使用者。新的许可位于 `Logs/Recovery-YYYYMMDD-<32位小写hex恢复ID>.json`，由 `Recovery.Common.ps1` 校验：同日 `Date`/`RecoveryId`/`CreatedAt`、`Status=AuthorizedRepair`、`PolicyVersion=ContinuousRepairV1`、非空 `RepairSummary`，以及原始尝试的 `OriginalAttemptSHA256`。若原始尝试不存在，值必须为 `Absent` 并提供同日 `SourceEvidenceFile` 与 `SourceEvidenceSHA256`。原始尝试、暂停和日志先归档保留，不能清空后重跑。

未知投币结果强制只读恢复；只有明确的同日平台流水、余额和当日累计共同证据才能使用许可中的 `CoinResolutions` 解决未知状态。恢复仍受当天最多 5 枚、余额和 Lv6 规则约束。只处理未完成事项，完成项永不重放。浏览器命令全程传相同 `-RecoveryId`，协调器用 `-BilibiliRecoveryId`；原生入口只接受 `Launch.ps1 -Mode Daily -Scheduled -RecoveryId`。每次恢复许可只能声明一次执行，不自动循环。

完整恢复校验与字段以 [Recovery.Common.ps1](../src/bilibili/Recovery.Common.ps1) 为准。没有合格许可时保持暂停并报告缺失条件。
