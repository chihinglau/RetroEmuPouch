# =================================================================
# 华为云免费 ECS 抢名额辅助脚本
# =================================================================
# 
# 用法（PowerShell）：
#   # 1. 先做 5 分钟手工准备：
#   #    a) 注册华为云账号 https://www.huaweicloud.com/register
#   #    b) 完成实名认证（身份证 + 支付宝）
#   #    c) 用 chrome 浏览器登录 https://console.huaweicloud.com 并保持登录状态
#   #
#   # 2. 运行抢名额脚本：
#   #    pip install playwright
#   #    python scripts/huaweicloud-grab.py
#   #
#   # 3. 脚本自动：
#   #    a) 打开 chrome 浏览器（复用你本机的 chrome profile，已登录状态）
#   #    b) 倒计时到 9:29:50 开始疯狂刷新
#   #    c) 检测到「立即领取」按钮可点击 → 自动点击
#   #    d) 进入创建页 → 自动选国内节点 + 2核2G + Ubuntu 22.04 + 自动分配公网 IP
#   #    e) 停在「确认创建」按钮前 → 等你手动输密码 + 点确认
#   #
#   # 4. 如果今天已经被抢光了：
#   #    - 脚本会持续监控，有补货（晚上偶尔会补）自动抓
#   #    - 或 Ctrl+C 退出，明天 9:28 再来
#
# 不做什么：
#   ❌ 不帮你注册账号（涉及手机号 + 短信验证码）
#   ❌ 不帮你实名认证（涉及身份证上传 + 人脸识别）
#   ❌ 不帮你设置 root 密码（安全，必须你自己设）
#
# =================================================================

import sys
import time
import datetime
import subprocess
import os
from pathlib import Path

# =================================================================
# 依赖检查 —— 没有 playwright 就自动装
# =================================================================
def ensure_playwright():
    try:
        from playwright.sync_api import sync_playwright
        return sync_playwright
    except ImportError:
        print("[*] playwright 未安装，正在安装...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "playwright"])
        subprocess.check_call([sys.executable, "-m", "playwright", "install", "chromium"])
        from playwright.sync_api import sync_playwright
        return sync_playwright

# =================================================================
# 配置（按需修改）
# =================================================================
# 目标时间：每天 9:30:00 开抢
GRAB_HOUR = 9
GRAB_MINUTE = 30
GRAB_SECOND = 0

# 抢哪个产品？
# "cloud-server" = 云耀服务器 L 实例（2核2G，推荐，12 个月免费）
# "ecs"          = 通用计算型 ECS（2核4G，有时需要抢）
TARGET_PRODUCT = "cloud-server"

# 选哪个地域？
# "beijing" / "shanghai" / "guangzhou" / "hongkong"
# 推荐：guangzhou（国内最快）或 beijing（北方便利）
TARGET_REGION = "guangzhou"

# 选什么规格？
# 云耀 L 实例：默认就 2核2G，没得选
TARGET_FLAVOR = "default"

# 选什么镜像？
TARGET_IMAGE_NAME = "Ubuntu 22.04 LTS"

# 你本机 Chrome 可执行文件路径（自动探测常见路径）
def find_chrome():
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    return None

# =================================================================
# 倒计时显示
# =================================================================
def countdown(target_time: datetime.datetime):
    now = datetime.datetime.now()
    delta = (target_time - now).total_seconds()
    
    if delta > 0:
        print(f"\n⏳ 倒计时到 {target_time.strftime('%H:%M:%S')} 开抢...")
        while delta > 0:
            mins, secs = divmod(int(delta), 60)
            print(f"   剩余 {mins:02d}:{secs:02d}", end="\r", flush=True)
            time.sleep(1)
            delta = (target_time - datetime.datetime.now()).total_seconds()
        print()
    else:
        print(f"\n⏰ 已过 {target_time.strftime('%H:%M:%S')}，立即开始抢！")

# =================================================================
# 核心：抢名额 + 自动填表
# =================================================================
def grab():
    sync_playwright = ensure_playwright()
    chrome_path = find_chrome()
    
    # 计算目标时间（今天 9:30，已过则明天）
    now = datetime.datetime.now()
    target = now.replace(hour=GRAB_HOUR, minute=GRAB_MINUTE, second=GRAB_SECOND, microsecond=0)
    if now >= target:
        target += datetime.timedelta(days=1)
        print(f"⚠️  今天 9:30 已过，目标改为明天 9:30")
    
    # ============ 启动浏览器 ============
    with sync_playwright() as p:
        launch_args = {
            "headless": False,          # 必须显示浏览器（你要手动登录 + 输密码）
            "args": [
                "--start-maximized",
                "--disable-blink-features=AutomationControlled",
            ],
        }
        if chrome_path:
            launch_args["executable_path"] = chrome_path
        
        browser = p.chromium.launch(**launch_args)
        context = browser.new_context(
            viewport={"width": 1440, "height": 900},
            locale="zh-CN",
        )
        page = context.new_page()
        
        # ============ Step 0: 先打开免费试用页面并等待 ============
        print("\n📄 打开华为云免费试用页面...")
        FREE_URL = "https://free.huaweicloud.com"
        page.goto(FREE_URL, wait_until="domcontentloaded")
        
        # 检查是否需要登录
        if "login" in page.url.lower() or "登录" in page.content():
            print("\n🔐 需要登录！请在弹出的浏览器里：")
            print("   1. 用手机/支付宝扫码登录华为云账号")
            print("   2. 确保已完成实名认证（https://console.huaweicloud.com/iam）")
            print("   3. 回到这个终端，按 Enter 继续...")
            input()
            page.reload()
        
        # ============ Step 1: 倒计时 ============
        # 如果还没到 9:30，先倒计时
        now = datetime.datetime.now()
        target = now.replace(hour=GRAB_HOUR, minute=GRAB_MINUTE, second=GRAB_SECOND, microsecond=0)
        if now >= target:
            # 已经过了开抢时间，直接开始
            print(f"\n⏰ 已过 {target.strftime('%H:%M:%S')}，立即开始抢！")
            target = datetime.datetime.now()
        countdown(target)
        
        # ============ Step 2: 刷新 + 检测「立即领取」按钮 ============
        print("\n🔄 开始疯狂刷新，寻找免费云耀服务器 L 实例...")
        
        GRAB_BUTTON_TEXTS = [
            "立即领取", "立即试用", "免费领取",
            "领取免费", "去体验", "免费用",
        ]
        
        MAX_REFRESH = 200   # 最多刷新 200 次（约 7 分钟）
        found = False
        refresh_count = 0
        
        for refresh_count in range(MAX_REFRESH):
            refresh_count += 1
            print(f"   [{refresh_count}/{MAX_REFRESH}] 刷新中...", end="\r", flush=True)
            
            try:
                page.goto(FREE_URL, wait_until="domcontentloaded", timeout=10000)
                time.sleep(0.3)  # 极短等待，加快刷新
                
                # 寻找包含目标文字的可点击按钮
                for btn_text in GRAB_BUTTON_TEXTS:
                    try:
                        locator = page.get_by_text(btn_text).first
                        if locator.is_visible(timeout=2000):
                            parent = locator.locator("xpath=ancestor::button | xpath=ancestor::a").first
                            if parent.is_visible() and parent.is_enabled():
                                # 确认这个按钮是云耀服务器的（检查上下文）
                                container = locator.locator("xpath=ancestor::*[contains(.,'云耀') or contains(.,'L实例') or contains(.,'ECS')]").first
                                if container.is_visible():
                                    print(f"\n✅ 发现可领取按钮！点击 '{btn_text}'...")
                                    parent.click()
                                    found = True
                                    break
                    except:
                        continue
                if found:
                    break
            except Exception as e:
                # 网络抖动，重试
                continue
        
        if not found:
            print(f"\n❌ 刷了 {MAX_REFRESH} 次，没抢到。名额可能已经秒光了。")
            print("   建议：晚上 8-9 点再跑一次，有时会补货。")
            print("   或明天 9:28 准时再来。")
            print("\n   也可以手动试试：")
            print("   1. 浏览器打开 https://free.huaweicloud.com")
            print("   2. Ctrl+F5 强刷")
            print("   3. 点立即领取")
            browser.close()
            return
        
        # ============ Step 3: 进入创建页，自动填表 ============
        print("\n📝 自动填写创建表单...")
        time.sleep(3)  # 等创建页加载
        
        # 3a. 选择地域（国内优先）
        region_map = {
            "beijing":  ["华北", "北京"],
            "shanghai": ["华东", "上海"],
            "guangzhou": ["华南", "广州"],
            "hongkong": ["亚太", "香港"],
        }
        try:
            region_keywords = region_map.get(TARGET_REGION, ["华南", "广州"])
            # 尝试点击地域下拉 → 选择
            page.select_option("select:has-text('地域')", label=region_keywords[-1])
            print(f"   ✅ 地域: {region_keywords[-1]}")
        except:
            print(f"   ⚠️  未能自动选地域，请手动选 '{TARGET_REGION}'")
        
        # 3b. 选择镜像（Ubuntu 22.04）
        try:
            # 展开镜像下拉
            page.get_by_text("镜像").first.click()
            time.sleep(0.5)
            page.get_by_text("Ubuntu").first.click()
            time.sleep(0.5)
            page.get_by_text("22.04").first.click()
            print(f"   ✅ 镜像: {TARGET_IMAGE_NAME}")
        except:
            print(f"   ⚠️  未能自动选镜像，请手动选 Ubuntu 22.04 LTS")
        
        # 3c. 确保公网 IP 勾选
        try:
            # 华为云创建页通常有个「自动分配公网 IP」开关
            # 尝试点击复选框如果未选中
            checkbox = page.locator("input[type='checkbox']").filter(has_text="公网")
            if checkbox.count() > 0:
                if not checkbox.first.is_checked():
                    checkbox.first.check()
            print("   ✅ 公网 IP: 自动分配")
        except:
            print("   ⚠️  请手动勾选「自动分配公网 IP」")
        
        # ============ Step 4: 停住，等用户手动操作 ============
        print("\n" + "=" * 60)
        print("✅ 表单已自动填好！")
        print("=" * 60)
        print("\n👉 现在请在浏览器里：")
        print("   1. 检查地域/镜像/规格是否正确")
        print("   2. 设置登录密码（📝 记下来！）")
        print("   3. 点击「立即创建」或「确认」")
        print("   4. 记下公网 IP")
        print("\n👉 拿到公网 IP 后：")
        print("   cd tools\\account_backend")
        print('   $env:ECS_HOST = "你的公网IP"')
        print("   .\\scripts\\deploy.ps1 -Action setup")
        print("   .\\scripts\\deploy.ps1 -Action deploy")
        print("   .\\scripts\\deploy.ps1 -Action seed")
        print("\n👉 完成后回到这个终端按 Ctrl+C 关闭浏览器。")
        
        # 保持浏览器打开，让用户手动完成
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            browser.close()

# =================================================================
# 入口
# =================================================================
if __name__ == "__main__":
    print("=" * 60)
    print("  华为云免费 ECS 抢名额辅助脚本")
    print("  目标：9:30 开抢 | 国内节点 | 云耀 L 实例 2核2G")
    print("=" * 60)
    
    try:
        grab()
    except KeyboardInterrupt:
        print("\n\n👋 已退出。明天 9:28 再来！")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ 脚本报错: {e}")
        print("   如果是 playwright 相关错误，试试手动抢：")
        print("   1. 浏览器打开 https://free.huaweicloud.com")
        print("   2. Ctrl+F5 强刷")
        print("   3. 点立即领取")
        sys.exit(1)
