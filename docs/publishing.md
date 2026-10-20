# Push 和发行

这个目录应成为独立仓库；不要把上层研究目录、已有安装或外部state目录作为仓库推送。

## 推送前

1. 阅读README中小黑盒的资源限制，保留默认关闭状态。
2. 运行 `scripts/Test-Publish.ps1`，确认源码、配置示例和Git历史均通过。
3. 查看 `git status`、`git diff --cached --stat`，只暂存本目录的公开源码。
4. 确认 `.gitignore` 生效；不要用 `git add -f` 加入私有资料。

尚未初始化时，可以在本目录执行：

```powershell
git init -b main
git add .
git commit -m "Prepare local daily check-in source release"
```

已有初始提交时不用再次初始化。提交身份使用发布者本人Git配置，不使用虚构身份。

如果Git尚未配置作者身份，先在这个仓库使用你自己的姓名及GitHub认可的提交邮箱配置 `git config user.name` 与 `git config user.email`，再提交。不要照抄别人的账号资料；使用GitHub隐私邮箱时以你自己的账号设置页面给出的地址为准。

在你自己的GitHub账号创建一个**空仓库**，然后使用它实际显示的地址：

```powershell
git remote add origin <YOUR_ACTUAL_GITHUB_REPOSITORY_URL>
git push -u origin main
```

这里的占位地址不是可直接运行的真实地址。本源码包不包含发布者的仓库地址、GitHub令牌、账号Secrets，也不会替别人创建远程仓库。

## Release

离线检查与实际干净电脑验收应分别记录。未完成另一设备验收前，发行说明应写“源码版/实验性小黑盒适配”，不能写“所有设备一键跑通”。

可以用 `git archive --format=zip --output=../local-daily-checkin-source.zip HEAD` 从已审查的提交生成源码包。勿打包整个工作目录。SHA256用于识别该压缩包，不代表账号流程已通过真实验收。

GitHub Actions只做源码离线检查；页面出现绿色状态不等于平台登录、分享、投币或奖励到账成功。

版本升级须保留各使用者自己的凭据与暂停记录。不要发布账号初始化缓存来解决安装问题。外部原生桥许可未明确前，不把其源码或产物作为Release附件。
