import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }

    /// 相对亮度（0 黑 ~ 1 白）
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func f(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }
}

/// 外观：深色 / 浅色 / 黑白
enum ThemeMode: String, CaseIterable {
    case dark, light, mono
    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .mono: return "黑白"
        }
    }
}

/// 设计令牌：颜色随「外观」变化；改外观后由 AppDelegate 重建界面。
enum Theme {
    // MARK: - 外观

    private static let modeKey = "themeMode"

    static var mode: ThemeMode {
        get { ThemeMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    // MARK: - 颜色

    static var bg: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x0A0F16)
        case .light: return UIColor(hex: 0xF2F4F8)
        case .mono: return .black
        }
    }

    static var card: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x131A24)
        case .light: return .white
        case .mono: return UIColor(hex: 0x0E0E0E)
        }
    }

    static var cardHi: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x1A232F)
        case .light: return UIColor(hex: 0xE9EEF5)
        case .mono: return UIColor(hex: 0x1A1A1A)
        }
    }

    static var line: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x233044)
        case .light: return UIColor(hex: 0xD8DFE8)
        case .mono: return UIColor(hex: 0x2E2E2E)
        }
    }

    static var text: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0xE8EEF6)
        case .light: return UIColor(hex: 0x0F1822)
        case .mono: return .white
        }
    }

    static var muted: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x8FA0B6)
        case .light: return UIColor(hex: 0x5A6B7E)
        case .mono: return UIColor(hex: 0xB6B6B6)
        }
    }

    static var dim: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x5B6B80)
        case .light: return UIColor(hex: 0x8B98A8)
        case .mono: return UIColor(hex: 0x7C7C7C)
        }
    }

    /// 强调色（黑白模式下也保持语义，便于分辨状态）
    static var cyan: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x38C6F4)
        case .light: return UIColor(hex: 0x0B7FBF)
        case .mono: return .white
        }
    }

    static var green: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0x57D9A3)
        case .light: return UIColor(hex: 0x0F8A5B)
        case .mono: return UIColor(hex: 0xDADADA)
        }
    }

    static var amber: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0xFFB547)
        case .light: return UIColor(hex: 0xA86400)
        case .mono: return UIColor(hex: 0xA8A8A8)
        }
    }

    static var red: UIColor {
        switch mode {
        case .dark: return UIColor(hex: 0xFF6B6B)
        case .light: return UIColor(hex: 0xC0392B)
        case .mono: return UIColor(hex: 0xFFFFFF)   // 黑白模式用纯白 + 加粗区分
        }
    }

    /// 系统控件（弹窗、分段控件等）跟随外观
    static var uiStyle: UIUserInterfaceStyle {
        switch mode {
        case .light: return .light
        default: return .dark
        }
    }

    /// 在某个背景色上该用什么文字颜色（自动选黑/白，保证对比度）
    static func textOn(_ bgColor: UIColor) -> UIColor {
        return bgColor.luminance > 0.5 ? UIColor(hex: 0x0F1822) : .white
    }

    // MARK: - 字体

    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: d, size: size)
        }
        return base
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - 组件

    static func label(_ text: String = "", size: CGFloat = 14, weight: UIFont.Weight = .regular,
                      color: UIColor? = nil, mono: Bool = false, lines: Int = 1) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = mono ? Theme.mono(size, weight) : Theme.rounded(size, weight)
        l.textColor = color ?? Theme.text
        l.numberOfLines = lines
        return l
    }

    static func card(_ padding: CGFloat = 16) -> UIView {
        let v = UIView()
        v.backgroundColor = card
        v.layer.cornerRadius = 18
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = line.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layoutMargins = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        return v
    }

    static func pill(_ text: String, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = "  \(text)  "
        l.font = rounded(12, .semibold)
        l.textColor = color
        l.backgroundColor = color.withAlphaComponent(0.12)
        l.layer.cornerRadius = 9
        l.layer.cornerCurve = .continuous
        l.clipsToBounds = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    static func dot(_ color: UIColor, size: CGFloat = 8) -> UIView {
        let v = UIView()
        v.backgroundColor = color
        v.layer.cornerRadius = size / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: size).isActive = true
        v.heightAnchor.constraint(equalToConstant: size).isActive = true
        return v
    }

    static func hstack(_ views: [UIView], spacing: CGFloat = 8, align: UIStackView.Alignment = .center) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.spacing = spacing
        s.alignment = align
        return s
    }

    static func vstack(_ views: [UIView], spacing: CGFloat = 8, align: UIStackView.Alignment = .fill) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.spacing = spacing
        s.alignment = align
        return s
    }

    /// 圆角按钮：文字颜色自动按背景亮度选黑/白，避免"黑底黑字"
    static func roundedButton(_ title: String, color: UIColor,
                              target: Any?, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = rounded(15, .semibold)
        b.setTitleColor(textOn(color), for: .normal)
        b.backgroundColor = color
        b.layer.cornerRadius = 12
        b.layer.cornerCurve = .continuous
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }

    static func spacer() -> UIView {
        let v = UIView()
        v.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        return v
    }
}

/// 凭证「寿命条」——整个 App 的签名元素。
final class LifeBar: UIView {
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = Theme.line
        track.layer.cornerRadius = 2
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])
        fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0.01)
        fillWidth.isActive = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(hours: Int?, dead: Bool) {
        let h = max(0, hours ?? 0)
        let ratio = min(1.0, CGFloat(h) / 24.0)
        fillWidth.isActive = false
        fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.01, ratio))
        fillWidth.isActive = true
        if dead { fill.backgroundColor = Theme.red }
        else if h >= 18 { fill.backgroundColor = Theme.red }
        else if h >= 12 { fill.backgroundColor = Theme.amber }
        else { fill.backgroundColor = Theme.cyan }
    }
}
