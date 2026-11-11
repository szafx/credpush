import Foundation

/// ⚠️ 这个文件在仓库里是**空值占位**。
/// CI 构建前会用 GitHub Actions 的 Secrets 覆盖它（见 .github/workflows/build-ipa.yml），
/// 这样公开仓库里不会出现任何真实密钥。
enum Secrets {
    static let password = ""
    static let pushToken = ""
    static let tsAuthKey = ""
}
