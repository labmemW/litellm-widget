# AGENTS.md — 给 AI 助手的操作规则

本仓是「LiteLLM 额度悬浮窗」:Windows 桌面置顶小窗,实时显示 LiteLLM 代理 key 的额度。
面向人类的说明在 README.md;本文件面向 AI 助手,**改代码 / 部署 / 排障前必读**。

## 运行拓扑(先搞清东西在哪)

- **本仓(Linux 服务器)**:源码存档,**不在这台机器上运行**
- **运行时(用户的 Windows 桌面)**:`~/.litellm-widget/` 下:
  litellm-widget.ps1(本体)、config.ini(**含多把 key**,`api_keys=` 逗号分隔;
  旧 `api_key=` 单 key 格式仍兼容)、start-widget.vbs(静默启动)、
  pos.txt(位置记忆)、last-state.txt(每轮脱敏诊断)
- **数据源(LiteLLM 代理)**:地址和 key 都在 config.ini 里,不要把真实值写进仓库;
  用量来自响应头 `x-litellm-key-spend` / `x-litellm-key-max-budget`
- 服务器与 Windows 之间用 scp 同步(端口/地址看用户环境),没有 CI;
  **Windows 上的活副本是事实源**,服务器仓是归档——改完记得同步回来提交

## 硬性规则(每条都是真实事故换来的)

1. **绝不提交 config.ini / api_key / 真实 base_url / 内部机器名和端口**。.gitignore 已挡
   config.ini,不要用任何方式绕过;仓里只有 config.example.ini 模板
2. **所有 .ps1 必须纯 ASCII**。Windows PowerShell 5.1 按 ANSI 读无 BOM 文件,任何非
   ASCII 字节(包括中文注释)会吞掉换行、破坏 C# 编译;C# 字符串里的中文一律
   `\uXXXX` 转义(本体里的 S() 函数)
3. **改完必须过 `widget-syntax-check.ps1` 三项检查**(ASCII 纯度 / PS 语法 / C# 编译),
   它检查的是 Windows 活副本路径;在服务器上改了 ps1 的话先 scp 到 Windows 再检查运行
4. **在 Windows 上改 config.ini 必须写成 .ps1 脚本文件执行,禁止 shell 内联命令**——
   cmd 会吃换行符,曾把整个配置压成一行、key 泄漏进日志;损坏后用 widget-fix-config.ps1 恢复
5. **按命令行匹配进程时会命中查询进程自身**(`*litellm-widget.ps1*` 出现在查询命令里),
   杀进程前排除自身 $PID
6. 用户本机系统代理若访问不了代理地址,任何探测脚本都要显式 `UseProxy=false`
   (具体地址看 config.ini,不要写死在代码或文档里)

## 修改 → 部署 → 验证 流程

1. 改 Windows 上 `~/.litellm-widget/litellm-widget.ps1`(活副本)
2. 跑 widget-syntax-check.ps1,三项全过
3. 重启:跑 `restart-widget.ps1`(按规则 5 杀旧实例并 VBS 重启)
4. **验证只看 last-state.txt**(30~90 秒内会刷新,可直接 cat,已脱敏):
   - 健康:`err=-  failCount=0  baseUrl=OK  keys=k0:spend/budget,...  total=x/y  keyLen=k0:25`
   - `err=HTTP 403`:探测模型下线,failCount 到 2 会自动 RelearnModel 自愈,等一轮
   - `err=HTTP 429 且 keys 有值`:该 key 已超限,走 429 响应体解析,属正常路径
     (状态行里该 key 显示为 `k0:x/y/over`;只有全部 key 超限才会整体退避 30 分钟)
   - `baseUrl=INVALID / keyLen=-1`:config.ini 损坏,跑 widget-fix-config.ps1
5. 验证通过后归档:scp 回服务器的仓目录,git add 具体文件名,commit

## 有用的事实

- **多 key(2026-11-20 加入)**:config.ini `api_keys=k1,k2,...` 逗号分隔,可选
  `key_names=名1,名2` 显示名(默认 k1,k2);每轮对每把 key 各探测一次,合计与明细
  分开展示;超限 key **各自**退避 30 分钟(429 也计入该 key 失败率,网关超 80% 封禁),
  健康 key 不受影响;last-state 的 keys/ 段用稳定索引 k0,k1(key_names 可能非 ASCII);
  改 key 清单 = 改 config.ini 的 api_keys 行(走 .ps1 脚本,规则 4)后重启
- 探测是合法最小请求("hi" + max_tokens=1,约 ¥0.00002/次,last-state 里 spend 可见非零):
  2026-10 起网关按失败率封 key(超 80% 封禁),旧"空 messages 必 400"零成本探测每天制造
  ~1440 次失败调用,经用户决定弃用——不要改回零成本探测
- **中继模式(2026-11-17 加入)**:代理的 LB 按来源 IP 钉实例、各实例 spend 账本不同步,
  本机出口曾被钉在只记 widget 自身探测(≈¥0.003)且冻结的账本上,而真实消费走其它出口
  (实测同 key 同一分钟:本机出口 0.0029 冻结,另一台机器出口 2.71 实时;经中继机转发后
  立即读到实时值)。配置键:relay_enabled/relay_ssh_host/relay_ssh_port/relay_ssh_user/
  relay_local_port/relay_target(缺省从 base_url 解析 host:port)。行为:启动时按
  "命令行含 `-L 127.0.0.1:<port>:<target>`"杀孤儿隧道(WMI,规格串运行时由 config 拼出,
  源码无环境信息);探测前确保隧道在,死了重拉(30 秒节流);拉不起来回落直连并把
  errStatus 置为 "relay tunnel down - probing direct";退出时杀自己的子进程。
  last-state 的 `relay=on/down/off` 看状态。C# 依赖 System.Management.dll(本体和
  widget-syntax-check.ps1 的 ReferencedAssemblies 都要带)
- 超预算后轮询退避为 30 分钟一次(OverLimitRefreshSeconds 常量);429 响应体解析额度路径不变
- 超限时 LiteLLM 返回 429,响应体含 "Current cost: X, Max budget: Y",widget 会解析
- 额度重置通常靠管理员手动或 budget_duration 自动(看部署),没有通用查询接口;
  重置后 widget 下轮自动恢复,阈值提醒重新武装
- key 通常有 RPM 限制,widget 每次轮询占 1 次
- 单实例互斥名 LiteLLMWidgetSingleInstance;开机自启在 HKCU Run 的 LiteLLMWidget 项
- 滚轮调透明度会实时写回 config.ini 的 opacity;拖动位置写 pos.txt
- 响应头数值有轻微多实例抖动(代理后多实例),不是 bug
