# Bilibili 原生源码补丁

基线为 [BiliBiliToolPro](https://github.com/RayWangQvQ/BiliBiliToolPro) 的固定提交 `ed3ed2c50728022b02badf21c04b1573c495052e`，沿用 GPL-3.0-only。补丁由本项目维护，包含受控每日入口、官方浏览器分享前置条件、nav.Money 余额读取、跨尝试投币记账及离线回归测试。没有分发上游预编译程序、账号配置或个人状态。

`upstream.json` 固定提交、SDK基线、补丁哈希及构建版本。仓库外空目录运行 `scripts/Build-BilibiliNative.ps1`，按上游 global.json 的 10.0.300 / latestFeature 规则使用稳定 10.0 SDK，依次检出固定源码、校验及应用补丁、运行合成测试，再生成 Windows x64 自包含程序与 `native-build.json`。后者的哈希识别本机构建产物，不是上游发布方二进制摘要。安装器只接受相符的构建证据，不再安装未经补丁修复的官方旧程序。

构建不启动平台任务。离线恢复需要部署者自己完整的 NuGet 包缓存；SDK、包缓存、构建目录和二进制都不提交到公开仓库。新电脑的真实登录、奖励到账和浏览器账号匹配仍需各部署者单独验收。
