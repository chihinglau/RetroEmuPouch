@echo off
REM =================================================================
REM RetroEmuPouch 后端 —— D 盘目录初始化
REM 用法：双击运行 或 cmd 执行: scripts\init-d-drive.bat
REM 效果：在 D:\RetroEmuPouch\ 下创建完整目录结构
REM =================================================================

echo.
echo ╔══════════════════════════════════════════════════════╗
echo ║  RetroEmuPouch 后端 —— D 盘专属目录初始化              ║
echo ╚══════════════════════════════════════════════════════╝
echo.

set "ROOT=D:\RetroEmuPouch"

echo 📁 创建目录结构...

mkdir "%ROOT%" 2>nul
mkdir "%ROOT%\backend" 2>nul
mkdir "%ROOT%\backend\postgres-data" 2>nul
mkdir "%ROOT%\backend\sqlite" 2>nul
mkdir "%ROOT%\backend\logs" 2>nul
mkdir "%ROOT%\backend\backups" 2>nul
mkdir "%ROOT%\backend\uploads" 2>nul
mkdir "%ROOT%\tunnel" 2>nul
mkdir "%ROOT%\tunnel\cloudflared" 2>nul
mkdir "%ROOT%\tunnel\cpolar" 2>nul
mkdir "%ROOT%\runtime" 2>nul

echo.
echo ✅ 目录结构已就绪：
echo.
echo    %ROOT%\
echo    ├── backend\
echo    │   ├── postgres-data\      ← PostgreSQL 数据卷
echo    │   ├── sqlite\             ← SQLite dev.db
echo    │   ├── logs\               ← 后端日志
echo    │   ├── backups\           ← 数据库备份
echo    │   └── uploads\            ← 云存档临时文件
echo    ├── tunnel\
echo    │   ├── cloudflared\        ← Cloudflare Tunnel 配置/证书
echo    │   └── cpolar\             ← cpolar 配置
echo    └── runtime\                ← 临时文件 / PID
echo.

REM 写入 README 说明
echo # RetroEmuPouch Backend Data > "%ROOT%\README.txt"
echo. >> "%ROOT%\README.txt"
echo 此目录存放后端服务的所有数据 >> "%ROOT%\README.txt"
echo 项目源码位置: D:\ai\prj\trae\HuaWei\RetroEmuPouch >> "%ROOT%\README.txt"
echo. >> "%ROOT%\README.txt"
echo 启动方式: >> "%ROOT%\README.txt"
echo   本地 dev:  python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 >> "%ROOT%\README.txt"
echo   穿透:     .\scripts\tunnel.ps1 -Provider cloudflare >> "%ROOT%\README.txt"
echo.

echo ✅ 完成！现在可以启动后端了。
echo.
pause
