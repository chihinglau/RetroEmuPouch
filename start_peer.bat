@echo off
chcp 65001 >nul
REM ============================================================
REM  GamePouch —— PC 端「我的电脑」伙伴服务 一键启动
REM  双击运行：另开一个窗口常驻服务, 本窗口立即返回。
REM  用法(可选参数会原样传给 run_peer_server.py):
REM    start_peer.bat                        用内置测试库 .tools/gstest
REM    start_peer.bat --root "D:\你的库" --name "客厅电脑"
REM    start_peer.bat --no-mdns              仅 UDP 广播发现
REM  停止: 关闭「GamePouch 伙伴服务」窗口, 或在该窗口按 Ctrl+C。
REM  日志: tools/library/peer_server.log
REM ============================================================
setlocal
cd /d "%~dp0"
if not exist tools\library\run_peer_server.py (
    echo 找不到 tools\library\run_peer_server.py
    echo 请把本 start_peer.bat 放在仓库根目录(RetroEmuPouch\\)下再双击。
    pause
    exit /b 1
)
start "GamePouch 伙伴服务" cmd /k "python tools\library\run_peer_server.py %* & echo. & echo [已停止] 关闭本窗口即可停止服务 & pause"
endlocal
