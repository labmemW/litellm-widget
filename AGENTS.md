# AGENTS.md — 给 AI 助手的操作规则

本仓是「LiteLLM 额度悬浮窗」:Windows 桌面置顶小窗,实时显示 LiteLLM 代理 key 的额度。
面向人类的说明在 README.md;本文件面向 AI 助手,**改代码 / 部署 / 排障前必读**。

## 运行拓扑(先搞清东西在哪)

- **本仓(Linux 服务器)**:源码存档,**不在这台机器上运行**
- **运行时(用户的 Windows 桌面)**:`~/.litellm-widget/` 下 5 个文件:
  litellm-widget.ps1(本体)、config.ini(**含 key**)、start-widget.vbs(静默启动)、
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
3. 重启:按规则 5 杀旧 powershell 实例,`wscript %USERPROFILE%\.litellm-widget\start-widget.vbs` 启动
4. **验证只看 last-state.txt**(30~90 秒内会刷新,可直接 cat,已脱敏):
   - 健康:`err=-  failCount=0  baseUrl=OK  keyLen>0  spend>=0`
   - `err=HTTP 403`:探测模型下线,failCount 到 2 会自动 RelearnModel 自愈,等一轮
   - `err=HTTP 429 且 spend 有值`:已超限,走 429 响应体解析,属正常路径
   - `baseUrl=INVALID / keyLen=-1`:config.ini 损坏,跑 widget-fix-config.ps1
5. 验证通过后归档:scp 回服务器的仓目录,git add 具体文件名,commit

## 有用的事实

- 轮询零成本:发空 messages 的必 400 请求,响应头照样带用量;不要换成真请求
- 超限时 LiteLLM 返回 429,响应体含 "Current cost: X, Max budget: Y",widget 会解析
- 额度重置通常靠管理员手动或 budget_duration 自动(看部署),没有通用查询接口;
  重置后 widget 下轮自动恢复,阈值提醒重新武装
- key 通常有 RPM 限制,widget 每次轮询占 1 次
- 单实例互斥名 LiteLLMWidgetSingleInstance;开机自启在 HKCU Run 的 LiteLLMWidget 项
- 滚轮调透明度会实时写回 config.ini 的 opacity;拖动位置写 pos.txt
- 响应头数值有轻微多实例抖动(代理后多实例),不是 bug
