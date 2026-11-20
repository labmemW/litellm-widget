# LiteLLM 额度悬浮窗(Windows)

桌面置顶小窗,实时显示 LiteLLM 代理 key 的额度:已用 / 限额 / 剩余 + 进度条,
到阈值弹通知。支持**多把 key**:顶部显示合计,下方每把 key 一行明细。单文件
PowerShell(WinForms),零依赖。

```
 LiteLLM 额度              15:08:17
 ¥18.05 / ¥100.00
 [███░░░░░░░░░░░░░░░░░░░░]  18.1%
 剩余 ¥81.95
 k1  15.9%  ¥7.95/50
 备用A  20.2%  ¥10.10/50
```

## 工作原理

- 数据源:代理(chat/completions)响应头 `x-litellm-key-spend` / `x-litellm-key-max-budget`
- **多 key**:config.ini `api_keys=k1,k2,...` 逗号分隔(`api_key=` 单 key 旧格式仍兼容);
  每轮对每把 key 各发一次最小探测,合计 = Σspend / Σbudget / Σ剩余(超限 key 剩余计 0)
- **合法最小探测**:发一条真实请求(`"hi"` + `max_tokens=1`,约 ¥0.00002/次,flash 模型),
  从响应头读用量。旧版的零成本探测(空 messages 必 400)会让每次轮询都计一次失败调用,
  网关按失败率封 key(超 80% 封禁),已弃用
- 超限场景:429 响应体带 `Current cost: X, Max budget: Y`,同样能解析;超限后轮询自动退避为
  30 分钟一次(429 也计入失败率),管理员重置后自动恢复
- HTTP 显式绕过系统代理(`UseProxy=false`):如果你的本机代理访问不了代理地址,就需要这个
- **中继模式(relay,可选)**:当代理的负载均衡按来源 IP 把你钉到一个
  spend 账本过期/不同步的实例上时(表现为:悬浮窗数值冻结不动,换台机器查同一个 key 却是实时的),
  开启 `relay_enabled=1`,悬浮窗会自己维护一条 `ssh -N -L` 隧道经中继机转发探测,
  让出口 IP 变成中继机的。隧道:启动时清理孤儿、死了自动重拉(30 秒节流)、
  中继机不可达时回落直连并在状态里标注;退出时杀掉自己的隧道子进程。
  需要 Windows OpenSSH(ssh.exe)+ 对中继机免密登录

## 功能

- 每 60 秒自动刷新(config.ini 可调,最低 10 秒);超限 key 各自退避为 30 分钟一次,
  健康 key 不受影响;全部超限时整体退避
- **多 key 报警**:按 key 弹"已用 80%/95%"通知(带 key 名),另有一条合计级 95% 告急;
  管理员重置后按 key 自动重新武装
- **多实例抖动修正**(按 key):代理若是集群部署,不同实例返回的 spend 有滞后差异,
  显示最近 15 分钟内见过的最大值,不回跳;管理员重置后 15 分钟内自动回落
- **边缘吸附 + 自动隐藏**:拖到屏幕左右边缘即贴边并收起(留 6px 抓取条),
  鼠标贴到屏幕边缘或划过抓取条时滑出,移开 1.5 秒后缩回;拖离边缘恢复普通模式
- 颜色分级:<80% 绿,≥80% 橙,≥95% 红;跨阈值时 Windows 通知(默认 80%/95%,可配)
- **滚轮调透明度**(30%~100%,自动记忆);config.ini 的 `opacity` 同效
- 左键拖动(位置记忆)、双击立即刷新、右键菜单(立即刷新/退出)
- 每次刷新自动夺回置顶(TopMost);不出现在任务栏和 Alt+Tab
- 自愈:探测模型下线时(403)自动从 /models 重选并写回配置;配置损坏时不发起请求
- 单实例互斥;开机自启(VBS 静默启动 + HKCU Run)
- 诊断:每轮把状态写到 `~/.litellm-widget/last-state.txt`(已脱敏,不含 key;中继模式含 `relay=on/down/off`)

## 文件

| 文件 | 说明 |
|---|---|
| `litellm-widget.ps1` | 悬浮窗本体(单文件,含内嵌 C#) |
| `AGENTS.md` | 给 AI 助手的操作规则(改代码/部署/排障必读) |
| `start-widget.vbs` | 静默启动器(无控制台黑框) |
| `install-autostart.ps1` | 生成 VBS + 注册开机自启(装新机器用) |
| `config.example.ini` | 配置模板;复制为 `config.ini` 并填入真实 key |
| `migrate-config-multikey.ps1` | 一次性迁移:config.ini `api_key=` → `api_keys=`(自动备份) |
| `widget-syntax-check.ps1` | 改完代码后的检查(ASCII 纯度/语法/C# 编译) |
| `widget-fix-config.ps1` | config.ini 损坏时从残骸恢复 key |
| `restart-widget.ps1` | 杀旧实例(排除自身)+ VBS 重启,改代码后用 |

## 安装(新机器)

```powershell
# 1. 文件就位
mkdir %USERPROFILE%\.litellm-widget
copy litellm-widget.ps1 start-widget.vbs %USERPROFILE%\.litellm-widget\

# 2. 配置
copy config.example.ini %USERPROFILE%\.litellm-widget\config.ini
notepad %USERPROFILE%\.litellm-widget\config.ini   # 填 base_url 和 api_key

# 3. 启动 / 装自启
wscript %USERPROFILE%\.litellm-widget\start-widget.vbs          # 立即启动
powershell -File install-autostart.ps1                          # 注册开机自启
```

卸载:删注册表 `HKCU\...\Run` 的 `LiteLLMWidget` 项,退出悬浮窗(右键菜单),删 `~/.litellm-widget`。

## 安全注意(重要)

- **`config.ini` 含 api_key,已 gitignore,绝不入库**
- 本仓所有 `.ps1` 必须**纯 ASCII**:Windows PowerShell 5.1 把无 BOM 文件按 ANSI 读,
  中文(哪怕注释)会破坏解析并让 Add-Type 的 C# 编译错乱;界面文案用 `\uXXXX` 转义
- 修改后务必跑 `widget-syntax-check.ps1`
- 提交前自查:确认没有 base_url、key、内部机器名等任何环境信息入库

## 已知限制

- 额度重置若是管理员手动操作,则无自动重置时间可查(部分部署的 /key/info 不开放);
  重置后悬浮窗在下个刷新周期自动恢复,提醒重新武装
- key 通常有 RPM 限制,悬浮窗每轮对每把 key 各占 1 次
- 集群部署下限额检查本身也有透支空间(各实例账本同步滞后,消费前校验各自为政),
  显示的是修正后的最大值,但真实消费仍可能略超限额——想稳妥就给提醒阈值留余量

## key 池分发(与 21/27 服务器联动)

widget 的 config.ini 是**多 key 的唯一事实源**,消费侧在两台 Linux 服务器上各跑一个
本地 LiteLLM key 池(kimi/工具经 `127.0.0.1:8081` 消费,429 自动冷却切换)。改完
config.ini 的 `api_keys=` 后跑分发脚本,把 key 推到两台机器并重启各自的池:

```powershell
powershell -File %USERPROFILE%\.litellm-widget\push-keys.ps1   # 默认推 27+21
```

- 脚本与 `push-merge.sh` 都在 `~/.litellm-widget/`(含内部机器信息,**不入库**);
  远端池的文件与运维见两台机器上的 `~/.agents/skills/litellm/SKILL.md`
- **key 彻底超限后要从 `api_keys=` 摘除再推一次**:池对冷却中的 key 每小时试探一次,
  上游网关按失败率(>80%)封 key,死 key 留在池里有封禁风险;管理员重置后再加回来
- 加 key 流程:改 config.ini(走 .ps1 脚本,勿 shell 内联)→ 重启 widget → push-keys
