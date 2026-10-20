# 小黑盒：仓库外还需要什么

这是一份缺项清单，**不是通用获取器**。只有GitHub源码、手机扫码或USB会话不足以在新电脑运行小黑盒。缺项保持关闭，B站不依赖这些资源。

## 资源、格式与获取能力

| 输入 | 内容/格式 | 来源及限制 | 本仓库能做什么 |
| --- | --- | --- | --- |
| `-AppApk` | 官方 `com.max.xiaoheihe` APK，1.3.397，versionCode1138，含ARM64库 | 本人安装的兼容官方App公开base.apk或官方发行；官方滚动下载不保证仍有此版本 | 离线核对包名/版本/库哈希并提取；不放行新版、不强制降级 |
| `shader-code.bin` | 真实App初始化code经Base64解码的二进制，shader版本14 | 运行时材料，不在静态APK中；未Root手机通用导出方法、独立匿名获取流程均未验证 | 只导入本人已有真实文件；不能随机生成或复制作者缓存 |
| `report-material.properties` | App算法参数，两个Base64文本属性，见下文 | 本人同版本App的EncryptUtil/RSAUtil材料；没有一键提取器 | 读入参数；文件存在/非空不等于内容有效 |
| `report-public-key.der` | RSA公钥，X.509 SubjectPublicKeyInfo DER结构 | 本人兼容App的 `NDKTools.getrsakey` 对应材料；不是PEM文本、PKCS#1裸公钥或证书本体 | ReportBuilder以X509EncodedKeySpec解析；没有自动导出器 |
| `provenance.json` | ShaderVersion数值14，非空ResourceOrigin | 本人记录真实来源，不含账号/设备信息 | 检查声明；手写元数据不能证明其他文件真实 |
| 外部原生桥源码 | 上游固定提交 `b7cc58df7c4bd1527ad25a333985ea2a59c792e4` | [zhong08/heybox-checkin](https://github.com/zhong08/heybox-checkin) 的NativeSigner/JElf修复；无仓库级开源许可证，不随本项目发布 | 本人提供干净固定checkout，或本人明确选择 `-FetchUpstreamSource` 私有获取 |
| 本人Android会话/设备数据 | 导入器私有生成 `phone-session.json` | 同版本已登录官方App，唯一授权USB真机，Provider允许读取 | 资源安装后由Import-HeyboxPhone导入；不能替代shader |

**不是要求用户提供个人签名证书或私钥。** APK发布签名元数据来自官方APK；请求签名材料与Windows代码签名证书不是一回事。DER文件是公钥，不索取 `.pfx`、`.p12`、RSA私钥、密码或手抄Cookie，不生成自签名证书“修复”缺项。

没有已有资源、而是需要通用获取方法时，应如实停在资源阻塞；本仓库目前不能保证自动补齐。不能把“自行准备资源”包装成全自动方案，不能承诺连上手机就必定跑通。

## 文件组织与精确格式

示例目录在源码外，限制本人Windows用户和SYSTEM访问，绝不上传GitHub：

```text
C:\PersonalResources\
  heybox.apk
  heybox-runtime\
    shader-code.bin
    report-material.properties
    report-public-key.der
    provenance.json
```

`report-material.properties` 使用ASCII或UTF-8无BOM保存，每个Base64值保持单行。Java Properties.load(InputStream)不会忽略UTF-8 BOM；不要用Windows PowerShell 5.1的 `Set-Content -Encoding UTF8` 写这个文件。每个值为真实字符串的UTF-8字节再做Base64，不是整个文件做Base64。下面只展示形状，占位值不能用于安装：

```properties
aes_iv_b64=<本人同版本App真实IV的Base64>
aes_alphabet_b64=<本人同版本App真实字母表的Base64>
```

IV解码后的UTF-8字节须16字节；字母表解码后为95字符，用于生成16字符AES密钥。长度符合不代表真实兼容，禁止猜造。本地封装/解封装自检也不证明服务器接受；安装器当前只导入非空资源、编译并运行ELF检查，**不自动执行ReportBuilder自检**。

`provenance.json` 为UTF-8，最小结构：

```json
{"ShaderVersion":14,"ResourceOrigin":"本人兼容官方App的合法运行资源"}
```

不用另交两份`.so`；安装器从APK的 `lib/arm64-v8a/` 提取并核对：

| 文件 | SHA256 |
| --- | --- |
| libglesv3_1.so | `5ff6850b0b682418bf62be178acb481119be042a7297c1f3bdf47666dca86344` |
| libnative-lib.so | `5d8699f237ab12582f3d9b22c23c3edb91f9f65bca3ac1211c36e25fdb069489` |

这些哈希只绑定当前支持的二进制，不证明账号/初始化资源有效或服务器接受，不通过改常量放行其他版本。

## 已做到与未解决

- 已实现已有真实资源的离线导入、版本/库核验、私有依赖构建、官方允许的USB会话导入，以及本地每日流程和结果核对。
- 原机受支持组合曾有真实任务成功；公开适配版仅离线验证，不能推广为其他电脑/账号已经验收。
- 未解决任意未Root手机导出shader、新电脑无资源时自动初始化、iPad替代Android导入，以及其他App版本/Windows ARM引擎的兼容性。

离线研究观察到App从 `/account/getui/fix` 响应读取code/version初始化ShaderManager；初始化前签名/拦截器链尚未形成通用验证路径。这个事实不是可以直接请求该地址的步骤。不要试探/循环请求、绕过App权限、Root手机、安装模拟器驱动或接第三方签名站。

## 缺项时怎样交付

例如：“B站完成安装/登录验收；小黑盒缺本人版本14的shader初始化资源，目前无已验证通用获取方法，保持关闭。未请求小黑盒账号接口、未建立它的每日执行。”

列出真实缺少的文件名即可。若用户已有资源，只需本机路径，AI本机导入，不要求贴入聊天。安装成功不等于真实任务成功，不为核对缺项重复执行当天任务。完整依赖、命令和状态标准见[AI部署约定](ai-deployment.md)。
