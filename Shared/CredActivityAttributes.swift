import ActivityKit
import Foundation

/// App 与灵动岛扩展共享的活动属性。
/// ★ 这个文件必须同时加进 App target 和 Widget Extension target。
@available(iOS 16.1, *)
struct CredActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0-based 步骤序号
        var step: Int
        /// 顶部短语（灵动岛紧凑视图会显示很短的这条）
        var short: String
        /// 详细说明（展开时显示）
        var detail: String
        /// **本步骤**开始的时刻（每换一步就重置，计时器从这里走）
        var stepStartedAt: Date
    }

    /// 目标账号（手机号或容器名）
    var name: String
    /// App 的 build 号（诊断用：灵动岛展开后右下角会显示 `v1.0.xxxx`，
    /// 用来确认渲染的是不是最新一版 Widget —— 旧版不显示这个）
    var build: String = ""
}
