# LiteLLM 额度悬浮窗(Windows)

桌面置顶小窗,实时显示 LiteLLM 代理 key 的额度:已用 / 限额 / 剩余 + 进度条,
到阈值弹通知。单文件 PowerShell(WinForms),零依赖。

```
 LiteLLM 额度              15:08:17
 ¥7.95 / ¥50.00
 [██░░░░░░░░░░░░░░░░░░░░]  15.9%
 剩余 ¥42.05
```

## 工作原理

- 数据源:代理(chat/completions)响应头 `x-litellm-key-spend` / `x-litellm-key-max-budget`
- **零成本探测**:发一个必然 400 的请求(空 messages),同样返回用量响应头——轮询不花一分钱额度
- 超限场景:429 响应体带 `Current cost: X, Max budget: Y`,同样能解析
- HTTP 显式绕过系统代理(`UseProxy=false`):如果你的本机代理访问不了代理地址,就需要这个

## 功能

- 每 60 秒自动刷新(config.ini 可调,最低 10 秒)
- 颜色分级:<80% 绿,≥80% 橙,≥95% 红;跨阈值时 Windows 通知(默认 80%/95%,可配)
- **滚轮调透明度**(30%~100%,自动记忆);config.ini 的 `opacity` 同效
- 左键拖动(位置记忆)、双击立即刷新、右键菜单(立即刷新/退出)
- 每次刷新自动夺回置顶(TopMost);不出现在任务栏和 Alt+Tab
- 自愈:探测模型下线时(403)自动从 /models 重选并写回配置;配置损坏时不发起请求
- 单实例互斥;开机自启(VBS 静默启动 + HKCU Run)
- 诊断:每轮把状态写到 `~/.litellm-widget/last-state.txt`(已脱敏,不含 key)

## 文件

| 文件 | 说明 |
|---|---|
| `litellm-widget.ps1` | 悬浮窗本体(单文件,含内嵌 C#) |
| `AGENTS.md` | 给 AI 助手的操作规则(改代码/部署/排障必读) |
| `start-widget.vbs` | 静默启动器(无控制台黑框) |
| `install-autostart.ps1` | 生成 VBS + 注册开机自启(装新机器用) |
| `config.example.ini` | 配置模板;复制为 `config.ini` 并填入真实 key |
| `widget-syntax-check.ps1` | 改完代码后的检查(ASCII 纯度/语法/C# 编译) |
| `widget-fix-config.ps1` | config.ini 损坏时从残骸恢复 key |

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
- key 通常有 RPM 限制,悬浮窗每轮询一次占 1 次
- 用量响应头有轻微多实例抖动(代理后多实例,DB 同步延迟),属正常
