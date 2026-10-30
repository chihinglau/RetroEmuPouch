# Skill: 无 gh CLI 创建 GitHub 仓库并推送代码

> 适用于：没有安装 GitHub CLI (`gh`) 或 `gh auth login` 无法完成的场景，通过 Windows 凭据管理器中已有的 Git 凭据完成仓库创建和代码推送。

## 前提条件

- Windows 系统，已安装 Git
- 用户曾通过浏览器登录 GitHub 并在 `git push/pull` 时保存过凭据（存储在 Windows 凭据管理器中）
- Git 已配置用户名和邮箱

## 原理

Windows 上 Git 默认使用 Credential Manager 存储凭据。当用户首次 `git push` 时输入的 GitHub 用户名和 Personal Access Token (PAT) 会被保存。通过 `git credential fill` 可以提取这些凭据，再用 Token 调用 GitHub API 创建仓库，最后用 `git push` 推送代码。

## 步骤

### 1. 初始化本地 Git 仓库

```powershell
cd <项目目录>

# 创建 .gitignore（排除大文件、临时文件）
# 根据项目需要编写，示例：
# *.wsl
# *.tmp
# *.log

git init
git add .
git commit -m "Initial commit"
```

### 2. 从凭据管理器提取 GitHub Token

```powershell
# 通过 git credential fill 获取存储的凭据
$input = "protocol=https`nhost=github.com`n`n"
$cred = $input | git credential fill 2>&1 | Out-String

# 解析 username 和 password（即 Token）
$username = (($cred -split "`n" | Where-Object { $_ -match "^username=" }) -replace "username=","").Trim()
$token    = (($cred -split "`n" | Where-Object { $_ -match "^password=" }) -replace "password=","").Trim()

Write-Host "Username: $username"
Write-Host "Token length: $($token.Length)"
Write-Host "Token prefix: $($token.Substring(0,4))..."  # ghp_ 开头表示 PAT
```

### 3. 通过 GitHub API 创建仓库

```powershell
$headers = @{
    "Authorization"     = "Bearer $token"
    "Accept"            = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$body = @{
    name        = "<仓库名>"           # 必填
    description = "<仓库描述>"
    private     = $false               # $true = 私有, $false = 公开
    auto_init   = $false               # 不自动创建 README（避免冲突）
} | ConvertTo-Json

$resp = Invoke-RestMethod -Uri "https://api.github.com/user/repos" `
    -Method Post -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 30

Write-Host "仓库已创建: $($resp.html_url)"
Write-Host "Clone URL: $($resp.clone_url)"
```

### 4. 添加远程并推送

```powershell
$repoUrl = "https://github.com/$username/<仓库名>.git"
git remote add origin $repoUrl
git push -u origin master   # 或 main
```

> `git push` 会自动使用凭据管理器中的 Token 进行认证，无需额外配置。

## 完整一键脚本

将以下脚本保存为 `Push-ToGitHub.ps1`，修改 `$RepoName` 和 `$Description` 后运行：

```powershell
# ==================== 配置 ====================
$RepoName    = "my-project"
$Description = "My project description"

# ==================== 主程序 ====================
$ErrorActionPreference = "Stop"

# 1. 初始化 Git（如果尚未初始化）
if (-not (Test-Path ".git")) {
    git init
    git add .
    git commit -m "Initial commit"
}

# 2. 提取 GitHub Token
$input = "protocol=https`nhost=github.com`n`n"
$cred = $input | git credential fill 2>&1 | Out-String
$username = (($cred -split "`n" | Where-Object { $_ -match "^username=" }) -replace "username=","").Trim()
$token    = (($cred -split "`n" | Where-Object { $_ -match "^password=" }) -replace "password=","").Trim()

if (-not $token -or $token.Length -lt 20) {
    Write-Host "[!] 未找到 GitHub 凭据，请先运行一次 git push 手动登录" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] GitHub 用户: $username" -ForegroundColor Green

# 3. 创建仓库
Write-Host "创建仓库 $RepoName ..." -ForegroundColor Cyan
$headers = @{
    "Authorization"        = "Bearer $token"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$body = @{ name = $RepoName; description = $Description; private = $false; auto_init = $false } | ConvertTo-Json

try {
    $resp = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 30
    Write-Host "[OK] 仓库已创建: $($resp.html_url)" -ForegroundColor Green
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -match "already exists") {
        Write-Host "[!] 仓库已存在，继续推送" -ForegroundColor Yellow
    } else {
        Write-Host "[!] 创建失败: $errMsg" -ForegroundColor Red
        exit 1
    }
}

# 4. 添加远程并推送
$repoUrl = "https://github.com/$username/$RepoName.git"
$existingRemote = git remote get-url origin 2>&1
if ($existingRemote -ne $repoUrl) {
    git remote remove origin 2>$null
    git remote add origin $repoUrl
}
Write-Host "推送到 $repoUrl ..." -ForegroundColor Cyan
git push -u origin master 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] 推送完成: https://github.com/$username/$RepoName" -ForegroundColor Green
}
```

## 常见问题

### Q: `git credential fill` 返回空？

用户从未通过 git 访问过 GitHub。解决方法：
```powershell
# 手动触发一次认证
git push https://github.com/test/test.git
# 输入用户名和 PAT，选择保存凭据
```

### Q: API 返回 401 Unauthorized？

Token 已过期或权限不足。需要用户在 GitHub Settings → Developer settings → Personal access tokens 创建新 Token（至少 `repo` 权限），然后：
```powershell
# 清除旧凭据
cmdkey /delete:LegacyGeneric:target=git:https://github.com
# 再次运行 git push 触发重新认证
```

### Q: Token 有 `repo` 权限但 `gh auth login` 失败？

`gh` CLI 需要 `read:org` scope，普通 PAT 可能不包含。本方法直接调用 GitHub API，只需要 `repo` scope 即可创建仓库。

### Q: 如何创建私有仓库？

修改 API 请求体：
```powershell
$body = @{ name = $RepoName; private = $true } | ConvertTo-Json
```

## API 参考

| 操作 | 方法 | 端点 | 所需 Scope |
|------|------|------|-----------|
| 创建仓库 | POST | `/user/repos` | `repo` |
| 列出仓库 | GET | `/user/repos` | `repo` |
| 删除仓库 | DELETE | `/repos/{owner}/{repo}` | `delete_repo` |
| 获取用户信息 | GET | `/user` | 空（只需认证） |

## 推送前检查：.gitignore 配置参考

> **强制要求**：每次 `git add` 前确认 `.gitignore` 已正确排除编译产物、日志和临时文件，避免误提交大文件或二进制产物污染仓库。

### 关键规则（本项目实际使用）

| 规则 | 用途 | 说明 |
|------|------|------|
| `*.o` `*.obj` `*.exe` `*.dll` `*.so` `*.a` `*.lib` `*.elf` | 编译中间产物 / 二进制 | 跨平台通用排除 |
| `build/` `build-win/` `build-ninja/` `build-linux/` `*.dir/` | 构建目录 | CMake / Ninja 生成 |
| `pq_ai_terminal/pq_sim` `pq_ai_terminal/pq_sim.exe` | C 仿真主程序 | Linux 无后缀 + Windows 后缀均排除 |
| `/pq_ai_terminal/test_*` | 测试可执行文件（Linux 无后缀） | 例如 `test_usb_ecm_ai_rpc`，只匹配 `pq_ai_terminal/` 直接子项，**不影响** `tests/` 目录下的 `.c` 源码 |
| `test_*.exe` `test_*.o` | 测试编译产物（Windows / 中间文件） | 与上一条互补 |
| `/test_*.c` | 根目录临时测试源文件 | 仅排除根目录，保留 `tests/` 目录下的正式测试源码（如 `tests/test_usb_ecm_ai_rpc.c`） |
| `*.log` `*.tmp` | 日志和临时文件 | 仿真日志、运行时输出 |
| `report*.txt` | 生成的报告 | 自动生成的文本报告 |
| `.vscode/` `.idea/` `*.swp` `.DS_Store` `Thumbs.db` | IDE / OS 文件 | 避免个人环境配置入库 |

### 容易踩坑的规则

1. **Linux 编译产物无后缀**：`test_usb_ecm_ai_rpc`（无 `.exe`）容易被默认规则漏掉，必须显式 `/pq_ai_terminal/test_*`。
2. **`tests/` 源码不能误伤**：使用 `/test_*.c`（前导 `/` 限定根目录）而不是 `test_*.c`，后者会递归排除 `tests/` 下所有 `.c`。
3. **大体积仿真产物**：MATLAB 的 `matlab_sim/results/`、`matlab_sim/dataset/`、`matlab_sim/data/` 必须排除，否则首次推送会因超过 GitHub 100MB 单文件限制失败。
4. **凭据 / Skill 文件**：`skill_github_repo_access.md` 本身也加入 `.gitignore`，避免泄露推送流程细节和 Token 使用方式。

### 验证 .gitignore 生效

```powershell
# 查看哪些文件会被 git 忽略（应该看到所有二进制和日志）
git status --ignored --short

# 强制检查某个文件是否被忽略
git check-ignore -v pq_ai_terminal/test_usb_ecm_ai_rpc
# 输出示例：
# .gitignore:43:/pq_ai_terminal/test_*    pq_ai_terminal/test_usb_ecm_ai_rpc
```

## 推送前必做：创建 README.md

> **强制要求**：首次推送任何仓库之前，必须先创建一个有实质内容的 `README.md`。空仓库或缺少 README 的仓库在 GitHub 上体验很差。

### README 应包含

| 内容 | 说明 |
|------|------|
| 项目名称 + 徽章 | 版本、License、构建状态（如有） |
| 一句话定位 | 项目是干什么的 |
| ✨ 功能特性列表 | 核心能力用表格列出（带 emoji 更易读） |
| 🚀 快速开始 | 至少覆盖 2 种运行方式（EXE / 源码） |
| 🖱️ 使用流程 | 典型用户操作步骤（带 ASCII 界面或截图更好） |
| 📁 项目结构 | 目录树 + 每个模块一句话说明 |
| 🛠️ 技术栈 | 主要语言 / 框架 / 构建工具 |
| 📝 变更日志 | 顶部展示最近 1-2 个版本 |
| 📜 License | MIT / Apache-2.0 等 |

### 检查清单（推送前逐项确认）

推送前确认：
- [ ] `README.md` 存在且非空（至少 50 行）
- [ ] 顶部版本号与代码中实际版本一致（如 `app/__init__.py` 的 `__version__`）
- [ ] 包含功能特性表
- [ ] 包含"快速开始"章节（EXE 或 `pip install && python main.py`）
- [ ] 包含项目目录树说明
- [ ] GitHub 仓库首页能直接看懂项目是做什么的
- [ ] `.gitignore` 已正确配置（参考下方规则）

## 推送前必做：刷新版本信息

> **强制要求**：每次向 GitHub 推送代码前，必须同步刷新以下三处版本信息，确保版本号、日期和变更日志一致。

### 需要更新的文件

| 文件 | 更新内容 | 说明 |
|------|----------|------|
| `ai_translate_py/core/version.py` | `VERSION`、`VERSION_DATE`、`CHANGELOG` 列表头部插入新版本 | 源码中的版本权威来源，关于对话框读取此文件 |
| `README.md` | 顶部版本号标注、版本历史章节头部插入新版本 | GitHub 仓库首页展示 |
| `DOCUMENTATION.md` | 顶部版本号、6.x 关键功能实现记录章节 | 开发部署文档 |

### 版本号规则

- **主版本号（Major）**：架构级变更或不兼容更新
- **次版本号（Minor）**：新增功能模块
- **修订号（Patch）**：Bug 修复、小优化

### CHANGELOG 条目格式

```python
{
    "version": "1.2.0",
    "date": "2026-07-27",       # 当天日期
    "title": "简短标题",
    "changes": [
        "具体变更项1",
        "具体变更项2",
        ...
    ],
}
```

### 检查清单

推送前确认：
- [ ] `version.py` 中 `VERSION` 和 `VERSION_DATE` 已更新
- [ ] `version.py` 中 `CHANGELOG` 列表头部已插入新版本条目
- [ ] `README.md` 顶部版本号已更新
- [ ] `README.md` 版本历史章节已插入新版本
- [ ] `DOCUMENTATION.md` 顶部版本号已更新
- [ ] `DOCUMENTATION.md` 关键功能实现记录已添加新版本
- [ ] commit message 包含版本号（如 `v1.2.0: ...`）
