# AI 本地部署操作约定

让接手的AI明确“仓库有什么、电脑缺什么、谁能补齐、何时必须停止”。不能把源码下载或文件安装当作部署成功。

**B站具备完整安装/登录/运行入口；小黑盒只适合已经拥有本人兼容资源者，目前没有新用户通用资源获取流程。两者均未在另一位用户电脑完成端到端验收。**

## 1. 先确认环境和授权

先确认用户要哪些模块，是否授权真实账号任务（B站消费虚拟硬币，小黑盒提交签到及三项模拟分享事件），是否要求调度。已有明确授权直接沿用。只读准备不触发平台请求，不索取Cookie/设备标识。

在普通用户Windows PowerShell、仓库根目录检查：

```powershell
[Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$PSVersionTable.PSVersion
[TimeZoneInfo]::Local.BaseUtcOffset
Get-Command pwsh.exe -ErrorAction SilentlyContinue
# 以下仅在准备小黑盒时需要；缺工具会报错，先准备再继续
python.exe --version
java.exe -version
javac.exe -version
mvn.cmd -version
git.exe --version
```

不要打印全量环境变量或私人文件。Python应为3.12；Java/javac同为JDK17，Maven也使用该JDK。同名命令存在不代表版本正确。安装器以解析到的 `java.exe` 旁边的 `javac.exe` 为准；应让当前进程PATH优先指向真实JDK17的bin，不能只指向Java启动shim目录。

| 仓库外条件 | B站 | 小黑盒 | 获取/检查责任 |
| --- | --- | --- | --- |
| Windows普通用户 | x64/x86/ARM64安装资产 | 仅Windows x64验证 | AI检查，不以管理员跑账号程序 |
| Windows PowerShell 5.1 | 必需启动入口 | 必需启动入口 | Windows自带；安全策略拒绝由本人处理，不放宽系统策略 |
| PowerShell 7稳定版 | 必需经验汇总 | 可用于根入口和检查 | AI按[Microsoft说明](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)在授权内准备；不代替5.1 |
| Python 3.12 x64，含venv/pip | 完整离线检查需要 | 必需，已验证组合 | [Python官方Windows发布](https://www.python.org/downloads/windows/)；安装器未强制版本，不代表其他版本已兼容 |
| JDK17 x64，含javac | 不需要 | 必需 | 如[Temurin官方17发行](https://adoptium.net/temurin/releases/?version=17)；不是JRE或其他大版本 |
| Maven 3.x、Git | Git用于源码获取/发布 | 必需 | [Apache安装说明](https://maven.apache.org/install.html)、[Git for Windows](https://git-scm.com/downloads/win)；安装器不代装 |
| 本人手机App | 手机哔哩哔哩扫码 | 已登录兼容安卓官方小黑盒 | 本人扫码/授权；iPad不能替代Android导入 |
| Android Platform-Tools | 不需要 | 首次会话导入必需 | [Google官方入口](https://developer.android.com/tools/releases/platform-tools)；唯一USB真机、本人允许USB调试 |
| 本人APK、4份资源、外部源码 | 不需要 | 缺一不可，仓库不带 | 见[资源清单](heybox-resources.md)；缺失就停小黑盒 |
| UTC+08、本机20:00 | 每日执行要求 | 每日执行要求 | AI检查，不自动改系统时区；其他时区目前不支持 |
| Codex本机自动化能力 | 仅定时需要 | 仅定时需要 | 开机联网、用户登录、Codex运行；不需要手机一直连接 |

依赖获取会访问官方发行站、GitHub、Python包源和Maven Central；安装下载联网与账号接口请求是不同阶段。优先复用工具，可使用便携版与仅本进程PATH。网络问题不修改系统代理，不改用第三方签名/代挂，不安装模拟器或加速驱动。

## 2. 建立配置，不覆盖旧数据

先检查现有 `config.local.json`、模块状态目录和相关调度。默认外部状态根 `%LOCALAPPDATA%\LocalDailyCheckin`，子目录为 `bilibili`、`heybox`、`reports`。禁止放进checkout或使用磁盘根。

没有本地配置时执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Setup.ps1
```

Setup只创建配置和状态父目录，不安装依赖/程序、不登录、不创建调度。配置已存在不要覆盖。自定义路径后，所有模块命令的 `-StateRoot` 须使用对应子目录；根入口使用同一 `-ConfigPath`。

安装器保护旧数据。遇非空模块目录或失败半成品，先查安全错误、保留文件；不要清空后盲重跑。确需新目录时保留旧目录、核对配置，避免丢凭据或再次触发当天任务。

## 3. 部署B站

前提：PowerShell7可用，普通用户，模块目录无已有安装。默认路径：

```powershell
$biliState = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'
pwsh.exe -NoProfile -File .\scripts\Install-Bilibili.ps1 -StateRoot $biliState
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\src\bilibili\Launch.ps1 -StateRoot $biliState -Mode Login
```

安装器固定BiliBiliToolPro **4.2.1**，从官方Release选本机自包含资产并校验发布方SHA256，无需额外.NET。配置中的 `bilibili.version` 只记录版本；改字段不会升级程序，不要为追新随意换 `-Version`。

本人用手机哔哩哔哩App扫电脑二维码。AI只看过滤登录结果，不读取/展示Cookie。扫码或退出码0不代表每日任务完成；失效/验证码/风控保留暂停，不反复尝试。详细行为见[bilibili.md](bilibili.md)。

## 4. 小黑盒先过资源门槛

先核对[资源清单](heybox-resources.md)：本人官方APK **1.3.397/build1138**，版本14真实shader、算法参数、公钥及来源文件，和本人有权本地使用的固定提交源码。缺任何一项都写 `BLOCKED_HEYBOX_RESOURCES`，保持 `heybox.enabled=false`，继续独立交付B站。

**未Root手机通用导出shader的方法尚未验证。** 扫码、USB会话、静态APK、手写provenance或生成密钥都不能代替。明确说明缺什么及目前无法自动取得的环节，不能只让用户“自行找证书”。

资源、工具链真实具备时安装；路径仅为示例：

```powershell
$heyState = Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\heybox'
.\scripts\Install-Heybox.ps1 -StateRoot $heyState -AppApk 'C:\PersonalResources\heybox.apk' -ResourceDirectory 'C:\PersonalResources\heybox-runtime' -UpstreamSourceDirectory 'C:\PersonalSources\heybox-checkin'
# 仅本人明确选择获取外部未许可源码时，用 -FetchUpstreamSource 替代 -UpstreamSourceDirectory
```

上游固定提交 `b7cc58df7c4bd1527ad25a333985ea2a59c792e4`；本项目GPL不替其授权。安装器建私有venv、装固定Python依赖、离线导入APK资源、取得Maven依赖并编译桥。它不代装Python/JDK/ADB，不执行App账号接口；只做编译和ELF检查，未执行ReportBuilder自检。**存在文件或导入成功不证明资源格式、签名或服务器接受。**

本人同版本已登录安卓真机允许USB调试后：

```powershell
.\scripts\Import-HeyboxPhone.ps1 -StateRoot $heyState -AdbPath 'C:\Android\platform-tools\adb.exe'
```

导入器用独立端口5039，只读官方允许导出的Provider，凭据直接落私有目录。不手工运行并打印原始Provider输出。不支持 `-Force`，默认拒绝覆盖已有会话。无授权/Provider被拒/App版本不匹配就停止，不Root、不改权限、不强制降级。成功后手机可断开。

准备完成且获准真实任务后，只修改本机配置 `heybox.enabled=true`，保留其他配置。三项分享是模拟完成事件，不外发联系人消息。详见[heybox.md](heybox.md)。

## 5. 真实验收一次，再建立所需调度

已获账号任务授权时，手动运行一次根入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Run-Daily.ps1
```

不要先分别跑模块再跑合并入口，不为展示重跑任务。当天完成跳过，已经尝试但结果不明不重发。读取外部 `reports\Combined-YYYYMMDD.json` / `.md`，核对实际日期/观察时间及当前调用。任务/奖励各看真实业务证据；上次确认值注明时间，缺项写未确认。失败保留暂停，不另跑Report或直接请求接口补报表。B站运行时不要同时手动投币/另开工具，原生检查没有跨客户端原子额度锁。

用户要求每日调度时：

```powershell
.\scripts\New-CodexPrompt.ps1
```

该脚本只输出本机专用文字。AI再使用所在Codex支持的自动化工具创建一个本地20:00合并任务，核对名称、时区、ACTIVE及命令含 `-Scheduled`。缺自动化工具就报告 `SCHEDULE_NOT_CREATED`，不编辑Codex内部文件、不改用Windows任务。相关旧调度只按本次授权处理，不删除无关任务。

## 6. 状态与完成标准

以下为AI报告用的文档标签，**不是脚本已实现的返回码**：

| 标签 | 实际含义/下一步 |
| --- | --- |
| `BLOCKED_ENVIRONMENT` | 写明确切工具/版本缺项；仅在授权内准备官方依赖 |
| `BLOCKED_HEYBOX_RESOURCES` | 写缺少文件/合法源码；小黑盒关闭，不伪造、不试接口，B站可独立完成 |
| `INSTALLED_NOT_VERIFIED` | 安装/构建通过，真实任务尚未验收；不能先宣称签到成功或开未验收模块的定时 |
| `WAITING_USER` | 写出本人需要扫码/USB授权/审批的窗口和具体动作 |
| `PAUSED` | 平台拒绝、失效或暂停文件；停止受影响操作，不重试，原因不明写未确认 |
| `VERIFIED_TODAY` | 本人当日业务已确认项目；分别列成功/跳过/失败，不保证未来 |
| `SCHEDULE_NOT_CREATED` | 没有可核对的实际调度；不冒称后台安排完成 |
| `SCHEDULE_ACTIVE` | 实际启用已核对；告知开机联网、用户登录及Codex运行条件 |

最终简报写：各模块启用/阻塞原因、安装路径与版本、真实验收结果/缺项、调度是否确实存在、本人还需做什么。只有B站跑通时应说“B站完成，小黑盒因缺X关闭”，不能说“双平台完成”。不上传私有状态或完整日志。发布前运行[离线检查](validation.md)，其结果不能代替真实验收。
