# TV 技术结论（开发版）

日期：2026-10-14。目标 macOS 26+ ARM64。本机验证为 macOS 27.0.1 ARM64、Swift 6.4、Mihomo v1.19.32。实现决定不代表特权验收完成。

| 编号 | 实现方案 / 参数 | 验证边界 |
| --- | --- | --- |
| TV01 | 本地副本；reload 读副本；file provider 相对资源复制到独立目录；缓存路径语义重定位；越界/绝对路径拒绝 | 解析与原文保留有自动化验证；需补充更多真实资源配置 |
| TV02 | Off 仍运行内核供 API、选择和测速使用，tun.enable=false，无应用系统代理 | 真实内核 API 与模式回读验证 |
| TV03 | SMAppService daemon，认证 XPC，同 Team ID / 固定标识；正式内核生命周期归属 Helper；开发 Off 使用无特权独立看护 | 源码和构建验证；无证书，正式注册/用户批准待验证 |
| TV04 | XPC 断连立即清理；心跳每 3s、失联 12s；KeepAlive 重启先恢复；开发看护观察 App PID 退出；本地 journal 恢复孤儿 | 开发看护的强制结束测试；root Helper 双重故障待验证 |
| TV05 | SCPreferences 事务锁，按网络 service ID 保存字典，恢复时逐字段比较并保留第三方修改 | 代码实现；实际代理修改、网卡变更、第三方冲突待特权验收 |
| TV06 | PUT /configs?force=true；配置置于 -d 工作目录；回读模式、组成员、有效选择；不确定结果强制补偿旧配置；关闭内核全局选择缓存 | 真实进程热重载和失败拒绝、模拟部分成功及失败补偿；自动组 fixed 与 provider 场景仍需扩大验证 |
| TV07 | 单节点 delay API，去重当前组显示集合；并发4、超时5000ms、gstatic 204；绿色<150ms、橙色150–399ms、红色≥400ms；异常置后，稳定排序 | 模型排序、真实本地204 DIRECT/REJECT用例；组级 delay 不使用 |
| TV08 | Off / Rule / 自启关闭；固定端口19090/17890；冲突拒绝；明确白名单见 ARCHITECTURE | 最小覆盖、DNS语义、tun其他字段、原文和模式不变量测试 |
| TV09 | 精确官方 ARM64资产，压缩摘要和Mach-O检查，-v/-t，启动后确认3s；状态原子提交后回收旧版本 | 真实更新、错误版本候选、替换启动失败回滚、旧文件回收已验证；需更多特权路径及下载/校验阶段故障注入 |
| TV10 | 更新不改App；root受控0700存储；Helper独立验证官方来源；Developer ID、hardened runtime、公证、装订脚本 | ad-hoc开发包构建验证；正式签名、更新后Gatekeeper与root执行待验证 |

官方参考：[Mihomo API](https://wiki.metacubex.one/api/)、[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[XPC代码签名约束](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))、[Apple公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[固定内核发行](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32)。
