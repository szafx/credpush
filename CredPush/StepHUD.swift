import UIKit

/// 步骤提示卡片：切到别的 App 之前、切回来之后显示（App 内）。
/// 中国移动期间的进度用本地通知横幅（见 Notify）。
final class StepHUD: UIView {
    enum State { case pending, running, done, failed }

    struct Step {
        var title: String
        var state: State = .pending
    }

    private let card = UIView()
    private let titleLabel = Theme.label("", size: 16, weight: .semibold)
    private let subLabel = Theme.label("", size: 12, color: Theme.dim, lines: 2)
    private let rowStack = UIStackView()
    private var rows: [(dot: UIView, label: UILabel)] = []
    private var countdownLabel: UILabel?
    private var steps: [Step] = []
    private var timer: Timer?
    private var elapsedTimer: Timer?
    private let timeLabel = Theme.label("00:00", size: 12, color: Theme.dim, mono: true)
    private var countdownEnd: Date?
    private var currentStep = -1
    private var stepStart = Date()
    private var onCancel: (() -> Void)?

    // MARK: - 显示

    static func show(in host: UIView, title: String, steps: [String],
                     cancelTitle: String? = "取消", onCancel: (() -> Void)? = nil) -> StepHUD {
        let hud = StepHUD(frame: host.bounds)
        hud.build(title: title, steps: steps, cancelTitle: cancelTitle, onCancel: onCancel)
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(hud)
        hud.alpha = 0
        UIView.animate(withDuration: 0.2) { hud.alpha = 1 }
        return hud
    }

    private func build(title: String, steps: [String], cancelTitle: String?, onCancel: (() -> Void)?) {
        self.onCancel = onCancel
        backgroundColor = UIColor.black.withAlphaComponent(0.55)

        card.backgroundColor = Theme.card
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.line.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.text = title
        subLabel.text = ""
        // 顶部右侧：已用计时
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        rowStack.axis = .vertical
        rowStack.spacing = 10
        self.steps = steps.map { Step(title: $0) }
        for s in steps {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 7
            dot.layer.borderWidth = 1.5
            dot.layer.borderColor = Theme.line.cgColor
            dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let l = Theme.label(s, size: 13, color: Theme.dim, lines: 2)
            let row = UIStackView(arrangedSubviews: [dot, l])
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .top
            rowStack.addArrangedSubview(row)
            rows.append((dot, l))
        }

        let headRow = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        headRow.axis = .horizontal
        headRow.spacing = 8
        headRow.alignment = .firstBaseline
        var views: [UIView] = [headRow, subLabel, rowStack]
        if let ct = cancelTitle {
            let btn = UIButton(type: .system)
            btn.setTitle(ct, for: .normal)
            btn.titleLabel?.font = Theme.rounded(13, .medium)
            btn.setTitleColor(Theme.muted, for: .normal)
            btn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            views.append(btn)
        }
        let col = UIStackView(arrangedSubviews: views)
        col.axis = .vertical
        col.spacing = 10
        col.setCustomSpacing(6, after: headRow)
        col.setCustomSpacing(16, after: subLabel)
        col.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col)

        // 每秒刷新已用时间
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let sec = max(0, Int(Date().timeIntervalSince(self.stepStart)))
            self.timeLabel.text = String(format: "%02d:%02d", sec / 60, sec % 60)
        }

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - 更新

    /// 标记第 index 步：前面全算完成，当前是运行中
    func setStep(_ index: Int, detail: String? = nil) {
        guard index < steps.count else { return }
        if index != currentStep {          // 换步 → 计时归零
            currentStep = index
            stepStart = Date()
            timeLabel.text = "00:00"
        }
        for i in 0..<steps.count {
            let st: State = i < index ? .done : (i == index ? .running : .pending)
            apply(i, st)
        }
        subLabel.text = detail ?? ""
        titleLabel.text = steps[index].title
    }

    func finish(_ ok: Bool, detail: String? = nil) {
        for i in 0..<steps.count { apply(i, ok ? .done : (steps[i].state == .done ? .done : .failed)) }
        subLabel.text = detail ?? ""
        titleLabel.text = ok ? "完成" : "未完成"
    }

    private func apply(_ i: Int, _ state: State) {
        guard i < rows.count else { return }
        steps[i].state = state
        let (dot, label) = rows[i]
        switch state {
        case .pending:
            dot.backgroundColor = .clear
            dot.layer.borderColor = Theme.line.cgColor
            label.textColor = Theme.dim
            label.font = Theme.rounded(13, .regular)
        case .running:
            dot.backgroundColor = Theme.cyan
            dot.layer.borderColor = Theme.cyan.cgColor
            label.textColor = Theme.text
            label.font = Theme.rounded(13, .semibold)
        case .done:
            dot.backgroundColor = Theme.green
            dot.layer.borderColor = Theme.green.cgColor
            label.textColor = Theme.muted
            label.font = Theme.rounded(13, .regular)
        case .failed:
            dot.backgroundColor = Theme.red
            dot.layer.borderColor = Theme.red.cgColor
            label.textColor = Theme.red
            label.font = Theme.rounded(13, .semibold)
        }
    }

    /// 倒计时（秒），用于「即将打开中国移动 3/2/1」
    func countdown(seconds: Int, onDone: @escaping () -> Void) {
        countdownEnd = Date().addingTimeInterval(Double(seconds))
        timer?.invalidate()
        tickCountdown(onDone: onDone)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickCountdown(onDone: onDone)
        }
    }

    private func tickCountdown(onDone: @escaping () -> Void) {
        guard let end = countdownEnd else { return }
        let left = end.timeIntervalSince(Date())
        if left <= 0 {
            timer?.invalidate()
            timer = nil
            onDone()
            return
        }
        subLabel.text = "即将切换 · \(Int(ceil(left)))"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func cancelTapped() {
        timer?.invalidate()
        dismiss()
        onCancel?()
    }

    func dismiss() {
        timer?.invalidate()
        elapsedTimer?.invalidate()
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
        }
    }

    deinit { timer?.invalidate(); elapsedTimer?.invalidate() }
}
