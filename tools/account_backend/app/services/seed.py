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
        ("feedback_email", "251266110@qq.com", "客服邮箱"),
        ("qq_group", "251266110", "客服 QQ 号（与 AGC 客服QQ 一致）"),
        ("wechat_id", "RetroEmuPouch", "官方微信号 / 公众号"),
        ("share_message", "趣玩匣 RetroEmuPouch —— 手机上的复古游戏机，重拾时光里的欢喜！", "分享应用文案"),
        ("privacy_policy_url", "https://api.gamepouch.cn/privacy", "隐私政策网页版 URL（应用商店提交 / 应用内跳转）"),
        ("terms_url", "https://api.gamepouch.cn/terms", "用户协议网页版 URL（应用商店提交 / 应用内跳转）"),
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
    """写入 / 更新隐私政策 + 用户协议 zh/en 已发布文档。

    已存在同 doc_key+language 的已发布文档时，若目标版本更高则就地更新
    （标题 / 正文 / 摘要 / 版本号 / 发布时间），方便重新部署时刷新文案；
    版本号升级会触发 App 端 ConsentGate 重新征求同意。
    """
    count = 0
    now = datetime(2026, 11, 4, tzinfo=timezone.utc)

    PRIVACY_ZH = """# 隐私政策

生效日期：2026 年 11 月 4 日
最后更新：2026 年 11 月 4 日

感谢您使用「趣玩匣 RetroEmuPouch」（以下简称"本应用"或"我们"）。我们深知个人信息对您的重要性，并会尽力保护您的隐私。请您在使用前仔细阅读本政策。

> **运营主体**：【请填写运营主体全称，例如：XX 科技有限公司】
> **注册地址**：【请填写】
> **联系邮箱**：251266110@qq.com（亦可从应用内"设置 → 关于"获取）
> **应用备案号**：【请填写，对应后台 AppConfig.filing_number】

## 一、我们收集的信息

1. **账号信息**：您注册时主动提供的邮箱地址、昵称。
2. **设备信息**：设备型号、操作系统版本、用于防刷的匿名设备标识（仅以哈希形式存储）。
3. **交易与订阅信息**：您购买会员的订单记录（商品名称、时间、金额区间）；支付由 Google Play / 华为应用市场完成，我们**不存储您的银行卡号或支付凭证**。
4. **游戏与存档数据**：本应用**不会自动上传任何 ROM / BIOS / 游戏本体文件**。仅在您主动开启"云存档"功能时，您选定的存档文件会经**客户端加密**后上传至我们的服务器（详见第三节）。
5. **日志信息**：为排查故障与安全防护，我们记录必要的访问日志（时间、匿名化的 IP 哈希、请求路径），保留不超过 30 天。

## 二、我们如何使用信息

- 提供账号注册、登录、会员权益发放与校验；
- 防止欺诈、盗号与滥用行为；
- 在您授权前提下，发送必要的服务通知（如会员到期提醒）；
- 以匿名、聚合形式改善产品体验（不进行个体画像追踪）。

## 三、信息的存储与安全

- **传输安全**：所有云端通信使用 HTTPS（TLS）加密传输。
- **云存档客户端加密**：云存档在您的设备上进行 AES-256-GCM 加密后上传，**密钥由您设定的云存档密码派生，服务端不持有、也无法解密您的存档内容**。忘记密码将导致存档无法恢复。
- **存储期限**：账号信息在您账号存续期间保留；注销账号后，我们会在 30 日内删除您的个人数据及云存档密文。日志信息保留不超过 30 天。
- **访问控制**：仅有必要的运维人员可在受限环境下访问生产数据，且受审计约束。

## 四、信息共享与披露

- 我们**不会**将您的个人信息出售或提供给第三方用于营销。
- 支付相关敏感信息由 Google / 华为等应用商店处理，我们不接触您的支付凭证。
- 仅在法律法规要求、或为保护本应用及用户合法权益所必需时，我们才会依法披露相关信息。

## 五、第三方服务

本应用可能集成以下第三方服务（以您实际使用的平台为准）：

- **Google Play Billing / 华为应用内支付**：用于会员购买与校验；
- **应用商店推送与安全组件**：由对应平台提供。

我们建议一并查阅上述第三方的隐私政策。

## 六、您的权利

您对自己的个人信息享有充分的控制权：

- 查阅、更正您的账号资料；
- 随时**删除云存档**或**注销账号**（注销将一并删除服务端个人数据）；
- 撤回您此前作出的同意（撤回不影响撤回前基于同意已开展的处理）；
- 如您对个人信息处理有异议，可通过上述邮箱联系我们。

## 七、未成年人保护

本应用主要面向成年用户。我们不向 14 周岁以下未成年人开放订阅与付费服务；若发现未成年人误注册，监护人可申请注销并删除相关数据。

## 八、政策的变更

我们可能根据法律法规或业务调整更新本政策。重大变更将通过应用内公告等方式通知；若变更涉及核心权益，您可能需要重新确认同意。

## 九、联系方式

如对本政策有任何疑问，请通过邮箱 251266110@qq.com 联系我们。

## 十、法律适用

本政策的订立、执行与争议解决均适用中华人民共和国大陆地区法律；如有争议，双方应友好协商，协商不成的，提交运营主体所在地有管辖权的人民法院诉讼解决。
"""

    PRIVACY_EN = """# Privacy Policy

Effective: 2026-11-04
Last updated: 2026-11-04

Thank you for using RetroEmuPouch ("this App" or "we"). We highly value your privacy and strive to protect it. Please read this policy carefully before use.

> **Operator**: [fill in the full legal entity name]
> **Registered address**: [fill in]
> **Contact email**: 251266110@qq.com
> **Filing number**: [fill in, corresponds to AppConfig.filing_number]

## 1. Information We Collect

1. **Account information**: email address and nickname you provide at registration.
2. **Device information**: device model, OS version, and anonymized device identifiers (stored only as hashes) used for abuse prevention.
3. **Transaction & subscription information**: records of your membership orders (product name, time, amount range). Payments are processed by Google Play / Huawei AppGallery; we do **not** store your card numbers or payment credentials.
4. **Game & save data**: this App does **not** automatically upload any ROM / BIOS / game binaries. Only when you explicitly enable "cloud save" are the save files you choose encrypted **on your device** and uploaded to our servers (see Section 3).
5. **Log information**: for troubleshooting and security, we keep necessary access logs (timestamp, anonymized IP hash, request path) for no more than 30 days.

## 2. How We Use Information

- To provide account registration, login, and membership entitlement services;
- To prevent fraud, account theft, and abuse;
- To send necessary service notifications (e.g., membership expiry) with your consent;
- To improve the product using anonymized, aggregated statistics (no individual profiling).

## 3. Storage & Security

- **Transport security**: all cloud communication uses HTTPS (TLS).
- **Client-side encryption**: cloud saves are encrypted on your device with AES-256-GCM before upload. **The key is derived from the cloud-save password you set; the server never holds and cannot decrypt your save contents.** Losing the password makes saves unrecoverable.
- **Retention**: account data is kept while your account is active; after account deletion we remove your personal data and encrypted saves within 30 days. Logs are kept no more than 30 days.
- **Access control**: only necessary operations staff may access production data under restricted, audited conditions.

## 4. Sharing & Disclosure

- We do **not** sell or provide your personal information to third parties for marketing.
- Payment credentials are handled by Google / Huawei app stores; we never touch them.
- We disclose information only when required by law or necessary to protect the App and its users.

## 5. Third-Party Services

This App may integrate: Google Play Billing / Huawei IAP (membership purchase & verification); app-store push & security components. Please also review those providers' privacy policies.

## 6. Your Rights

You control your personal data: review/correct your profile; delete cloud saves or **delete your account** (which also removes server-side personal data); withdraw previously given consent; contact us at 251266110@qq.com for any concern.

## 7. Minors

This App is primarily for adults. We do not offer subscriptions or paid services to users under 14. Guardians may request deletion of a minor's data.

## 8. Changes

We may update this policy. Material changes will be notified in-app; core changes may require re-confirmation of consent.

## 9. Contact

Questions? Email 251266110@qq.com.

## 10. Governing Law

This policy is governed by the laws of mainland China; disputes are resolved by the competent court at the operator's location.
"""

    EULA_ZH = """# 用户协议

生效日期：2026 年 11 月 4 日
最后更新：2026 年 11 月 4 日

欢迎使用「趣玩匣 RetroEmuPouch」（以下简称"本应用"）。在使用前，请您仔细阅读并理解本协议。

> **运营主体**：【请填写运营主体全称】
> **联系邮箱**：251266110@qq.com

## 一、软件许可

1. 我们授予您一项**非独占、可撤销、不可转让**的许可，供您在本应用上个人、非商业地使用本软件。
2. 本应用是一款**模拟器前端播放器**。**我们不提供、不分发任何游戏、ROM 或 BIOS 文件**；您须自行导入您合法持有版权的游戏资源。

## 二、使用规范

您承诺：

- 仅导入来源合法、不侵犯任何第三方版权的游戏资源；
- 不得将本应用用于任何违反当地法律法规的用途；
- 不得对本应用进行反向工程、反编译、反汇编，或移除其版权标识；
- 不得以商业目的转售、出租或再分发本应用。

## 三、知识产权

1. 本应用的软件代码、界面设计、品牌名称与标识等知识产权归开发者所有，受相关法律法规保护。
2. 本应用所集成的第三方模拟器核心（如基于 libretro 的开源核心）遵循其各自的开放源代码许可（如 GPL / LGPL 等）；您使用相关核心时亦须遵守对应许可证条款。

## 四、会员与虚拟权益

1. 会员（含普通 VIP / 超级 VIP 等）为**虚拟增值服务**，一经购买通常不支持退款（法定情形除外）。
2. 会员权益（如去除广告、云存档等）以应用内实际展示与后端下发为准；我们保留根据运营需要调整的权限，但会保障已购用户的合理既有权益。

## 五、免责声明

本应用按"现状"提供，不作出任何明示或暗示的保证。特别地：

- 我们不对特定游戏在本应用上的运行效果、兼容性作出保证；
- 您因导入或使用不合法的游戏资源所引发的一切版权纠纷与法律责任，由您自行承担；
- 在法律允许的最大范围内，我们不对因使用或无法使用本应用而造成的任何直接、间接损失负责。

## 六、违约与终止

如您违反本协议，我们可中止或终止向您提供部分或全部服务，并不退还已支付的费用（如适用）。

## 七、协议变更

我们可能不时更新本协议，更新后将通过应用内公告等方式提示。您继续使用本应用即视为接受更新后的协议。

## 八、争议解决与法律适用

本协议的订立、执行与争议解决适用中华人民共和国大陆地区法律；如有争议，协商不成的，提交运营主体所在地有管辖权的人民法院诉讼解决。

## 九、联系方式

如有疑问，请联系 251266110@qq.com。
"""

    EULA_EN = """# End-User License Agreement

Effective: 2026-11-04
Last updated: 2026-11-04

Welcome to RetroEmuPouch ("this App"). Please read and understand this agreement before use.

> **Operator**: [fill in the full legal entity name]
> **Contact email**: 251266110@qq.com

## 1. License Grant

1. We grant you a **non-exclusive, revocable, non-transferable** license to use this software for personal, non-commercial purposes.
2. This App is an **emulator front-end player**. **We do not provide or distribute any games, ROMs, or BIOS files**; you must import game content you lawfully own.

## 2. Usage Rules

You agree to: import only legally obtained content that does not infringe third-party rights; not use this App for any unlawful purpose; not reverse engineer, decompile, or disassemble it; not resell, rent, or redistribute it commercially.

## 3. Intellectual Property

1. The software code, UI design, brand names, and marks are owned by the developer and protected by law.
2. Third-party emulator cores integrated (e.g., libretro-based open-source cores) are governed by their own open-source licenses (GPL / LGPL, etc.); by using them you also agree to those licenses.

## 4. Membership & Virtual Benefits

1. Membership (e.g., standard / super VIP) is a **virtual value-added service**, generally non-refundable once purchased (except where required by law).
2. Membership benefits (ad removal, cloud save, etc.) are as shown in-app and granted by the backend; we may adjust them operationally while protecting already-purchased users' reasonable entitlements.

## 5. Disclaimers

This App is provided "as is" without warranties. In particular: we do not warrant that any specific game runs correctly; you bear all responsibility for copyright disputes arising from content you import; to the maximum extent permitted by law, we are not liable for any direct or indirect damages from using this App.

## 6. Breach & Termination

If you breach this agreement, we may suspend or terminate part or all of the services without refunding fees already paid (where applicable).

## 7. Changes

We may update this agreement from time to time and notify you in-app. Continued use constitutes acceptance of the updated terms.

## 8. Dispute Resolution & Governing Law

This agreement is governed by the laws of mainland China; unresolved disputes are submitted to the competent court at the operator's location.

## 9. Contact

Questions? Email 251266110@qq.com.
"""

    docs = [
        ("privacy_policy", "zh", 2, "隐私政策", PRIVACY_ZH, "2026-11-04 合规升级版"),
        ("privacy_policy", "en", 2, "Privacy Policy", PRIVACY_EN, "Compliance update 2026-11-04"),
        ("eula", "zh", 2, "用户协议", EULA_ZH, "2026-11-04 合规升级版"),
        ("eula", "en", 2, "End-User License Agreement", EULA_EN, "Compliance update 2026-11-04"),
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
            if exists.version < ver:
                exists.version = ver
                exists.title = title
                exists.content = content
                exists.summary = summary
                exists.published_at = now
                exists.updated_at = now
                count += 1
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
            published_at=now,
            created_at=now,
            updated_at=now,
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
