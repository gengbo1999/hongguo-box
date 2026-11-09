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
}
