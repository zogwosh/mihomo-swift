# 配置、状态与恢复设计

## 组件

`MihomoApp`：中文 SwiftUI、菜单栏和唯一 AppModel。`MihomoCore`：Profile、副本资源、状态事务、Controller、下载验证、系统代理。`MihomoHelper`：已签名的 root XPC 服务；开发包另用该程序的无特权看护模式。`HelperIPC`：固定、受限的 XPC 接口和代码签名身份。

开发包没有提权后门。正式包通过 SMAppService.daemon 注册；客户端和服务端均用 NSXPCConnection.setCodeSigningRequirement 要求相同 Team ID 和固定签名标识。无 Team ID 的包不能启动 root Helper。不提供 shell、任意参数或任意可执行文件路径接口。

## 原文与白名单

Profile 使用稳定 UUID。原 YAML 保存成不可变 `profiles/<UUID>.yaml`，节点选择和订阅地址写在私有 state.json，原文不被控制操作修改。

| 字段 | 原因 |
| --- | --- |
| mode | 全局代理模式 |
| tun.enable | 三种互斥网络模式；其他 tun 字段保留 |
| external-controller、secret | 127.0.0.1:19090 和私有随机认证密钥 |
| external-controller-tls / unix / pipe | 删除额外控制入口，确保只有应用控制的认证入口 |
| mixed-port、allow-lan、bind-address | 仅 System Proxy 模式覆盖为 17890 / false / 127.0.0.1 |
| profile.store-selected | false，防止内核全局缓存造成 Profile 之间的选择串用；App 自行恢复各组记录 |
| proxy-providers.*.path、rule-providers.*.path | 复制相对资源后重定位到隔离目录，保持资源内容及行为，避免切换 -d 或改变原 YAML |

不覆盖 DNS、规则、代理定义、组类型或健康检查。文件型 provider 导入时复制；HTTP provider 缓存路径按 Profile 隔离。禁止绝对 / 越界资源路径和独立 TUN listener，明确报不兼容。顶层 geodata 自定义本地路径等未支持资源形式可能被内核预验证拒绝；不能静默改写为其他资源。

## 提交点

原文、候选运行 YAML 和下载内核均使用独立文件名。每个运行操作先记录旧 state.json 到 transaction.json，随后验证和加载候选，回读模式、组成员和有效选择，再用同目录临时文件 + fsync + rename 原子提交 state.json。它是唯一提交点。状态文件成功提交前，候选文件不能代替旧文件；提交后遗留的 journal 不推翻已经提交的 state.json。

失败始终补偿到上次提交的 Profile 和模式，即使 PUT 超时也重新加载旧配置并回读。补偿失败停止受管理内核并尝试恢复系统代理，保留 journal 和用户意图，显示不可用状态。UI 以实际 running 状态区分保存偏好与当前是否接管。

新节点选择先 PUT，再 GET 回读，成功才保存。失败恢复原选择；自动组原来未固定时用 DELETE 清除临时 fixed，避免将自动组意外固定。不可恢复时解除接管。

## 进程与清理

开发 Off 模式由独立无特权看护进程启动内核，使用 DispatchSource 观察 App 退出，并处理正常终止信号。看护同时退出时保留进程记录；下一实例持有数据目录锁后仅清理记录内 PID 且真实可执行路径一致的遗留进程。重复启动不会产生第二个受管理内核。

正式 Helper 生命周期基于 XPC 断开立即清理、每 3 秒心跳、12 秒失联阈值。launchd KeepAlive 重启 Helper 后，先检查受控目录记录，核对真实可执行路径，仅清理自身 root 内核，然后恢复代理快照。此特权路径尚待故障注入验证。

系统代理通过 SystemConfiguration 的 SCPreferences 锁完成修改。按 service ID 保存完整原始字典和协议启用状态，代理快照先于系统写入。恢复时逐字段比较应用曾写入值，只恢复未被第三方改变的值；无关设置不动。新服务只在显式模式事务时纳入，移除服务保留恢复记录。

## 更新

检查和下载只由用户触发，固定官方仓库，选择精确 darwin-arm64 资产，必须具备 GitHub SHA-256 digest。校验压缩包摘要、Mach-O CPU、`-v`、`-t`，下载失败不停止旧内核。重启后回读版本、模式、组和选择，持续确认 3 秒后提交。失败自动恢复旧内核，旧文件直到成功提交后才回收。App 包从不被更新写入。

root Helper 不直接执行客户端给出的普通可写文件。内核内容首先与签名 App 内置内核比较；不同内容通过 Helper 独立下载官方最新发行并验证摘要后再比对。已确认文件放入 root 所有、0700 的受控目录，并在执行前重新核对摘要。状态提交后客户端通知 Helper 核对当前受管理进程与内核摘要，再删除事务中的旧受控内核；清理失败保留 journal 并显示清理未完成，下次恢复重试。完整特权更新验收仍待完成，详见 TV09 / TV10。

## 参数

Controller 127.0.0.1:19090；System Proxy 127.0.0.1:17890。端口冲突拒绝事务并保留原状态，不接管其他进程。API 请求 10 秒，资源 15 秒；内核验证 25 秒；启动确认 15 秒。延迟测试并发 4、超时 5000ms、URL `https://www.gstatic.com/generate_204`；绿色 <150ms、橙色 150–399ms、红色 ≥400ms，失败/超时红色并有文字。Off / Rule / 自启关闭为首启默认值。
