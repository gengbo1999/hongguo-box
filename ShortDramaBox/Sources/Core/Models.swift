import Foundation

struct Series: Identifiable, Hashable, Codable {
    let id: String
    var title: String = ""
    var cover: String = ""
    var intro: String = ""
    var episodeCount: Int = 0
    var accessibleCount: Int = 0
    var rightText: String = ""
    var tags: [String] = []
    /// 来源：hg=红果（默认） dy=抖音；老数据为空，按 id 前缀兜底。
    /// 列表卡片和详情页据此显示来源徽标（图标+文字），避免混池后分不清出处。
    var source: String = ""
    /// 同一部剧在其它来源的条目（列表按标题去重后保留，供详情页/播放页「换源」）。
    /// 仅用于内存展示，不参与持久化。
    var alternates: [Series]? = nil
}

struct Episode: Identifiable, Hashable {
    /// 播放列表里的全局序号；单季时等于集号，多季拼接后用于翻页与缓存键。
    let index: Int
    let vid: String
    /// 所属季（多季拼接时填写）；单季为空。
    var seriesId: String = ""
    var seriesTitle: String = ""
    var seriesCover: String = ""
    var seasonNumber: Int = 0
    /// 本季内的集号；0 表示用 index。
    var episodeNumber: Int = 0

    var id: Int { index }
    /// 展示给用户的集号：多季时仍是「本季第几集」。
    var displayNumber: Int { episodeNumber > 0 ? episodeNumber : index }
    var hasSeason: Bool { seasonNumber > 0 && !seriesTitle.isEmpty }
}

struct VideoTrack: Hashable {
    var definition: String = ""
    var width: Int = 0
    var height: Int = 0
    var size: Int = 0
    var url: String = ""
    var spadeA: String = ""
    var codec: String = ""
    /// 这条档位的来源说明 / 降级原因。空串=正常取自官方接口。
    /// 回退到公网明文源时会写明「接口为什么没给出高清档位」，
    /// 让用户看到原因，而不是默默变糊。
    var note: String = ""
}

struct HomeSection: Identifiable, Hashable {
    let id: String
    let name: String
    let items: [Series]
}


extension Series {
    /// 标题里的「第N季」标记（如「第十二季」）；没有则 nil
    var seasonMarker: String? {
        guard let r = title.range(of: #"第[0-9一二三四五六七八九十百千零两]+季\s*$"#,
                                 options: .regularExpression) else { return nil }
        return String(title[r]).trimmingCharacters(in: .whitespaces)
    }

    /// 去掉季标记后的基础片名；没有季标记返回 nil
    var seasonBase: String? {
        guard let r = title.range(of: #"[:：]?\s*第[0-9一二三四五六七八九十百千零两]+季\s*$"#,
                                 options: .regularExpression) else { return nil }
        let base = String(title[title.startIndex..<r.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,、·-—_"))
        return base.count >= 2 ? base : nil
    }

    /// 「第十二季」→ 12；解析不出返回 nil
    var seasonNumber: Int? {
        guard let m = seasonMarker else { return nil }
        let digits = m.filter { $0.isNumber || "一二三四五六七八九十百千零两".contains($0) }
        guard !digits.isEmpty else { return nil }
        return Series.chineseNumber(digits)
    }

    static func chineseNumber(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let d: [Character: Int] = ["零":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,
                                   "六":6,"七":7,"八":8,"九":9]
        let u: [Character: Int] = ["十":10,"百":100,"千":1000]
        var total = 0, cur = 0
        for ch in s {
            if let v = d[ch] { cur = v }
            else if let m = u[ch] { total += (cur == 0 ? 1 : cur) * m; cur = 0 }
            else { return nil }
        }
        return total + cur
    }

    /// 是否抖音源（老数据 source 为空时按 id 前缀兜底）。
    var isDouyin: Bool {
        let kind = source.isEmpty ? (id.hasPrefix("dy:") ? "dy" : "hg") : source
        return kind == "dy"
    }

    /// 列表去重键：规范化标题 + 集数。
    /// 集数不同视为不同剧，避免把同名但不同季/不同长度的条目误合并。
    var dedupeKey: String {
        guard !title.isEmpty else { return "id:\(id)" }
        var t = title.lowercased()
        t.removeAll { ch in
            ch == " " || ch == "　" || ch == "：" || ch == ":" || ch == "·"
                || ch == "-" || ch == "—" || ch == "，" || ch == ","
        }
        return "\(t)#\(episodeCount)"
    }

    /// 合并同剧的另一个来源条目：优先抖音作主条目，其余进入 alternates。
    mutating func mergeAlternate(_ other: Series) {
        guard other.id != id else { return }
        if other.isDouyin && !isDouyin {
            // 红果条目让位给抖音条目，原条目降为备用源。
            var me = self
            me.alternates = nil
            var them = other
            var alts: [Series] = []
            // 自己 + 两边原有的备用源，按 id 去重（可能互相已经包含对方）。
            for cand in [me] + (them.alternates ?? []) + (alternates ?? []) {
                guard cand.id != them.id else { continue }
                guard !alts.contains(where: { $0.id == cand.id }) else { continue }
                var copy = cand
                copy.alternates = nil
                alts.append(copy)
            }
            them.alternates = alts.isEmpty ? nil : alts
            self = them
            return
        }
        var alts = alternates ?? []
        if !alts.contains(where: { $0.id == other.id }) {
            var copy = other
            copy.alternates = nil     // 保持扁平，避免嵌套alternates
            alts.append(copy)
        }
        alternates = alts
    }

    /// 对列表按 dedupeKey 合并同剧多源，保持首次出现顺序。
    static func dedupe(_ list: [Series]) -> [Series] {
        var out: [Series] = []
        var index: [String: Int] = [:]
        for var s in list {
            s.alternates = nil
            let key = s.dedupeKey
            if let i = index[key] {
                out[i].mergeAlternate(s)
            } else {
                index[key] = out.count
                out.append(s)
            }
        }
        return out
    }
}
