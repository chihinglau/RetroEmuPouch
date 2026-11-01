"""Seed data —— 首次部署时写入 CMS 文档和 AppConfig 默认值。"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from ..models import AppConfig, CmsDocument


def _insert_if_missing(db: Session, model, **filter_kwargs):
    row = db.query(model).filter_by(**filter_kwargs).first()
    if row:
        return False
    db.add(model(**filter_kwargs))
    return True


def seed_app_configs(db: Session) -> int:
    """写入 LegalConstants 全部静态项的默认值到 app_configs。"""
    defaults: list[tuple[str, str, str]] = [
        ("filing_number", "", "工信部 APP 备案号"),
        ("feedback_url", "https://github.com/chihinglau/RetroEmuPouch/issues", "用户反馈入口"),
        ("feedback_email", "support@retroemupouch.example.com", "客服邮箱"),
        ("qq_group", "123456789", "官方 QQ 群号"),
        ("wechat_id", "RetroEmuPouch", "官方微信号 / 公众号"),
        ("share_message", "趣玩匣 RetroEmuPouch —— 手机上的复古游戏机，重拾时光里的欢喜！", "分享应用文案"),
        ("enable_consent_gate", "true", "是否启用首次启动同意门禁"),
        ("ad_sdk_consent_required", "false", "是否要求个性化广告同意（合规）"),
    ]
    count = 0
    for key, val, desc in defaults:
        if _insert_if_missing(db, AppConfig, config_key=key, config_value=val, description=desc):
            count += 1
    db.commit()
    return count


def seed_cms_documents(db: Session) -> int:
    """写入隐私政策 + 用户协议 zh/en 默认草稿。"""
    count = 0

    PRIVACY_ZH = """# 隐私政策

**趣玩匣 RetroEmuPouch**（以下简称"本应用"）非常重视您的隐私。本政策说明我们如何收集、使用与保护您的数据。

## 一、我们收集的信息

- **账号信息**：您注册时提供的邮箱地址、昵称。
- **设备信息**：设备型号、操作系统版本、唯一标识（用于防止滥用）。
- **订阅信息**：您购买会员的订单记录（通过 Google Play / 华为应用市场计费）。
- **游戏数据**：本应用**不自动上传**任何 ROM / BIOS 文件。存档与设置仅在您主动开启"云同步"时经加密通道上传。

## 二、我们**不收集**的信息

- 任何 ROM / BIOS / 游戏本体二进制文件。
- 您本地存储的游戏列表以外的文件。

## 三、我们如何使用信息

- 提供账号注册、登录、会员权益服务。
- 防止欺诈、滥用行为。
- 改善产品体验（匿名统计）。

## 四、数据保护

- 所有云端数据传输使用 HTTPS 加密。
- 云存档由客户端 AES-256-GCM 加密后上传，服务端不解密。
- 我们不会与任何第三方共享您的个人信息，除非法律要求。

## 五、您的权利

- 您可以随时在应用内删除账号。
- 您可以随时撤回同意并清除本地数据。

## 六、未成年人保护

- 本应用不对 14 周岁以下未成年人开放订阅服务。

最后更新：2026-11-02
"""

    PRIVACY_EN = """# Privacy Policy

RetroEmuPouch ("this App") values your privacy. This policy explains how we collect, use, and protect your data.

## 1. Information We Collect

- **Account information**: email address and nickname provided at registration.
- **Device information**: device model, OS version, unique identifiers (to prevent abuse).
- **Subscription information**: your membership orders (billed through Google Play / Huawei AppGallery).
- **Game data**: this App does **not** auto-upload ROM or BIOS files. Saves and settings are uploaded only when you enable "cloud sync", via an encrypted channel.

## 2. Information We Do NOT Collect

- Any ROM / BIOS / game binary files.
- Any files outside your local game library.

## 3. How We Use Information

- To provide account registration, login, and membership services.
- To prevent fraud and abuse.
- To improve the product (anonymous statistics).

## 4. Data Protection

- All cloud data uses HTTPS encryption in transit.
- Cloud saves are encrypted client-side with AES-256-GCM before upload; we cannot decrypt them.
- We will not share your personal information with third parties unless required by law.

## 5. Your Rights

- You may delete your account at any time from within the App.
- You may withdraw consent and clear local data at any time.

## 6. Minors

- This App does not offer subscriptions to users under 14.

Last updated: 2026-11-02
"""

    EULA_ZH = """# 用户协议

**趣玩匣 RetroEmuPouch** 允许您在遵守本协议的前提下使用本应用。

## 一、许可范围

本应用是一款前端模拟器播放器。**我们不提供任何游戏、ROM 或 BIOS 文件**。您须自行导入合法持有版权的游戏资源。

## 二、您的义务

- 您须确保导入的游戏资源来源合法，不侵犯任何第三方版权。
- 您不得将本应用用于任何违反当地法律法规的用途。
- 您不得对本应用进行反向工程、反编译、反汇编。

## 三、免责声明

- 本应用按"现状"提供，不保证适用于特定用途。
- 您因使用不合法的游戏资源所引发的一切纠纷和责任，由您自行承担。
- 我们不对因使用本应用直接或间接造成的任何损失负责。

## 四、知识产权

本应用的软件代码、界面设计、品牌名称等知识产权均归开发者所有。

## 五、协议变更

我们可能不定期更新本协议。重大变更将在应用内显著提示。

最后更新：2026-11-02
"""

    EULA_EN = """# End-User License Agreement

RetroEmuPouch grants you a non-exclusive license to use the App under this agreement.

## 1. Scope of License

The App is a front-end emulator player. **We do not distribute any games, ROMs, or BIOS files**. You must import game content that you lawfully own.

## 2. Your Obligations

- You are solely responsible for ensuring the content you import is legally obtained and does not infringe any third-party rights.
- You must not use this App for any purpose that violates local laws.
- You must not reverse engineer, decompile, or disassemble this App.

## 3. Disclaimers

- The App is provided "as is" without warranties of any kind.
- You are solely responsible for any disputes arising from the content you import.
- We are not liable for any direct or indirect damages caused by using this App.

## 4. Intellectual Property

All code, UI design, branding, and related intellectual property belong to the developer.

## 5. Changes to This Agreement

We may update this agreement from time to time. Material changes will be prominently posted in the App.

Last updated: 2026-11-02
"""

    docs = [
        ("privacy_policy", "zh", 1, "隐私政策", PRIVACY_ZH, "首版隐私政策"),
        ("privacy_policy", "en", 1, "Privacy Policy", PRIVACY_EN, "First release"),
        ("eula", "zh", 1, "用户协议", EULA_ZH, "首版用户协议"),
        ("eula", "en", 1, "End-User License Agreement", EULA_EN, "First release"),
    ]

    for doc_key, lang, ver, title, content, summary in docs:
        exists = (
            db.query(CmsDocument)
            .filter(
                CmsDocument.doc_key == doc_key,
                CmsDocument.language == lang,
                CmsDocument.status == "published",
            )
            .first()
        )
        if exists:
            continue
        doc = CmsDocument(
            id=str(uuid.uuid4()),
            doc_key=doc_key,
            version=ver,
            language=lang,
            title=title,
            content=content,
            summary=summary,
            status="published",
            published_at=datetime(2026, 11, 2, tzinfo=timezone.utc),
            created_at=datetime(2026, 11, 2, tzinfo=timezone.utc),
            updated_at=datetime(2026, 11, 2, tzinfo=timezone.utc),
        )
        db.add(doc)
        count += 1

    db.commit()
    return count


def run_seed(db: Session) -> dict:
    from datetime import datetime, timezone
    import uuid
    return {
        "app_configs_seeded": seed_app_configs(db),
        "cms_docs_seeded": seed_cms_documents(db),
    }
