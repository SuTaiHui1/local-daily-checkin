# 小黑盒模块：本地运行，资源准备有前提

本模块只做签到和三项**模拟分享完成上报**（帖子、游戏详情、游戏评价）。不会真正发给微信联系人，不发帖、不写评价、不领取其他任务、不接第三方签名服务。

部署前先读[AI部署顺序](ai-deployment.md)及[外部资源精确清单](heybox-resources.md)。后者区分APK、运行时shader、算法参数、公钥和本人会话，说明格式与获取限制；不是让用户提交个人签名证书或私钥。缺少资源时保持关闭，不把USB导入成功当成所有资源已齐。

## 已验证范围与公开版限制

原部署在 Windows、Python 3.12、JDK 17、Unidbg 0.9.9、官方 Android App **1.3.397 / build 1138**、初始化版本 **14** 上，曾由真实平台任务清单确认四项完成。这个结果不能证明其他设备、账号或新版 App 兼容。公开源码重新整理后只做离线检查，发布过程中不会重跑真实任务。

**全新电脑目前不能一键取得全部签名资源，因此默认 `heybox.enabled=false`。** 已登录且授权 USB 调试的未 Root 安卓手机能提供会话；但官方 Provider 不公开 `gles30` 初始化缓存。APK 里只有原生库，没有这个运行时数据。不能把作者的缓存、设备身份或会话当通用文件发给别人。

已离线确认官方 App 从 `/account/getui/fix` 响应取 `code`（Base64）与 `version`，解码后初始化 ShaderManager 并写入 MMKV 的 `gles30local_vertex`、`gles30local_matrix`。但该请求的初始化前签名/拦截器链没有完成通用验证，不能称为匿名下载接口，本仓库也不会试探它。没有建立未 Root 手机普通权限下导出这个缓存的可靠自动方法。缺资源时安装脚本会在下载依赖或请求平台之前停止；不要为此 Root 手机、绕过 App 权限或关闭系统安全功能。

## 可复现的个人本地准备

适合**已经合法拥有自己兼容运行资源**的使用者。不是让新用户提取 Cookie；会话通过官方导出的 Provider 读取，只留在本人 Windows 用户的私有目录。

所需环境：Windows x64、Python 3.12、JDK **17**（不是 JRE 或较新 JDK）、Maven、Git；首次导入另需 Google 官方 [Platform-Tools](https://developer.android.com/tools/releases/platform-tools)。安装脚本不安装驱动、不改代理、不重启任何软件。操作时使用普通用户窗口。

1. 准备本人官方 App APK。可从本人已安装手机取得公开 `base.apk`，或从[小黑盒官方网站](https://www.xiaoheihe.cn/)的官方下载入口取得；必须是当前受支持版本。曾核对官方入口为 `https://dl.max-c.com/app/heybox/heybox-release.apk`，这个地址会滚动更新，不能因此放行新版本。离线导入检查 APK 包名、版本与两份 ARM64 原生库 SHA256；不下载或运行未知修改版。
2. 准备 repo **外**的个人资源目录，含 `shader-code.bin`（本人 App 初始化数据，已经 Base64 解码的字节）、`report-material.properties`（App AES IV/字母表等算法参数）、`report-public-key.der`（App 返回的 RSA 公钥），以及下面的 `provenance.json`。这三份文件不会由公共仓库提供。算法参数来自本人同版本 App 的 `EncryptUtil` / `RSAUtil`，公钥来自本地 `NDKTools.getrsakey`；本仓库不把这些已有资源冒称为自动获取。示例仅表示元数据形状，不能生成缺失的真实资源：

   ```json
   {"ShaderVersion":14,"ResourceOrigin":"本人兼容官方 App 的合法运行资源"}
   ```

3. 原生桥仍使用 [zhong08/heybox-checkin](https://github.com/zhong08/heybox-checkin) 的固定提交 `b7cc58df7c4bd1527ad25a333985ea2a59c792e4`。**该仓库没有仓库级开源许可证，公开包未复制其源码；本项目 GPL 不替它授权。** 可提供自己 repo 外的固定提交 checkout；若自行确认适用于个人本地使用，也可显式让安装脚本获取到私有目录：

   ```powershell
   .\scripts\Install-Heybox.ps1 -AppApk 'C:\PersonalResources\heybox.apk' -ResourceDirectory 'C:\PersonalResources\heybox-runtime' -FetchUpstreamSource
   ```

   若已经有合适源码，用 `-UpstreamSourceDirectory 'C:\PersonalSources\heybox-checkin'` 代替 `-FetchUpstreamSource`。脚本仅编译其 `NativeSigner` 和带许可证的 JElf 修复，依赖从 Maven Central 取得；不运行其签到、Docker、通知、轮询或 cron。外部未许可源码不随本包重新发布。

4. 用本人官方 App 登录，连接 USB、打开 USB 调试并在手机授权电脑，然后运行：

   ```powershell
   .\scripts\Import-HeyboxPhone.ps1 -AdbPath 'C:\Android\platform-tools\adb.exe'
   ```

   只用独立 ADB 端口 5039，选择唯一 USB 真机；读官方导出的 `content://com.max.xiaoheihe.statusprovider/login`。如系统拒绝、无导出 Provider 或 App 版本不符则停止，不改权限、不 Root、不强行安装旧 App。需要更新会话时先在私有目录备份旧凭据；默认拒绝覆盖已有文件。成功后可断开手机，凭据失效才需重新导入。

5. 配置 `heybox.enabled=true`，并在首次本机人工检查时运行根入口或本模块入口。开启即表示本人选择**模拟分享完成事件上报**，不外发消息。接口接受、平台实际任务完成和经验汇总分别判断；平台拒绝或协议改变时停止，不能保证长期有效。

所有命令可添加 `-StateRoot 'D:\YourPrivateState\heybox'`，应与根配置展开后的 `stateRoot\heybox` 一致。默认 `%LOCALAPPDATA%\LocalDailyCheckin\heybox`，禁止把私有状态放在源码 repo 内。

## 每日执行与记录

根调度调用：

```powershell
.\src\heybox\LaunchDaily.ps1 -StateRoot "$env:LOCALAPPDATA\LocalDailyCheckin\heybox" -Scheduled
```

只在当前本地日期20:00后处理当天；电脑时区须为北京时间 UTC+08。当天成功直接跳过，已经尝试但中断也不自动再次提交；跨日只处理新日期。先查平台当日状态，仅提交未完成项。互斥锁阻止多实例。每个阶段只调用一次，不自动重试、不轮询，不运行其他平台任务。

遇异常会保留 `heybox-paused.txt`，后续不请求平台。先查明并处理原因，再按[恢复契约](../src/heybox/RECOVERY-CONTRACT.md)记录本人授权、旧记录/暂停/修复证据哈希和一次性RecoveryId。根入口用 `-Scheduled -HeyboxRecoveryId <ID>`，只处理许可内未完成项；不要直接删暂停标记反复尝试。脚本拒绝管理员权限执行，也不会创建 Windows 计划任务。

日报读取外部 `logs\Report-YYYYMMDD.json`，原始过滤业务结论在 `logs\Daily-YYYYMMDD.json`；`-Status` 只读本地记录，不查询平台。`RecordFile` 只接受本地同一logs目录、同一天的原始或恢复记录。`ActionsSubmittedThisInvocation` 表示本轮提交尝试，不能当作奖励成功数；复用快照使用原 `SummaryObservedAt`。包含各任务结果、当天任务经验、当前等级/经验进度、距下一级经验、按当天实际奖励估算的升级天数、H币余额、签到奖励和连续签到天数。缺字段写未确认，旧快照须标注时间；不是全账号净经验变化，不许用上一次数据冒充新查询。

## 0.2.0 目标选择修复

游戏评价分享仅从 `GameCommentsObj.links` 顶层选择 `appid=730`、`link_tag=3` 且可分享的当期目标，拒绝删除、私密、不可分享或历史未经确认的目标。完成标志与实际奖励分别判断；首次失败及已完成项在恢复过程中保留，已完成项不重复提交。

## 来源与授权

- 本目录 Python 胶水、`PhoneNativeRunner.java`、`ReportBuilder.java` 为本地适配源码；上游未许可的 `NativeSigner` 不包含在本 repo。
- 外部原生桥来源与固定提交见上；Unidbg 0.9.9 为 [Apache-2.0](https://github.com/zhkl0228/unidbg)，JElf 为 [MIT](https://github.com/fornwall/jelf)，相应声明留在外部源码/依赖中。Requests 为 Apache-2.0，Androguard 为 Apache-2.0。
- 小黑盒 APK、`.so`、初始化资源与官方协议均属各自权利人；本仓库许可证不授权再分发这些文件。仅在本人有权的环境使用。
- Android [Provider 权限](https://developer.android.com/guide/topics/manifest/provider-element)决定会话读取是否允许；不能因旧版允许就绕过新版限制。
