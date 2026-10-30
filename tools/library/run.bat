@echo off
chcp 65001 >nul 2>&1
setlocal
rem 趣玩匣 GamePouch · 本地游戏库管理 (双击启动)
set "SCRIPT=%~dp0library_manager.py"
if not exist "%SCRIPT%" (
  echo 未找到 library_manager.py
  pause
  exit /b 1
)
python "%SCRIPT%"
if errorlevel 1 (
  echo.
  echo 运行失败, 请确认已安装 Python 3 并在 PATH 中可用。
  pause
)
endlocal
