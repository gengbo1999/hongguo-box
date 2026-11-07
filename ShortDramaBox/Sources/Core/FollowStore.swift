import Foundation
import SwiftUI

/// 一部被关注短剧里的某一季。季是独立剧集（各自有 id / 标题 / 封面）。
struct FollowSeason: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var cover: String
    var number: Int

    var displayName: String { number > 0 ? "第\(number)季" : title }
}

/// 关注列表里的「一部剧」：多季合并成一条，避免同一部剧占好几行。
struct FollowGroup: Codable, Identifiable {
    var base: String
    var displayTitle: String
    var cover: String
    var seasons: [FollowSeason]
    /// 已知的最新季号；没有季标记的单季为 0。
    var latestSeason: Int
    /// 用户已经看过的最新季号，用来判断要不要提醒「新一季」。
    var seenSeason: Int
    var hasUpdate: Bool
    var updated: Date

    var id: String { base }

    var latest: FollowSeason? {
        seasons.max { $0.number < $1.number }
    }

    var seasonCount: Int { seasons.count }

    var seasonSummary: String {
        guard latestSeason > 0 else { return "单季" }
        return seasons.count > 1 ? "共 \(seasons.count) 季 · 最新第 \(latestSeason) 季" : "第 \(latestSeason) 季"
    }
}

/// 关注数据只存在本机 UserDefaults，和观看记录一样，不依赖账号。
final class FollowStore: ObservableObject {
    static let shared = FollowStore()

    @Published private(set) var groups: [FollowGroup] = []

    private let storageKey = "followed_series_v1"

    private init() { load() }

    var updateCount: Int { groups.filter(\.hasUpdate).count }

    func isFollowing(_ series: Series) -> Bool {
        groups.contains { $0.base == baseName(series) }
    }

    /// 关注/取消关注。关注时把兄弟季一起并进来，这样多季天然是一条。
    func toggle(series: Series, siblings: [Series] = []) {
        let base = baseName(series)
        if let idx = groups.firstIndex(where: { $0.base == base }) {
            groups.remove(at: idx)
            save()
            return
        }
        upsert(series: series, siblings: siblings, markSeen: true)
    }

    func unfollow(base: String) {
        groups.removeAll { $0.base == base }
        save()
    }

    /// 已关注的剧在详情页/列表刷新时调用：发现新季只置更新标识，不自动算已看。
    func merge(series: Series, siblings: [Series]) {
        guard isFollowing(series) else { return }
        upsert(series: series, siblings: siblings, markSeen: false)
    }

    /// 只把「当前这一季」记为已看；如果还有更新的季，更新标识要保留。
    func markSeen(base: String, season: Int) {
        guard let idx = groups.firstIndex(where: { $0.base == base }) else { return }
        groups[idx].seenSeason = max(groups[idx].seenSeason, season)
        groups[idx].hasUpdate = groups[idx].latestSeason > groups[idx].seenSeason
        groups[idx].updated = Date()
        save()
    }

    /// 记录页刷新：重新按片名搜一次，看有没有新一季上线。
    @MainActor
    func refreshAll() async {
        for group in groups {
            let base = group.base
            var found = await CatalogAPI.search(base, limit: 60).list
            if found.isEmpty, let page = try? await SearchAPI.remote(base) {
                found = page.list
            }
            let sameBase = found.filter { baseName($0) == base }
            guard let first = sameBase.first else { continue }
            upsert(series: first, siblings: sameBase.filter { $0.id != first.id }, markSeen: false)
        }
    }

    // MARK: - 内部

    private func baseName(_ series: Series) -> String {
        series.seasonBase ?? series.title
    }

    private func upsert(series: Series, siblings: [Series], markSeen: Bool) {
        let base = baseName(series)
        var all = [series] + siblings
        // 同一个 base 下按剧集 id 去重，并保持季号从旧到新。
        var seen = Set<String>()
        all = all.filter { seen.insert($0.id).inserted }
        all.sort { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }

        let seasons = all.map {
            FollowSeason(id: $0.id,
                         title: $0.title,
                         cover: $0.cover,
                         number: $0.seasonNumber ?? 0)
        }
        let latest = seasons.map(\.number).max() ?? 0
        let cover = seasons.last(where: { !$0.cover.isEmpty })?.cover ?? series.cover

        if let idx = groups.firstIndex(where: { $0.base == base }) {
            // 合并而不是覆盖：某次搜索失败时不能把已知的季弄丢。
            var byId: [String: FollowSeason] = [:]
            for season in groups[idx].seasons { byId[season.id] = season }
            for season in seasons { byId[season.id] = season }
            groups[idx].seasons = byId.values.sorted { $0.number < $1.number }
            groups[idx].latestSeason = max(groups[idx].latestSeason, latest)
            groups[idx].cover = cover.isEmpty ? groups[idx].cover : cover
            groups[idx].displayTitle = base
            if markSeen {
                groups[idx].seenSeason = groups[idx].latestSeason
            }
            groups[idx].hasUpdate = groups[idx].latestSeason > groups[idx].seenSeason
            groups[idx].updated = Date()
        } else {
            let latestSeason = latest
            groups.append(FollowGroup(base: base,
                                      displayTitle: base,
                                      cover: cover,
                                      seasons: seasons,
                                      latestSeason: latestSeason,
                                      seenSeason: latestSeason,
                                      hasUpdate: false,
                                      updated: Date()))
        }
        // 最新季排前面，更新过的也排前面。
        groups.sort {
            if $0.hasUpdate != $1.hasUpdate { return $0.hasUpdate && !$1.hasUpdate }
            return $0.updated > $1.updated
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([FollowGroup].self, from: data) else { return }
        groups = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
