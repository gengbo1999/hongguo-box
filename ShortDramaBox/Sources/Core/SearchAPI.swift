import Foundation

/// 站内搜索：抓 `https://hongguoduanju.com/search/<关键词>`，从页面内嵌的
/// `_ROUTER_DATA` 里取「按相关度排序的前若干条 + 命中总数」。
///
/// ⚠️ 现状：站方已把搜索页改成前端渲染，页面上不再有 `_ROUTER_DATA`，
/// 这条链路基本抓不到数据（`routerJSON` 返回 nil → 抛 `ApiError.noData`）。
/// 保留它是为了站方万一改回去；调用方必须容忍失败，不能把结果当唯一来源。
enum SearchAPI {
    struct Page {
        var list: [Series] = []
        var total: Int = 0
    }

    static func remote(_ keyword: String) async throws -> Page {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return Page() }
        // 关键词作为路径段，按字节全量百分号编码（中文安全）
        let esc = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
        let data = try await httpGet("\(Catalog.base)/search/\(esc)")
        guard let j = routerJSON(data) else { throw ApiError.noData }
        let page = asDict(asDict(j["loaderData"])["search_(keyword)/page"])
        var out = Page()
        out.total = asInt(page["totalCount"])
        for raw in asArr(page["searchList"]) {
            let item = asDict(raw)
            let vd = asDict(item["video_data"])
            let sid = asStr(vd["series_id"])
            guard !sid.isEmpty else { continue }
            var s = Series(id: sid)
            let t = asStr(vd["series_title"])
            s.title = t.isEmpty ? asStr(item["name"]) : t
            s.cover = asStr(vd["series_cover"])
            s.intro = asStr(vd["series_intro"])
            s.episodeCount = asInt(vd["episode_cnt"])
            s.rightText = asStr(vd["episode_right_text"])
            s.tags = asArr(vd["category_list"])
                .map { asStr(asDict($0)["name"]) }
                .filter { !$0.isEmpty }
            out.list.append(s)
        }
        return out
    }
}
