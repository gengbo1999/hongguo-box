import Foundation

/// 服务端目录层（`server/hg/catalog.py`）的客户端。
///
/// 以前这些查询都在本地算：App 包里塞一个 20.5 MB 的 `index.bin.z`，
/// `LocalIndex` 解压成 34 MB 后做字节扫描和倒排。现在标签云、标签翻页、
/// 最新、随机、搜索都由服务端算好直接发 JSON，App 里不再有索引文件，
/// 安装包小 20 MB，冷启动也不用解压。
///
/// 地址和签名网关共用 `RemoteResolver.base`，默认就是官方服务器，
/// 配一次就能同时用上取流和目录。把 `resolver_base` 清空等于关掉远端：
/// 所有方法都返回 nil / 空，调用方按「服务端不可用」降级，
/// 首页推荐、站内搜索这些不依赖全库的功能照常能用。
enum CatalogAPI {

    /// 与服务端一致的默认分页大小。
    static let defaultPageLimit = 24
    /// 标签云一次要全量（服务端上限 1000，实际 400 个出头）。
    static let maxTagBuckets = 1000

    static var isEnabled: Bool { RemoteResolver.base != nil }

    // MARK: - 返回类型

    /// 一个标签及其剧集数。
    struct TagBucket: Hashable {
        var tag: String
        var count: Int
    }

    struct SearchResult {
        var list: [Series] = []
        /// 命中的**不同剧集**总数（列表只带前 limit 条）
        var total = 0
    }

    // MARK: - 接口

    /// 标签云，按剧集数从多到少。
    static func tagBuckets() async -> [TagBucket] {
        guard let j = await get("/api/tags", ["limit": "\(maxTagBuckets)"]) else { return [] }
        return asArr(j["items"]).compactMap { raw in
            let d = asDict(raw)
            let tag = asStr(d["tag"])
            guard !tag.isEmpty else { return nil }
            return TagBucket(tag: tag, count: asInt(d["count"]))
        }
    }

    /// 某个标签下的剧集，`offset`/`limit` 分页。服务端按上架时间倒序。
    static func tagPage(_ tag: String, offset: Int = 0, limit: Int = defaultPageLimit) async -> (items: [Series], total: Int) {
        guard !tag.isEmpty, let j = await get("/api/tag", [
            "tag": tag, "offset": "\(max(0, offset))", "limit": "\(max(1, limit))",
        ]) else { return ([], 0) }
        return (seriesList(j), asInt(j["total"]))
    }

    /// 「最新」：全库按上架时间倒序。`next` 是下一批的 offset。
    static func newest(offset: Int = 0, limit: Int = defaultPageLimit) async -> (items: [Series], next: Int) {
        guard let j = await get("/api/newest", [
            "offset": "\(max(0, offset))", "limit": "\(max(1, limit))",
        ]) else { return ([], max(0, offset)) }
        return (seriesList(j), asInt(j["next"]))
    }

    /// 全库随机，跳过 `excluding` 里的 id。条数可能略少，按返回的用。
    static func random(limit: Int, excluding: Set<String> = []) async -> [Series] {
        var q: [String: String] = ["limit": "\(max(1, limit))"]
        if !excluding.isEmpty { q["exclude"] = excluding.joined(separator: ",") }
        // 排除列表太长会顶破 URL 长度，且服务端最多 100 条；截断只影响去重强度
        guard let j = await get("/api/random", q) else { return [] }
        return seriesList(j)
    }

    /// 片名片段 / sid 搜索。
    static func search(_ keyword: String, limit: Int = 300, offset: Int = 0) async -> SearchResult {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return SearchResult() }
        guard let j = await get("/api/search", [
            "q": k, "limit": "\(max(1, limit))", "offset": "\(max(0, offset))",
        ]) else { return SearchResult() }
        return SearchResult(list: seriesList(j), total: asInt(j["total"]))
    }

    /// 按 sid 批量取（≤200 个），用来补齐详情页缺的封面/简介。
    static func byIDs(_ ids: [String]) async -> [Series] {
        let uniq = ids.filter { !$0.isEmpty && !$0.contains(",") }
        guard !uniq.isEmpty else { return [] }
        guard let j = await get("/api/series", ["ids": uniq.prefix(200).joined(separator: ",")])
        else { return [] }
        return seriesList(j)
    }

    /// 服务端报的全库条数（首页/搜索页显示「在 N 部里搜」用）。
    static func totalCount() async -> Int {
        guard let j = await get("/healthz", [:]) else { return 0 }
        return asInt(j["series"])
    }

    // MARK: - 内部

    /// 拼 URL 并做一次 GET。任何失败（没配地址、超时、非 200、JSON 不合法）都返回 nil。
    private static func get(_ path: String, _ query: [String: String]) async -> [String: Any]? {
        guard let base = RemoteResolver.base,
              var comps = URLComponents(string: base + path) else { return nil }
        // queryItems 会把中文标签/关键词正确百分号编码
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ShortDramaBox-Catalog/1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any],
                  (dict["ok"] as? Bool) ?? false
            else { return nil }
            return dict
        } catch {
            // 服务端没部署 / 不在同一网络都很正常，不打扰用户
            return nil
        }
    }

    /// 服务端统一的条目形状：{id,title,cover,intro,eps,tags:[...],created}
    private static func seriesList(_ j: [String: Any]) -> [Series] {
        asArr(j["items"]).compactMap { raw in
            let d = asDict(raw)
            let sid = asStr(d["id"])
            guard !sid.isEmpty else { return nil }
            var s = Series(id: sid)
            s.title = asStr(d["title"])
            guard !s.title.isEmpty else { return nil }
            s.cover = asStr(d["cover"])
            s.intro = asStr(d["intro"])
            s.episodeCount = asInt(d["eps"])
            s.tags = asArr(d["tags"]).map { asStr($0) }.filter { !$0.isEmpty }
            s.source = asStr(d["source"])
            s.sources = asArr(d["sources"]).compactMap { raw in
                let x = asDict(raw)
                let sid = asStr(x["sid"])
                guard !sid.isEmpty else { return nil }
                return SeriesSource(source: asStr(x["source"]), sid: sid,
                                    eps: asInt(x["eps"]), title: asStr(x["title"]))
            }
            return s
        }
    }
}