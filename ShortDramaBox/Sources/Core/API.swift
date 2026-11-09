import Foundation

let BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

enum ApiError: Error, LocalizedError {
    case badURL, http(Int), noData, server(Int, String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .http(let c): return "网络错误 HTTP \(c)"
        case .noData: return "返回数据为空"
        case .server(let c, let m): return "接口错误 \(c)" + (m.isEmpty ? "" : "：\(m)")
        }
    }
}

func httpGet(_ url: String, timeout: TimeInterval = 20) async throws -> Data {
    guard let u = URL(string: url) else { throw ApiError.badURL }
    var r = URLRequest(url: u)
    r.timeoutInterval = timeout
    r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
    r.setValue("text/html,application/json,*/*", forHTTPHeaderField: "Accept")
    r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
    let (data, resp) = try await URLSession.shared.data(for: r)
    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
    return data
}

/// 从 SSR HTML 中提取 _ROUTER_DATA 的 JSON（大括号配对，跳过字符串与转义）
func routerJSON(_ data: Data) -> [String: Any]? {
    guard let s = String(data: data, encoding: .utf8) else { return nil }
    let chars = Array(s)
    guard let mk = s.range(of: "_ROUTER_DATA") else { return nil }
    var i = s.distance(from: s.startIndex, to: mk.lowerBound)
    while i < chars.count && chars[i] != "{" { i += 1 }
    guard i < chars.count else { return nil }
    var depth = 0, inStr = false, esc = false
    let start = i
    while i < chars.count {
        let c = chars[i]
        if inStr {
            if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
        } else if c == "\"" { inStr = true }
        else if c == "{" { depth += 1 }
        else if c == "}" {
            depth -= 1
            if depth == 0 {
                let js = String(chars[start...i])
                return (try? JSONSerialization.jsonObject(with: Data(js.utf8))) as? [String: Any]
            }
        }
        i += 1
    }
    return nil
}

func asDict(_ v: Any?) -> [String: Any] { (v as? [String: Any]) ?? [:] }
func asArr(_ v: Any?) -> [Any] { (v as? [Any]) ?? [] }
func asStr(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func asInt(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) ?? 0 }
    return 0
}

func seriesFrom(_ d: [String: Any]) -> Series {
    var s = Series(id: asStr(d["series_id"]))
    s.title = asStr(d["series_name"]).isEmpty ? asStr(d["series_title"]) : asStr(d["series_name"])
    s.cover = asStr(d["series_cover"])
    s.intro = asStr(d["series_intro"])
    s.episodeCount = asInt(d["episode_cnt"])
    s.accessibleCount = asInt(d["accessible_episode_cnt"])
    s.rightText = asStr(d["episode_right_text"])
    s.tags = asArr(d["tags"]).map { asStr($0) }.filter { !$0.isEmpty }
    return s
}

/// 把 404/500 这类"内容不存在"翻译成用户能看懂的话
func friendlyGet(_ url: String, what: String) async throws -> Data {
    do { return try await httpGet(url) }
    catch ApiError.http(let c) where c == 404 || c == 410 || c == 500 {
        throw ApiError.server(c, what)
    }
}

enum Catalog {
    static let base = "https://hongguoduanju.com"
    static let categories: [(slug: String, name: String)] = [
        ("real-drama", "真人剧"), ("comic-drama", "漫剧"),
        ("ai-drama", "AI剧"), ("comic", "漫画"),
    ]

    static func home() async throws -> [HomeSection] {
        guard let j = routerJSON(try await friendlyGet("\(base)/", what: "首页加载失败，请检查网络")) else { throw ApiError.noData }
        let page = asDict(asDict(j["loaderData"])["page"])
        return asArr(page["homeSections"]).map { sec in
            let d = asDict(sec)
            return HomeSection(id: asStr(d["tab_type"]), name: asStr(d["tab_name"]),
                               items: asArr(d["video_list"]).map { seriesFrom(asDict($0)) })
        }.filter { !$0.items.isEmpty }
    }

    static func category(_ slug: String, page: Int = 1) async throws -> [Series] {
        var url = "\(base)/category/\(slug)"
        if page > 1 { url += "?page=\(page)" }
        guard let j = routerJSON(try await friendlyGet(url, what: "该分类不存在或已下架")) else { throw ApiError.noData }
        let ld = asDict(j["loaderData"])
        for (_, v) in ld {
            let rec = asArr(asDict(v)["recommendList"])
            if !rec.isEmpty { return rec.map { seriesFrom(asDict($0)) } }
        }
        return []
    }


    static func detail(_ seriesId: String) async throws -> (Series, [Episode]) {
        // `dy:`（抖音）红果站内没有，详情与剧集必须问自建服务端
        if seriesId.hasPrefix("dy:") {
            return try await serverDetail(seriesId)
        }
        guard let j = routerJSON(try await friendlyGet("\(base)/detail?series_id=\(seriesId)", what: "该短剧不存在或已下架")) else { throw ApiError.noData }
        let sd = asDict(asDict(asDict(j["loaderData"])["detail_page"])["seriesDetail"])
        var s = seriesFrom(sd)
        if s.title.isEmpty { s.title = asStr(sd["series_name"]) }
        let eps = asArr(sd["vid_list"]).enumerated().map { Episode(index: $0.offset + 1, vid: asStr($0.element)) }
        return (s, eps)
    }

    /// 抖音来源的详情：`GET {resolver}/api/detail?sid=dy:<id>`。
    ///
    /// 返回形状与服务端 `server/hg/app.py` 的 `_douyin_detail` 一致：
    /// `{ok, series:{id,title,cover,intro,eps,tags}, episodes:[{index,vid}]}`
    static func serverDetail(_ seriesId: String) async throws -> (Series, [Episode]) {
        guard let root = RemoteResolver.base,
              var comps = URLComponents(string: root + "/api/detail") else { throw ApiError.noData }
        comps.queryItems = [URLQueryItem(name: "sid", value: seriesId)]
        guard let url = comps.url else { throw ApiError.noData }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ShortDramaBox-Catalog/1", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let d = obj["series"] as? [String: Any] else { throw ApiError.noData }

        var s = Series(id: seriesId)
        s.title = asStr(d["title"])
        s.cover = asStr(d["cover"])
        s.intro = asStr(d["intro"])
        s.episodeCount = asInt(d["eps"])
        s.tags = asArr(d["tags"]).map { asStr($0) }
        s.source = asStr(d["source"])
        if s.title.isEmpty {
            s.title = "抖音短剧"
        }

        let eps: [Episode] = asArr(obj["episodes"]).compactMap { raw in
            let e = asDict(raw)
            let v = asStr(e["vid"])
            guard !v.isEmpty else { return nil }
            return Episode(index: asInt(e["index"]), vid: v)
        }
        return (s, eps)
    }
}
