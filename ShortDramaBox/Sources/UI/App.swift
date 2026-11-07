import SwiftUI
import UIKit

/// 只做一件事：把「当前允许哪些方向」交给 OrientationSupport。
/// 默认竖屏；播放页点横屏按钮时才临时放开。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationSupport.mask
    }
}

@main
struct DuanjuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() { HGLog.start() }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var tab = 0
    @ObservedObject private var follows = FollowStore.shared

    var body: some View {
        // 记录当前选中的 Tab：推荐页要在切走时停掉后台预取，
        // 否则人在详情页时它还在下两三路 1080p，把带宽占满。
        TabView(selection: $tab) {
            FeedView(active: tab == 0).tag(0)
                .tabItem { Label("推荐", systemImage: "play.rectangle.fill") }
            HomeView().tag(1).tabItem { Label("首页", systemImage: "house.fill") }
            BrowseView().tag(2).tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
            SearchView().tag(3).tabItem { Label("搜索", systemImage: "magnifyingglass") }
            HistoryView().tag(4).tabItem { Label("记录", systemImage: "clock.fill") }
                .badge(follows.updateCount)
        }
        .tint(.pink)
        .task { await follows.refreshAll() }
        .onChange(of: tab) { t in HGLog.i("界面", "切到第 \(t) 个 Tab") }
    }
}
