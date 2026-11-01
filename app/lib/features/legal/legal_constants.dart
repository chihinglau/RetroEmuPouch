/// 合规与法务相关常量（发布相关）。
///
/// 这些值与发布流程强相关，集中管理便于一处修改、双端（Android / OHOS）共用。
class LegalConstants {
  /// 公网可访问的隐私政策 URL。
  ///
  /// 用途：APP 备案、Google Play Data Safety 表单、应用内"网页版隐私政策"入口。
  /// 部署方式见 `docs/release-plan.md` 缺口 4：将仓库内的 `docs/privacy.md`
  /// 托管到 GitHub Pages（默认 Pages 源 = 仓库 `/docs` 目录），
  /// 即可通过 `https://<user>.github.io/GamePouch/privacy` 访问。
  static const String privacyPolicyUrl =
      'https://chihinglau.github.io/GamePouch/privacy';

  /// 工信部 APP 备案号。
  ///
  /// 备案通过后回填（见 `docs/release-plan.md` 缺口 3）。
  /// 空字符串表示"备案中"，UI 显示占位提示而非空白，避免上架前界面出现空字段。
  static const String filingNumber = '';

  /// 用户反馈入口（GitHub Issues）。设置页「意见反馈 / 客服中心」复制给用户，
  /// 在浏览器打开即可提反馈；后续可替换为邮箱或工单系统（发布时一处改）。
  static const String feedbackUrl =
      'https://github.com/chihinglau/RetroEmuPouch/issues';

  /// 「分享应用」推荐文案（剪贴板分享——无 share 插件时的零依赖实现）。
  static const String shareMessage =
      '趣玩匣 RetroEmuPouch —— 手机上的复古游戏机，重拾时光里的欢喜！';

  /// 客服邮箱（意见反馈 → 发送邮件；无 url_launcher，复制给用户去邮箱发送）。
  static const String feedbackEmail = 'support@retroemupouch.example.com';

  /// 官方 QQ 群号（意见反馈 → QQ群反馈；复制后加群）。
  static const String qqGroup = '123456789';

  /// 官方微信号 / 公众号（意见反馈 → 微信反馈；复制后添加）。
  static const String wechatId = 'RetroEmuPouch';
}
