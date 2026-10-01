---
name: windows-username-migration
description: Safely rename a Windows local account AND its C:\Users profile folder (e.g. Chinese → English username) with zero data loss. Use when the user wants to change their Windows account name / profile path, or when agents, compilers, package managers or CLIs keep failing due to non-ASCII profile paths (C:\Users\<中文名>). Covers ARSO auto-restart sign-on, scheduled-task handle races, NTUSER.DAT hive locks, handle64 forensics, offline registry fixes, and full rollback. 实战复盘：从 5 次失败到一次成功的完整方法论。
---

# Windows 用户名/配置文件夹安全迁移实战手册

> 来源：2026-09-30 真实迁移（中文用户名 → Solskjaer，Win11 26200）。
> 前 5 次尝试全部失败但**用户数据零损失**，第 6 次一次成功。
> 本手册 = 每一次失败的真实根因 + 解法 + 可直接使用的脚本（scripts/ 目录，替换 SID 与密码即可用）。

## 0. 铁律（先读这个）

1. **只做原位重命名（`Rename-Item`），永不复制/移动/删除用户文件。**
   同一分区内目录改名是纯元数据操作，瞬间完成、不碰文件内容——这从根源上排除了
   "复制中断/磁盘满导致丢文件"。回滚 = 改回名字。
2. **预检不过，立即中止。** 每一步失败都要"当作没发生过"地退出，宁可多跑一次。
3. **一切动作写日志，失败时日志要自动取证**（输出 ACL、存活进程、已加载 hive）。
4. **永远先做**：完整数据备份（放另一块盘）、注册表 .reg 导出、系统还原点、一个恢复管理员账户。
5. **显示形式 ≠ 存储形式**：注册表/计划任务里存的是名字还是 SID？路径是大写还是小写？
   正斜杠还是双反斜杠？UTF-8 还是 GBK？——每一种变体都要单独处理（见 §4）。

## 1. 目标与整体架构

```
step0 勘察（只读）
  ├─ 账户类型/SID/管理员身份、磁盘空间
  ├─ OneDrive（是否登录/云端占位文件）、WSL/Docker、IIS、junction 链接
  ├─ 引用旧路径的：用户环境变量、服务、计划任务、配置文件清单
  └─ 杀软/受控文件夹访问状态
step1 准备（提权）：创建恢复管理员 + 系统还原点
备份：Documents/Desktop/… 完整副本 + .reg 导出 + NTUSER.DAT 副本 → 第二块盘
step2 迁移（核心，见 §3）：重命名文件夹 + 注册表 + NTUSER.DAT 离线修复 + 配置文件字节修复 + 账户改名
step3 验证：10 项只读检查
step4 清理：恢复被禁用的任务/服务、删除恢复账户（等确认一切正常后）
```

## 2. 六个真实的坑（症状 → 根因 → 解法）

### 坑① NTUSER.DAT 被锁 —— "切换用户" ≠ 注销
- **症状**：备份/探测报 "文件正由另一进程使用"。
- **根因**：通过"切换用户"进入恢复账户，旧账户会话仍挂在后台，注册表 hive 未卸载。
- **解法**：`reg load HKU\_Probe "<旧目录>\NTUSER.DAT"` 作探针，失败即中止并要求**真正重启**；
  若 hive 已加载但无桌面会话（后台残留），可清进程后 `reg unload HKU\<SID>` 强制卸载。

### 坑② 十几个旧身份计划任务抢占 —— 你不是一个人在战斗
- **症状**：`Rename-Item` 报"访问被拒绝"，重试 30 秒仍然被拒；期间无任何以旧身份运行的进程？
- **根因**：本机 13 个计划任务以旧账户身份运行（夸克/OneDrive 启动器/FN 热键/Google 组件/华硕…），
  登录瞬间"抢跑"，打开文件夹句柄甚至加载 hive。
- **解法**：按 **Principal 身份**枚举并禁用所有相关任务 → 杀掉以旧身份运行的进程 → 再动手；
  迁移成功后把任务 XML 里的旧路径字节级替换掉，再恢复启用。

### 坑③ ARSO：用户根本没停在登录界面（最阴险）
- **症状**：用户发誓"在登录界面等了 3 分钟"，但开机日志显示任务运行时 `explorer.exe` 已经以旧用户身份在跑。
- **根因**：Win11"重启后自动登录"（Automatic Restart Sign-On）。你以为在等登录界面，其实系统已自动进桌面。
- **解法**：提前关闭它，否则一切"开机时动手"的方案必败：
  ```powershell
  # 提权
  reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Policies\System" /v DisableAutomaticRestartSignOn /t REG_DWORD /d 1 /f
  reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f
  # 当前用户（免提权）
  reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v RestartApps /t REG_DWORD /d 0 /f
  ```

### 坑④ 计划任务的 Principal 存的是"名字"不是 SID
- **症状**：按 SID 过滤计划任务 → 一个都匹配不到；但交互式按"名字+SID"匹配能找到 13 个。
- **根因**：任务的 Principal.UserId 因创建方式不同，可能存账户名（`DESKTOP-XXX\<中文用户名>`）也可能存 SID。
- **解法**：双条件匹配 `$uid -match $sid -or $uid -like "*$旧名*"`；
  **同理**，迁移后恢复任务时还要加 `*新名*`（因为任务 XML 已被替换成新名）。

### 坑⑤ 普通手段全部排除后仍被拒 —— 用 handle64 点名真凶
- **症状**：任务已禁用、hive 干净、ACL 正常（`icacls` 无 Deny）、无旧身份进程，改名仍被拒 30 秒。
- **根因（本例真凶）**：`CodexSandboxService.OpenAI.Codex`（codex-windows-sandbox-service.exe，自启动服务）
  在开机时就持有**配置文件夹根目录**的句柄。微软电脑管家、NVIDIA Container、华硕 Armoury Crate 占着子目录。
- **解法（动态清除器）**：用微软官方 [Sysinternals Handle](https://download.sysinternals.com/files/Handle.zip)
  实时扫描所有持有该目录句柄的进程 → 有所属服务则 `Stop-Service`，否则 `Stop-Process` → 立即重命名；
  **每次重试前重扫**。下载注意：国内网络需 `curl --ssl-no-revoke`。
  ```powershell
  handle64.exe -accepteula -a -nobanner "C:\Users\<旧名>"   # 列出所有句柄及进程
  ```
- **经验**：当"看不见的占用"持续存在时，不要猜，**用句柄枚举点名**。内核反作弊驱动（如 ACE-BOOT）
  也可能是嫌疑人——临时禁用其启动类型，迁移成功后恢复。

### 坑⑥ 用户登录撞上迁移最后几秒（会造成恐慌！）
- **症状**：迁移明明在推进，用户却在某次登录时看到"旧用户名 + 密码错误"，极度惊恐。
- **根因**：迁移最后几秒在做"账户改名"，此时登录界面显示旧名、凭据校验撞上半改名状态 → 报错。
  用户再重启一次就正常了（迁移已完成），但体验极差。
- **解法**：迁移的最后阶段（改文件夹名→改注册表→改账户名这 ~10 秒）应当**阻止登录**——
  可先临时禁用该账户的登录权限（`net user <名> /active:no`）最后再启用，或在脚本开头
  明确告知用户"迁移需 X 分钟，完成后才会显示成功，期间登录必然失败属正常"。
  **事后安抚要点**：拿日志时间线给用户看"你的登录尝试发生在 16:43:35，账户改名发生在 16:43:39"。

## 3. 迁移核心步骤（scripts/step2b_boot_rename.ps1 的骨架）

1. **预检**：注册表 ProfileList\SID 的 ProfileImagePath 存在、目标名未占用、当前不在旧目录里、
   hive 未加载（已加载→见坑①分支处理）。
2. **再备份**：ProfileList .reg 导出 + NTUSER.DAT / UsrClass.dat 文件副本（此时 hive 未锁，直接复制）。
3. **清场**（每个都写日志）：禁用旧身份任务 → 停 WSearch/SysMain/WAS →
   停自启动占位服务（如 Codex 沙箱）→ 杀旧身份进程 → handle64 扫描清句柄持有者。
4. **改名**：`Rename-Item -LiteralPath C:\Users\<旧名> -NewName <新名>`（10 次重试，每次重试前重新清场）。
5. **注册表**：`ProfileList\SID\ProfileImagePath` 立即更新（与改名是关键原子对）。
6. **离线修 NTUSER.DAT**：`reg load HKU\_TmpUser` 后按树修复这些键里含旧路径的字符串值
   （**保持原值类型**，REG_EXPAND_SZ 要用 DoNotExpandEnvironmentNames 读原串）：
   - `Environment`（Path/PNPM_HOME/TEMP/TMP/OneDrive…）
   - `...\CurrentVersion\Run`、`RunOnce`
   - `...\Explorer\User Shell Folders` 与 `Shell Folders`（本例全是绝对路径！）
   - `...\Lxss`（WSL）、`Software\Microsoft\OneDrive`（UserFolder 等）
7. **字节级修配置文件**：对扫描清单里的文件做**字节替换**（不重编码，避免破坏文件其余部分），
   覆盖 5+ 种形态：`C:\Users\旧名` 的 UTF-8 / GBK / UTF-16LE / 正斜杠 / **小写盘符 `c:\users\`** /
   **TOML 双反斜杠 `C:\\Users\\`** —— 以及**纯中文叶子名**（中文无大小写问题，最鲁棒）。
   每个文件先备份原件。还要扫 `C:\Windows\System32\Tasks\`（任务 XML 是 UTF-16）和
   IIS 的 `applicationHost.config`。
8. **账户改名**：`Rename-LocalUser`（按 SID 找人）+ `Set-LocalUser -FullName`。
9. **恢复**：重新启用禁用的任务、恢复临时禁用的服务/驱动启动类型。
10. **自删**：`Unregister-ScheduledTask` 删除开机任务，写 DONE 标记。设计为**可续跑/幂等**：
    中途断电重启后，再开机时按当前状态补完剩余步骤。

## 4. 容易被忽略的检查项

- **OneDrive**：未登录≠没配置（注册表 Accounts\Business1/Personal 的 UserFolder 要修）；
  目录里可能是"按需文件"云占位符——它们**不能复制**（云提供程序未运行会报错 362），
  也**不需要复制**（云端即备份，改名不影响）。
- **旧 ProfileList 的 RefCount / 乱码垃圾文件夹**：`C:\Users` 下常有历史乱码目录
  （UTF-8 被当 GBK 的产物），先备份再删。
- **杀软**：Defender 服务异常（0x800106ba）时用 SecurityCenter2 查注册的 AV；
  受控文件夹访问会拦改名，需临时放行。
- **第三方自启动驱动**（游戏反作弊 ACE-BOOT 等）：会锁目录，临时 `sc config ... start= disabled`，
  成功后恢复（注意 `sc config ... start= boot` 可能报 87 错，`start= system` 是可用等价）。
- **带空格的服务名**：`sc config "AntiCheatExpert Service" start= manual` 会被空格坑，
  用 `Set-Service -Name <名> -StartupType Manual` 代替。
- **卸载信息键与文件关联**（迁移后一两天才爆的暗雷）：`HKCU\...\Uninstall\<GUID>_is1` 的
  `InstallLocation/UninstallString/DisplayIcon`、`HKCU\Software\Classes\Applications\<app>\` 的
  图标与 command、`MuiCache`——这些残留不会让系统报错，但**软件自更新时**会按旧路径重装，
  弹"安装程序不能创建目录 C:\Users\<旧名>，错误 5：拒绝访问"。更新器每检查一次就弹一次。
  症状与迁移的关联极其隐蔽，排查入口：弹窗里出现旧路径 + Temp 里有滞留的 `CodeSetup-*.exe`。

## 5. 验证清单（scripts/step3_verify.ps1）

USERPROFILE / 账户名 / 注册表路径 / 新目录存在 / 用户环境变量无旧路径 /
Shell Folders 全部指向存在目录 / git 全局配置可读 / .ssh 存在 / 无悬空链接 /
配置文件 0 处旧路径残留。**注意**：`-like '[FAIL]*'` 里方括号是通配符字符类，
统计要用 `$_.StartsWith('[FAIL]')`（本手册作者亲自踩过）。

## 6. 回滚（应始终可用）

```powershell
Rename-Item 'C:\Users\<新名>' '<旧名>'
Set-ItemProperty 'HKLM:\...\ProfileList\<SID>' -Name ProfileImagePath -Value 'C:\Users\<旧名>'
Rename-LocalUser -Name <新名> -NewName '<旧名>'
# 兜底：.reg 备份双份 + NTUSER.DAT 副本 + 系统还原点
```

## 7. 给 Agent / 自动化执行者的元经验

1. **"安全中止"是用户信任的基石**：5 次失败 0 损失，用户才愿意给你第 6 次机会。
   每个失败分支都必须保证"当作没发生过"。
2. **现象会撒谎，日志不会**：用户说"我在登录界面等了 3 分钟"，日志显示 explorer 正以旧用户运行——
   先取证（handle64/日志时间线），再动手。
3. **每层修复都要问"存储形式和显示形式一致吗"**：SID vs 名字、大小写、正反斜杠、转义、编码——
   一个变体漏掉就是一个"神秘 FAIL"。
4. **把失败路径做成自动取证**：FATAL 时自动输出 ACL、存活进程、已加载 hive，
   下一次失败就直接带答案回来。
5. **让用户做的事越少越好**：双击按钮 + 一次重启；UAC 弹窗要提前明确说"马上会弹，请点是"，
   否则用户不在屏幕前就卡住。
6. **给用户"可感知的进度与凶险预告"**：如实说明哪一步可能看到什么（比如"迁移最后几秒内
   登录会失败，这不是密码错误"），能避免最大的信任危机。

## 8. scripts/ 目录（实战脚本，替换 SID/密码/路径后可用）

| 脚本 | 作用 |
|---|---|
| `scan_config.ps1` | 扫描配置文件中的旧路径硬编码（生成修复清单） |
| `step1_prepare_admin.ps1` | 创建恢复管理员 + 系统还原点 |
| `step2_rename_profile.ps1` | 交互式迁移（SolskAdmin 会话内跑，全套清场+重试） |
| `step2b_boot_rename.ps1` | 开机迁移（SYSTEM 计划任务，推荐；可续跑、幂等、成功自删） |
| `step2d_disable_arso.ps1` | 关闭 ARSO 自动重启登录 |
| `step3_verify.ps1` | 迁移后 10 项验证 |
| `clean_residual.ps1` | 残留路径清理（含大小写/转义/编码变体） |

> 使用前：把脚本中的 SID `S-1-5-21-<你的机器>-1001`、工作目录、临时密码替换成你自己的。
> 警示：这是高风险系统操作。请先完整读懂本手册，准备备份与恢复账户，并选用户在场的时间执行。
