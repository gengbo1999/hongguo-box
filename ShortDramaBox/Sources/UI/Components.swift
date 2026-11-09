import Foundation
import SwiftUI

/// 观看进度 / 历史（本地持久化）
final class WatchStore: ObservableObject {
    static let shared = WatchStore()
    struct Item: Codable, Identifiable {
        var id: String { seriesId }
        let seriesId: String
        var title: String
        var cover: String
        var episode: Int
        var seconds: Double
        var updated: Date
    }
    @Published private(set) var items: [Item] = []
    private let key = "watch_history"

    init() { load() }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Item].self, from: d) else { return }
        items = v.sorted { $0.updated > $1.updated }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    func progress(seriesId: String) -> Item? { items.first { $0.seriesId == seriesId } }
    func record(seriesId: String, title: String, cover: String, episode: Int, seconds: Double) {
        var list = items.filter { $0.seriesId != seriesId }
        list.insert(Item(seriesId: seriesId, title: title, cover: cover,
                         episode: episode, seconds: seconds, updated: Date()), at: 0)
        items = Array(list.prefix(100)); save()
    }
    func remove(seriesId: String) {
        items.removeAll { $0.seriesId == seriesId }; save()
    }
    func clear() { items = []; save() }
}

struct PosterCard: View {
    let series: Series
    var width: CGFloat = 120
    var progressText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: series.cover)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
                    }
                }
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    SourceBadge(series: series).padding(5)
                }
                if let t = progressText ?? (series.rightText.isEmpty ? nil : series.rightText) {
                    Text(t).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            }
            Text(series.title).font(.system(size: 12)).lineLimit(2)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: width, alignment: .leading)
        }
    }
}



// MARK: - 来源标记

extension Series {
    /// 归一化来源：老数据没有 source 字段，按 id 前缀兜底。
    var sourceKind: String {
        if !source.isEmpty { return source }
        if id.hasPrefix("dy:") { return "dy" }
        return "hg"
    }

    var sourceName: String {
        switch sourceKind {
        case "dy": return "抖音"
        default: return "红果"
        }
    }

    var sourceSymbol: String {
        switch sourceKind {
        case "dy": return "music.note"
        default: return "play.rectangle.fill"
        }
    }

    var sourceTint: Color {
        switch sourceKind {
        case "dy": return Color(red: 0.10, green: 0.78, blue: 0.85)
        default: return Color(red: 0.95, green: 0.35, blue: 0.25)
        }
    }
}

/// 封面/详情用的小标签：图标 + 文字，一眼区分红果 / 抖音。
struct SourceBadge: View {
    let series: Series
    var fontSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: series.sourceSymbol)
                .font(.system(size: fontSize - 1, weight: .bold))
            Text(series.sourceName)
                .font(.system(size: fontSize, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(series.sourceTint.opacity(0.92))
        .clipShape(Capsule())
    }
}

/// 选集档位缓存 + 批量预取。
///
/// 官方批量接口 `mixed_video_id_map` 一次能取 5 个 vid 的档位。
/// 播放页拿它把后面几集的地址提前取好，滑到下一集就不用再等一次
/// 「获取播放地址…」；顺手把下一集的片子也预下载解密好，切集直接开播。
final class TrackCache: @unchecked Sendable {
    static let shared = TrackCache()
    private let lock = NSLock()
    /// 缓存上限：一集档位约 1KB，60 集也就几十 KB，不会成为内存负担
    private let cap = 60
    private var store: [String: [VideoTrack]] = [:]
    private var order: [String] = []
    /// 已经试过但没拿到的 vid：别反复打接口
    private var tried: Set<String> = []
    private var inFlight: Set<String> = []

    func cached(_ vid: String) -> [VideoTrack]? {
        lock.lock(); defer { lock.unlock() }
        return store[vid]
    }

    func put(_ vid: String, _ list: [VideoTrack]) {
        lock.lock(); defer { lock.unlock() }
        tried.insert(vid)
        guard !list.isEmpty else { return }
        if store[vid] == nil { order.append(vid) }
        store[vid] = list
        while order.count > cap, let first = order.first {
            order.removeFirst(); store[first] = nil
        }
    }
    /// 批量预取（内部按 5 个一组切分请求）。已缓存/在飞/试过的不重复发。
    func prefetch(_ vids: [String]) {
        lock.lock()
        let want = vids.filter { store[$0] == nil && !inFlight.contains($0) && !tried.contains($0) }
        for v in want { inFlight.insert(v) }
        lock.unlock()
        guard !want.isEmpty else { return }
        Task {
            let got = await PlayerAPI.multiTracks(for: want)
            lock.lock()
            for v in want {
                inFlight.remove(v)
                if let list = got[v], !list.isEmpty {
                    if store[v] == nil { order.append(v) }
                    store[v] = list
                    while order.count > cap, let first = order.first {
                        order.removeFirst(); store[first] = nil
                    }
                } else {
                    tried.insert(v)
                }
            }
            lock.unlock()
        }
    }
    /// 换剧时清掉上一部的缓存，免得越积越多
    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll(); tried.removeAll()
    }
}

/// 全局播放权：任何时刻只允许一个画面在播、只允许一路声音。
///
/// 推荐页的卡片在 fullScreenCover / sheet 后面不会被自动暂停 ——
/// 弹出播放页之后两个 AVPlayer 一起响，就是「两个视频同时播放、声音重叠」。
/// 视图层已经按「有没有弹层」把底色停掉，这里再加一道硬保证：
/// 谁最后申请播放权，谁就把上一个持有者停掉。
///
/// 注意不要标 @MainActor：调用点在 View 的普通方法里，
/// iOS 上那是同步的非隔离上下文，标了隔离直接编译不过
/// （error: call to main actor-isolated instance method in a
///  synchronous nonisolated context）。改用锁保护，
/// 并把「停上一个」确保派回主线程执行。
final class PlaybackCenter: @unchecked Sendable {
    static let shared = PlaybackCenter()
    private let lock = NSLock()
    private var owner: String?
    private var stop: (() -> Void)?

    /// 申请播放权。上一个持有者会被立刻停掉。
    func claim(_ id: String, stop: @escaping () -> Void) {
        lock.lock()
        // 自己重复申请就别把自己停了
        let prev: (() -> Void)? = (owner == id) ? nil : self.stop
        owner = id
        self.stop = stop
        lock.unlock()
        if let prev { onMain(prev) }
    }

    /// 归还。只有自己还持有时才清空，免得把后来者的播放权一起抹掉。
    func release(_ id: String) {
        lock.lock()
        if owner == id { owner = nil; stop = nil }
        lock.unlock()
    }

    /// 停播放器得在主线程做。本来就在主线程就直接同步执行，
    /// 这样「先停上一个、再播下一个」的顺序是确定的。
    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }
}
