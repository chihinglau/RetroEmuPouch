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
}
