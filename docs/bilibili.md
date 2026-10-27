# B站本地适配器

本模块基于 [BiliBiliToolPro](https://github.com/RayWangQvQ/BiliBiliToolPro) 固定提交 `ed3ed2c50728022b02badf21c04b1573c495052e`，应用本仓库的 GPL 源码补丁后构建。修复版从登录 `nav.Money` 读取余额，记录投币提交意图和结果，并以官方浏览器奖励证据作为分享前置。

## 构建、安装与登录

当前构建目标是 Windows x64。需要 Git、.NET SDK **10.0.300**或符合上游 `rollForward=latestFeature` 的稳定10.0 SDK、Windows PowerShell 5.1 和 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)。SDK版本随固定上游 `global.json` 校验；自包含产物运行时不另需.NET。脚本不会静默安装系统工具、驱动或调度。

在仓库根目录，用普通用户运行，两个目标目录应在仓库外且为空：

```powershell
$build = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckinBuilds\bilibili-0.2.0'
$state = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'
pwsh -NoProfile -File .\scripts\Build-BilibiliNative.ps1 -OutputDirectory $build
pwsh -NoProfile -File .\scripts\Install-Bilibili.ps1 -StateRoot $state -NativeBuildDirectory $build
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $state -Mode Login
```

构建器校验固定提交及补丁哈希，先检查补丁能否应用，再运行合成原生回归测试并发布程序。构建清单记录源码、补丁、测试和文件哈希；安装器核对清单及实际文件，不接受任意EXE，也不能用未修复的官方4.2.1程序代替。自行构建的产物哈希用于识别本次结果，不是上游发布方的二进制签名。

已有匹配SDK、NuGet缓存和上游Git checkout时可使用：

```powershell
.\scripts\Build-BilibiliNative.ps1 -OutputDirectory $build -DotnetPath 'C:\BuildTools\dotnet\dotnet.exe' -PackageCache 'C:\BuildCaches\nuget' -UpstreamRepository 'C:\BuildSources\BiliBiliToolPro' -OfflineRestore
```

这些是路径示例。离线缓存缺依赖时构建失败，不假称通过。保留构建目录中的固定上游源码、补丁及许可证。安装器拒绝非空状态目录；升级前备份本人状态，并保留凭据、失败、暂停与当日尝试记录。

本人用手机哔哩哔哩App扫码确认。凭据保存在外部 `$state\app\cookies.json`；不需要提取或展示Cookie。模块以普通权限运行，安装时设置当前用户/SYSTEM访问权限。登录成功不代表每日奖励完成。

首次还须实际核对官方浏览器与原生登录的是同一账号，再按[官方浏览器分享步骤](bilibili-browser.md)建立本地绑定。绑定只保存个人空间链接的本地哈希，不是平台验证。

## 执行与暂停

合并入口是正常执行路径：

```powershell
.\scripts\Run-Daily.ps1 -Scheduled
# 仅整理已有当日报告，不请求平台
.\scripts\Run-Daily.ps1 -ReportOnly
```

根入口先调用本地 `BrowserShare.ps1 -Action Prepare`。`ReadyForBrowser` 表示等待官方页面核对/分享，期间小黑盒独立执行。完成文档中的奖励确认并得到 `ReadyForNative` 后，再次调用根入口继续B站；完成的小黑盒会跳过。原生入口不会代替浏览器补发分享。有效恢复许可的 `ReadyForReadOnly` 只允许原生只读核对，不提交任务。

官方页面分享奖励已完成时记录实际观察，不再点击；未完成时先保存一次提交标记，最多点击一次，再核对真实奖励变化。页面、账号、回执或奖励不明确就暂停。不要直接调用网页私有接口或用默认成功码填空，详见[证据格式](bilibili-browser.md)。

`StateRoot\daily-paused.txt` 是持久暂停开关，存在时不请求平台。菜单不会直接清除暂停。必须先完成诊断、保留原证据并取得适用的恢复授权；验证码、登录失效等本人操作仍由本人处理。模块本身不创建Windows任务或常驻服务。

## 每日规则与恢复

- 仅登录、观看、每日分享、视频投币；单账号。点赞、关注取关、评论、弹幕、漫画、抽奖、大会员、充电和付费操作关闭。
- 当日总目标5枚，平台奖励进度包含已计入的手动部分。原生持久化每次投币意图、确认或拒绝，恢复时继承当日已确认下限，不因奖励延迟再补第6枚。余额保留0，不充值；Lv6停止升级投币。
- 不要并发手动投币或运行另一套工具；本地锁和日志不能为所有客户端提供平台级原子额度锁。
- 保留POST最少20秒间隔；完成当天就本地跳过。20:00前不做当天任务，迟到只处理实际执行当天，不补历史。
- 已尝试而结果不明时不自动重发。恢复使用 `-Scheduled -BilibiliRecoveryId <32位小写十六进制ID>`；它不是绕过暂停的开关。

恢复许可绑定当天日期、一次性ID、原始attempt或来源证据哈希及修复说明，遵循 `Recovery.Common.ps1` 的 `AuthorizedRepair/ContinuousRepairV1` 契约。许可中的文字不能替代本人实际授权。发布者原机的持续修复授权不自动适用于其他使用者。

未知投币结果会强制只读核对。只有真实平台明细、余额和当日总量支持的确认/拒绝证据才能解除未知状态；不删除attempt、投币journal或旧失败，不复用已消耗许可。任何恢复仍受同一个当日5币上限约束。

## 日报与证据口径

`StateRoot\Logs\Report-YYYYMMDD.json` 提供登录、观看、分享、投币四项。七项汇总为登录奖励硬币、今日经验、等级经验、距Lv6经验、考虑有限余额的升级天数估算、余额、日志及观察时间。投币去向简写为“UP主｜视频简写｜枚数”。

本轮新增投币数来自匹配本轮证据，当天累计来自平台当日奖励状态，两者不可相加。`-ReportOnly` 的新增数为0；失败后复用旧快照不能确认本轮副作用时写未知。小黑盒提交尝试数也不代表奖励成功数。

`SummarySource=CurrentRun` 需要日志与本轮匹配；`LastConfirmedToday` 保留原始 `SummaryObservedAt`，不能标成新查询。缺字段为未确认，退出码0不是完成证明。汇总程序只进行规定的有限读取，不为补表再次执行任务或追加循环查询。

今日经验是平台当天奖励，不把多次登录提示重复相加。登录赠币需实际收支证据，未查到为未确认。当天投币明细可能含手动操作，不把来源不明的明细冒称本工具新增。升级天数基于当前余额、每日登录所得及之后每日任务都完成的假设，是估算。

## 验证与来源

发布验证只运行源码、合成数据和原生回归测试，不为打包运行平台业务。构建或离线检查通过不等于其他账号/电脑已经端到端验收。

```powershell
.\scripts\Test-Publish.ps1
```

补丁及原生测试位于 `src/bilibili/patches`，保留GPL上游归属；构建器取得固定上游源，二进制不随公开源码发布。说明和边界见[验证文档](validation.md)与[第三方声明](../THIRD_PARTY_NOTICES.md)。账号、浏览器绑定、Nonce、恢复许可和运行记录只留在本人外部状态目录，不上传GitHub。
