# 小黑盒有证据的修复恢复

正常入口：`LaunchDaily.ps1 -StateRoot <外部状态目录> -Scheduled`。
恢复入口在相同参数后增加 `-RecoveryId <ID>`；ID 为 1–64 个字母、数字、下划线或横线，首位必须是字母或数字。恢复仅能在当天北京时间 20:00 后，通过普通用户入口执行。

此适配器每轮只执行一次，不自行循环重试。使用者须先授权相应任务及修复恢复；仓库不包含某个账户的授权、登录状态或资源。修复负责人可继续诊断并取得新的证据，然后创建新的恢复许可。仅更换 ID、复制旧证据不能获得新一次提交。

## 保留原证据

原始 `logs/Daily-YYYYMMDD.json` 不覆盖。恢复使用 `logs/Daily-YYYYMMDD-recovery-ID.json`，通过排他创建记录占用一次尝试。已存在记录、互斥锁和当前暂停文件均阻止重复执行。

当前 `heybox-paused.txt` 表示待诊断；入口不会自动清除。负责人解释暂停原因、完成修复或取得真实的新状态依据后，将暂停文件原样归档到同一 `logs` 目录并核对 SHA256。用户主动暂停不属于自动故障恢复。

## 两份恢复文件

在外部状态目录的 `logs` 创建 `RepairEvidence-ID.json`，包含：

- `Status`: `ValidatedDiagnosis`
- `Diagnosis`: 实际查到的原因或新观察
- `Validation`: 实际完成的验证及支持的下一步

再创建 `RecoveryPermit-YYYYMMDD-ID.json`，包含：

- `Date`: 实际当天 `YYYY-MM-DD`；`RecoveryId`: 本轮 ID
- `Status`: `ReadyAfterDiagnosis`
- `PriorRecordFile`: 最近一次失败 Daily 的直接文件名；`PriorRecordSHA256`: 其 SHA256
- `RepairEvidenceFile`: 上述修复证据的直接文件名；`RepairEvidenceSHA256`: 其 SHA256
- `AllowedTasks`: 本轮获准项目键的非空列表，候选为 `sign`、`1`、`19`、`31`
- `AllowResubmitWaiting`: `true`
- 如归档了暂停：`ArchivedPauseFile` 和 `ArchivedPauseSHA256`

当天已经有记录时，许可必须绑定最新一次记录；没有当天记录时可绑定先前日期的故障作为原因证据，但只处理实际当天任务，不补历史。证据文件均须位于同一 `logs`，不得指向凭证或目录外文件。所有 SHA256 按文件原始字节计算。

## 每轮的实际行为

入口先读取当前任务清单。平台 `finish` 项目和当天任何先前记录已确认 `finish` 的项目都不再提交；仅对本轮 `AllowedTasks` 内、当前 `waiting` 且没有已完成证据的项目执行。状态从 `finish` 回退到 `waiting` 时记录 `PreviouslyConfirmedNoReplay`，交给负责人查因。

评价目标只取 `GameCommentsObj.links` 顶层、`appid=730`、`link_tag=3` 的评价，排除删除、私密、不可分享及本地曾提交但未确认的目标。选择依据保存在 `ShareTargets[31]`。三项分享只是本机模拟上报，无外发消息。

四项都 `finish` 且四项公示经验数额有效，才写 `ConfirmedDailyTasks`。四项都 `finish` 但奖励缺项时，后续恢复仅核对清单，不重新提交完成项目。任何失败停止当轮副作用并写安全暂停；负责人继续诊断，不能把 HTTP 200、退出码 0 或已提交当作奖励到账。

## 结果读取

`logs/last-invocation.json` 的 `RecordFile` 指向本次原始或恢复记录；必须校验同目录和当天日期。`Report-YYYYMMDD.json` 兼容统一汇报，含四行 `PublicTasks`、`PublicSummary`、空 `CoinDonations`，并保留原 `Tasks`、`Summary`、`Donations`。

`InvocationStatus` 区分本轮跳过、暂停与执行；`ActionsSubmittedThisInvocation` 是本轮已登记提交尝试的项目数，不能用于证明奖励到账。`NewObservation=false` 时，经验和资料来自标注了 `SummaryObservedAt` 的同日历史记录。`exp/max_exp` 是等级进度；升级天数为按当天四项奖励计算的离线估算。所有缺项保留未确认。
