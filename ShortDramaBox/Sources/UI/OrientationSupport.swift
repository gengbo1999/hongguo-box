import UIKit

/// 只在播放页临时放开横屏；其余页面保持竖屏。
///
/// iOS 的旋转不是「改个 View 的 frame」就行：必须同时改
/// `supportedInterfaceOrientations`（AppDelegate 读这里）并请求几何更新，
/// 否则系统仍按 Info.plist 的竖屏掩码把画面锁死。
enum OrientationSupport {
    /// AppDelegate 的 `supportedInterfaceOrientationsFor` 直接读它。
    static var mask: UIInterfaceOrientationMask = .portrait

    static var isLandscape: Bool { mask.contains(.landscape) }

    static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        guard let scene = activeScene else { return }
        let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { _ in
            // 旋转失败（例如设备被家长控制锁定）时保持原状，不弹错误打断播放。
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}