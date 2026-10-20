# B站本地适配器

此模块包装 [BiliBiliToolPro](https://github.com/RayWangQvQ/BiliBiliToolPro)，不重新实现投币接口、不包含任何用户的登录数据。默认固定官方稳定版 [4.2.1](https://github.com/RayWangQvQ/BiliBiliToolPro/releases/tag/4.2.1)，发布版本对应 `ed3ed2c`。第三方程序不会以管理员运行。

## 安装与首次登录

需要 Windows 10/11、Windows PowerShell 5.1 和 [Microsoft PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)。安装器识别 Windows x64/x86/ARM64，下载对应官方自包含 ZIP，因此 BiliBiliToolPro 不需要额外安装 .NET 运行时。脚本不会静默安装系统依赖、驱动或创建 Windows 计划任务。

在仓库根目录，用普通用户运行：

```powershell
$state = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'
pwsh -NoProfile -File .\scripts\Install-Bilibili.ps1 -StateRoot $state
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $state -Mode Login
```

使用**手机哔哩哔哩 App** 扫描电脑窗口的二维码并确认。二维码只显示于本机，临时图片会随窗口关闭删除。凭据由原生工具保存在 `$state\app\cookies.json`，无需提取或粘贴 Cookie。新建状态目录的权限限定为当前 Windows 用户与 SYSTEM，子文件继承此权限。它不是加密保险箱；具备本机管理权限的人仍可能取得文件。

安装器只从 GitHub 官方 Releases 下载；优先核对 GitHub 资产 `digest` 的发布方 SHA256。4.2.1 另内置当天核实的 x64/x86/ARM64 资产 SHA256，在元数据未提供 digest 时作为固定版本校验。没有发布方可用校验值的新版本会停止安装，不把自行计算哈希冒称来源校验。当前发布方元数据接口可能受本机网络影响，脚本不会修改系统代理或自动重试。

程序、日志和凭据均放在仓库外的 `StateRoot`。安装器遇到已有 `app` 时停止，不覆盖已有账号配置；升级须先备份自己的状态目录并核对新版行为。代码没有自动升级程序。

## 执行、查看与暂停

```powershell
# 手动立即执行一次
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $state -Mode Daily
# Codex 每天20:00和迟到补做统一使用这个入口
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $state -Mode Daily -Scheduled
# 本地菜单：查看记录、重新登录、暂停/恢复、立即运行
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $state -Mode Menu
```

运行依赖当前 Windows 用户保持登录、电脑开机联网；Codex 调度时还需要 Codex 可以执行本机任务。此模块本身不创建任何计划任务或常驻服务。普通权限启动若被系统拒绝，会报错退出，不提升权限或绕过审批。

`StateRoot\daily-paused.txt` 是持久暂停开关，存在时 Daily 不请求平台。菜单恢复只是解除本机暂停，不会替你打开 Codex 的暂停调度。先处理明确提示的失效登录、验证码或接口问题，再恢复。菜单不会清理历史记录。

## 每日规则

- 只运行登录、观看、每日分享、投硬币；单账号。点赞、专栏投币、关注/取关、漫画、抽奖、大会员、兑换、充电和付费操作关闭；不接第三方通知。
- 每天目标5枚，原生程序先查平台当天计入的投币经验并扣除已完成数量，包含手动部分；已投满5枚直接跳过。余额保留0，不充值，余额不足按原生逻辑减少或跳过。Lv6停止升级投币，登录观看分享仍保留。
- 保留 POST 请求至少20秒间隔。适配器不为失败自动重跑 Daily；平台拒绝、验证码、-352或登录失效出现时，停止进程并保留暂停标记。上游原生程序本身的视频候选选择流程保持原样，不能宣称完全没有内部候选检查。
- 单个 Windows 用户会话中用互斥锁防并行。当日安全汇总已确认全部完成时，离线跳过，既不启动工具也不发平台查询。否则最多启动一次原生 Daily，由其继续检查当天状态。
- `-Scheduled` 在20:00后只处理实际当天；19:55–20:00可等待到20:00；更早的旧触发直接跳过，不提前做当天、不循环补历史。
- 当天“累计最多5枚”依赖平台当天投币奖励进度及原生余额检查。请勿同时开另一套自动脚本或在其执行期间手动投币：平台接口不提供跨客户端的原子额度锁，脚本无法为并发人工操作提供绝对上限保证。

模块不会修改系统代理和 ViewTurbo。运行时仅在子进程中清理会覆盖任务安全选项的 BiliBiliToolPro 环境变量；不修改系统/用户环境变量。安装器替换新解压程序的默认任务/日志模板，避免上游默认启用额外任务和原始文件日志。

## 日报与证据口径

`StateRoot\Logs\Report-YYYYMMDD.json` 是主汇总可消费的安全报告；`PublicTasks` 含登录、观看、分享、投币四项；`PublicSummary` 含登录奖励硬币、今日经验、当前等级经验、距Lv6经验、考虑余额的估计天数、余额、运行记录七项。`CoinDonations` 为“UP主名｜视频简写｜枚数”。

正常 Daily 结束后，`Experience.ps1` 只读查询账号经验、当天奖励、硬币收支各一次；复用收支结果查登录奖励与投币去向。每个公开视频最多一次、总计最多5次匿名查询 UP/标题，不携带登录凭据、不分页、不重试。汇总失败不会追加投币，不会再运行每日任务。

今日经验以平台当天奖励状态为准，包含手动和工具完成的部分；不逐次相加“登录经验+5”提示。登录赠送1币必须从当天奖励收支确认，未查到只能写未确认。投币新增数来自成功业务日志，当天累计来自奖励状态；当天支出明细可能含手动投币，不靠相似标题强行归因。升级天数按登录5、观看5、分享5、投币每枚10、每日登录获得1币及当前余额估计，不是保证日期。

`SummarySource=CurrentRun` 表示匹配本次日志且汇总在完成后生成；`LastConfirmedToday` 只能作为注明 `SummaryObservedAt` 的当日上次确认值；缺失为未确认。退出码0不等于四项成功。运行日志只持久化筛选后的业务消息，不持久化请求、响应、Cookie、token、二维码内容或账号标识。不要将整个状态目录上传 GitHub，即使它被称为“日志”。

## 验证与来源

本公开适配版本做了脚本解析、配置策略、模拟日期、防重复、预测与脱敏报告测试；**没有为打包而运行真实平台任务，也没有在其他用户的账号/电脑实测**。原机实际运行经验不等于通用安装包验收，接口规则改变后可能失效。

离线检查：

```powershell
pwsh -NoProfile -File .\src\bilibili\Test-Offline.ps1
```

官方主程序按其 [GPL v3 许可证](https://github.com/RayWangQvQ/BiliBiliToolPro/blob/main/LICENSE)单独下载，未将二进制、原始程序源码或个人账号内容包含在本仓库。这里的 PowerShell 启动/汇总适配从本项目原有本机脚本泛化，相关配置项和运行方式依据上游4.2.1文档及源码核对。新版本的签名、配置和接口行为应重新验证。
