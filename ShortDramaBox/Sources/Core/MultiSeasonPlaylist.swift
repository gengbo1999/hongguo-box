import Foundation

/// 把同一部剧的多个“第 N 季”拼成一条连续播放列表。
///
/// 只处理带季标记的剧；单季剧原样返回，不会多发请求。
enum MultiSeasonPlaylist {
    static func build(series: Series,
                      episodes: [Episode],
                      siblings: [Series]? = nil) async -> [Episode] {
        guard !episodes.isEmpty else { return episodes }
        // 第一季的标题往往没有「第N季」标记，但第二季会以「…第2季」出现；
        // 所以没有季标记时，用完整标题当合并基准（精确匹配，避免误并同前缀的其它剧）。
        let base = series.seasonBase ?? series.title

        var others: [Series]
        if let siblings {
            others = siblings
        } else {
            others = await discover(base: base)
        }
        var seen = Set<String>([series.id])
        others = others.filter {
            seen.insert($0.id).inserted && ($0.seasonBase ?? $0.title) == base
        }
        guard !others.isEmpty else { return episodes }

        var ordered = [series] + others
        ordered.sort { ($0.seasonNumber ?? 1) < ($1.seasonNumber ?? 1) }

        var merged: [Episode] = []
        var n = 0
        for s in ordered {
            let detail: Series
            let list: [Episode]
            if s.id == series.id {
                detail = series
                list = episodes
            } else if let (d, e) = try? await Catalog.detail(s.id), !e.isEmpty {
                detail = d
                list = e
            } else {
                continue
            }
            for ep in list {
                n += 1
                merged.append(Episode(index: n, vid: ep.vid,
                                      seriesId: s.id,
                                      seriesTitle: detail.title,
                                      seriesCover: detail.cover,
                                      seasonNumber: s.seasonNumber ?? 1,
                                      episodeNumber: ep.index))
            }
        }
        return merged.count > episodes.count ? merged : episodes
    }

    static func discover(base: String) async -> [Series] {
        // 先走服务端目录（快、稳定）；站内搜索页已改成前端渲染，只作兜底。
        var found = await CatalogAPI.search(base, limit: 60).list
        if found.isEmpty, let page = try? await SearchAPI.remote(base) {
            found = page.list
        }
        return found.filter { ($0.seasonBase ?? $0.title) == base }
    }
}
