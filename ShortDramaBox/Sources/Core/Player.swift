import Foundation

/// 游客身份取流：无需签名 / 登录 / Cookie（逆向自桌面版后端 hongguo.py）
///
/// 按顺序尝试三条线路：
///
/// 1. **批量取流（主力，实测可用）** `POST /novel/player/multi_video_model/v1/`
///    要点全在请求体里（逆向自桌面版）：
///      · `biz_param.video_platform = 1024` —— 换成别的值服务端一律回
///        `video platform invalid, param:N`（0..120、1000、2000、9999 全试过）
///      · 视频号放在 `mixed_video_id_map` 里，**不是** `video_id_list`
///    2026-10-21 实测：匿名请求直接 `code=0`，5 档齐全
///    （1080p 1080x1920 / 720p / 540p / 480p / 360p，全 bytevc1 + spade_a），
///    1080p 直链 6,628,394 字节，可解密播放。
///
/// 2. **旧的单条接口** `POST /novel/player/video_model/v1/`：
///    同一时期对第三方客户端**静默拒答**——HTTP 200 但 0 字节，
///    与请求体、请求头、host、出口 IP（家宽 / 阿里云杭州）都无关，
///    带不带 `x-ss-stub`(MD5(body)) 也一样。留着它只是万一哪天恢复。
///
/// 3. **公网明文兜底** `https://hongguoduanju.com/video/public/<vid>/<档位>.mp4`：
///    站点目前只放了 360p（1080p/720p/540p/480p/240p 全 404），
///    仍并发探测全部档位，哪天上高清就自动用上。走到这一步会把
///    「为什么没有高清」只写进 `VideoTrack.note` 供日志排查，不在画面上显示降级提示。
enum PlayerAPI {
    // MARK: - 请求 profile

    /// 一套完整的取流请求特征（host + 查询串 + 请求头）
    struct Profile {
        let name: String
        let host: String
        let query: [(String, String)]
        let headers: [(String, String)]
    }

    /// 旧的单条接口路径（当前静默拒答）
    static let path = "/novel/player/video_model/v1/"
    /// 批量接口路径（主力）
    static let multiPath = "/novel/player/multi_video_model/v1/"

    /// 安卓 App 请求参数（逆向自 7.3.5.32 客户端）
    static let appQuery: [(String, String)] = [
        ("aid", "8662"), ("app_name", "novelread"), ("version_code", "73532"),
        ("version_name", "7.3.5.32"), ("manifest_version_code", "73532"),
        ("update_version_code", "73532"), ("channel", "update_64"),
        ("device_platform", "android"), ("os", "android"), ("ssmix", "a"),
        ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"),
        ("os_api", "36"), ("os_version", "16"), ("resolution", "1280*2772"),
        ("dpi", "520"), ("ac", "wifi"),
    ]

    static let ua = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; "
        + "Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 "
        + "QuicVersion:c67e9834 2025-09-08)"

    static let appHeaders: [(String, String)] = [
        ("user-agent", ua), ("accept", "application/json"),
        ("x-xs-from-web", "0"), ("sdk-version", "2"),
        ("content-type", "application/json; charset=utf-8"),
    ]

    /// 桌面版内置的「公开游客」profile（channel=audit / audit-windows）：
    /// 主机是 **a** 而不是 b，UA 是 hongguo-route-audit/1.0，另带区域头。
    static let auditQuery: [(String, String)] = [
        ("aid", "8662"), ("app_name", "novelread"), ("version_code", "72232"),
        ("version_name", "7.2.2.32"), ("channel", "audit"),
        ("device_platform", "android"), ("device_type", "audit-windows"),
        ("os_version", "12"), ("update_version_code", "72232"),
    ]

    static let auditHeaders: [(String, String)] = [
        ("user-agent", "hongguo-route-audit/1.0"), ("accept", "application/json"),
        ("x-tt-store-region", "cn-sh"), ("x-tt-store-region-src", "uid"),
        ("passport-sdk-version", "5051452"), ("sdk-version", "2"),
        ("content-type", "application/json; charset=utf-8"),
    ]

    /// 依次尝试顺序：主 App 线路 → 备用 host → 公开游客线路
    static let profiles: [Profile] = [
        Profile(name: "app-b", host: "https://api5-normal-sinfonlineb.fqnovel.com",
                query: appQuery, headers: appHeaders),
        Profile(name: "app-c", host: "https://api5-normal-sinfonlinec.fqnovel.com",
                query: appQuery, headers: appHeaders),
        Profile(name: "audit-a", host: "https://api5-normal-sinfonlinea.fqnovel.com",
                query: auditQuery, headers: auditHeaders),
    ]

    /// 随机游客设备号（持久化，避免每次变化）
    static var guestDevice: (id: String, iid: String) {
        let d = UserDefaults.standard
        if let a = d.string(forKey: "guest_device"), let b = d.string(forKey: "guest_iid") {
            return (a, b)
        }
        func rnd() -> String { String(UInt64.random(in: 1_000_000_000_000_000_000...9_999_999_999_999_999_999)) }
        let a = rnd(), b = rnd()
        d.set(a, forKey: "guest_device"); d.set(b, forKey: "guest_iid")
        return (a, b)
    }

    /// 拼上游客设备号的完整查询串
    static func fullQuery(_ p: Profile) -> String {
        let g = guestDevice
        return p.query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            + "&device_id=\(g.id)&iid=\(g.iid)"
    }

    // MARK: - 请求体

    /// 旧的单条接口请求体
    static func body(_ vid: String) -> [String: Any] {
        ["video_id": vid, "content_type": 1,
         "biz_param": ["need_all_video_definition": true, "video_platform": 3]]
    }

    /// 批量接口请求体（逆向自桌面版 hongguo.py）
    /// `video_platform: 1024` 是唯一被接受的平台号；视频号放 `mixed_video_id_map`。
    static func multiBody(_ vid: String) -> [String: Any] {
        ["biz_param": [
            "detail_page_version": 0, "device_level": 3,
            "disable_digg_stat": false, "disable_video_relate_book": false,
            "need_all_video_definition": true, "need_mp4_align": false,
            "use_os_player": false, "use_server_dns": false,
            "video_platform": 1024,
        ], "mixed_video_id_map": ["1": [vid]]]
    }

    /// 批量接口请求体：官方一次最多 5 个 vid
    static func multiBody(_ vids: [String]) -> [String: Any] {
        ["biz_param": [
            "detail_page_version": 0, "device_level": 3,
            "disable_digg_stat": false, "disable_video_relate_book": false,
            "need_all_video_definition": true, "need_mp4_align": false,
            "use_os_player": false, "use_server_dns": false,
            "video_platform": 1024,
        ], "mixed_video_id_map": ["1": Array(vids.prefix(5))]]
    }

    // MARK: - 解析

    /// 直链在两种线路里都可能是明文 https，也可能是 base64（桌面版两种都遇到过）
    static func mediaURL(_ item: [String: Any]) -> String {
        for key in ["main_url", "backup_url"] {
            let v = asStr(item[key])
            if v.isEmpty { continue }
            if v.hasPrefix("http") { return v }
            if let d = Data(base64Encoded: v), let s = String(data: d, encoding: .utf8),
               s.hasPrefix("http") { return s }
        }
        return ""
    }

    /// 把一份 video_model（字典，或 JSON 字符串）解析成档位列表。
    /// 批量接口与旧的单条接口共用这份结构：
    /// `video_list[].video_meta{definition,vwidth,vheight,size,codec_type}`
    /// `video_list[].encrypt_info{spade_a}`
    static func parseTracks(_ model: Any) -> [VideoTrack] {
        var vm = asDict(model)
        if vm.isEmpty, let s = model as? String, let d = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) {
            vm = asDict(o)
        }
        return asArr(vm["video_list"]).map { raw -> VideoTrack in
            let it = asDict(raw), m = asDict(it["video_meta"]), e = asDict(it["encrypt_info"])
            var t = VideoTrack()
            t.definition = asStr(m["definition"])
            t.width = asInt(m["vwidth"]); t.height = asInt(m["vheight"])
            t.size = asInt(m["size"]); t.codec = asStr(m["codec_type"])
            t.url = mediaURL(it)
            t.spadeA = asStr(e["spade_a"])
            return t
        }.filter { !$0.url.isEmpty }
    }

    // MARK: - 单次请求

    /// 用某一套 profile 打**批量**接口取一次档位（主力线路）。
    /// 失败时返回**简短原因**（给用户看的）：`200/0字节`、`HTTP404`、`code100001`…
    static func multiAttempt(_ p: Profile, vid: String) async -> Result<[VideoTrack], FetchError> {
        guard let u = URL(string: p.host + multiPath + "?" + fullQuery(p)) else {
            return .failure(FetchError("URL非法"))
        }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        for h in p.headers { r.setValue(h.1, forHTTPHeaderField: h.0) }
        guard let raw = try? JSONSerialization.data(withJSONObject: multiBody(vid)) else {
            return .failure(FetchError("请求体非法"))
        }
        r.httpBody = raw
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            return .failure(FetchError("网络失败"))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { return .failure(FetchError("HTTP\(status)")) }
        // 空体 / 非 JSON：服务端风控拒答的典型形态
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(FetchError("\(status)/\(data.count)字节"))
        }
        let code = asInt(root["code"])
        if code != 0 { return .failure(FetchError("code\(code)")) }
        // data 以 vid 为键，值里带一个 JSON 字符串形式的 video_model
        let group = asDict(asDict(root["data"])[vid])
        let inner = asStr(group["video_model"])
        guard !inner.isEmpty else { return .failure(FetchError("无video_model")) }
        return .success(parseTracks(inner))
    }

    /// 用一套 profile 打批量接口，一次最多取 5 个 vid 的档位。
    static func multiAttempt(_ p: Profile, vids: [String]) async -> Result<[String: [VideoTrack]], FetchError> {
        let chunk = Array(vids.prefix(5))
        guard !chunk.isEmpty else { return .success([:]) }
        guard let u = URL(string: p.host + multiPath + "?" + fullQuery(p)) else {
            return .failure(FetchError("URL非法"))
        }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        for h in p.headers { r.setValue(h.1, forHTTPHeaderField: h.0) }
        guard let raw = try? JSONSerialization.data(withJSONObject: multiBody(chunk)) else {
            return .failure(FetchError("请求体非法"))
        }
        r.httpBody = raw
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            return .failure(FetchError("网络失败"))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { return .failure(FetchError("HTTP\(status)")) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(FetchError("\(status)/\(data.count)字节"))
        }
        let code = asInt(root["code"])
        if code != 0 { return .failure(FetchError("code\(code)")) }
        let group = asDict(root["data"])
        var out: [String: [VideoTrack]] = [:]
        for vid in chunk {
            let inner = asStr(asDict(group[vid])["video_model"])
            if inner.isEmpty { continue }
            let list = parseTracks(inner)
            if !list.isEmpty { out[vid] = list }
        }
        return out.isEmpty ? .failure(FetchError("无video_model")) : .success(out)
    }

    /// 批量取档位：每 5 个 vid 一次请求 —— 切集前先把后面几集的地址拿好，
    /// 5 集一次往返，省掉 4 次「获取播放地址」的等待。
    /// 只试前 2 套 profile：预取要的是快，不值得把 6 套都轮一遍。
    static func multiTracks(for vids: [String]) async -> [String: [VideoTrack]] {
        var want = vids
        var out: [String: [VideoTrack]] = [:]
        while !want.isEmpty {
            let chunk = Array(want.prefix(5))
            want.removeFirst(chunk.count)
            for p in profiles.prefix(2) {
                if case .success(let got) = await multiAttempt(p, vids: chunk) {
                    out.merge(got) { a, _ in a }
                    break
                }
            }
        }
        return out
    }

    /// 选定要播的档位（播放页与预取共用 —— 保证预取下的就是待会儿要播的那一条，
    /// 否则预取等于白下）。
    /// - 手动指定清晰度时**不做编解码过滤**：源站给了就认，播不了交给本机转码
    /// - 自动选择时优先能直接播的最高清晰度（省掉转码等待）
    static func pick(_ list: [VideoTrack], force: String?) -> VideoTrack? {
        if let f = force, let t = list.first(where: { $0.definition == f }) { return t }
        let ok = playable(list)
        if let p = ok.first(where: { $0.definition.contains("1080") }) { return p }
        if let f = ok.first { return f }
        return list.first
    }

    /// 用某一套 profile 打**旧的单条**接口取一次档位（当前静默拒答，保留以防恢复）
    static func attempt(_ p: Profile, vid: String) async -> Result<[VideoTrack], FetchError> {
        guard let u = URL(string: p.host + path + "?" + fullQuery(p)) else {
            return .failure(FetchError("URL非法"))
        }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        for h in p.headers { r.setValue(h.1, forHTTPHeaderField: h.0) }
        guard let raw = try? JSONSerialization.data(withJSONObject: body(vid)) else {
            return .failure(FetchError("请求体非法"))
        }
        r.httpBody = raw
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            return .failure(FetchError("网络失败"))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { return .failure(FetchError("HTTP\(status)")) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(FetchError("\(status)/\(data.count)字节"))
        }
        let code = asInt(root["code"])
        if code != 0 { return .failure(FetchError("code\(code)")) }
        guard let inner = asStr(asDict(root["data"])["video_model"]).data(using: .utf8),
              let vm = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any]
        else { return .failure(FetchError("无video_model")) }
        return .success(parseTracks(vm))
    }

    /// 走服务端签名网关取流。
    ///
    /// 这是拿到 1080p 的**唯一现实路径**：签名头只能在 Android 侧生成，
    /// 放到服务端之后，签名方案一打通就全量生效，不用重新侧载 App。
    /// 网关没配 / 连不上 / 签名还没通，都会返回空数组，调用方自然回退本地直连。
    static func remoteTracks(_ vid: String) async -> [VideoTrack] {
        guard RemoteResolver.isEnabled else { return [] }

        var out: [VideoTrack] = []
        for p in profiles.prefix(2) {
            var q = Dictionary(p.query, uniquingKeysWith: { a, _ in a })
            let g = guestDevice
            q["device_id"] = g.id
            q["iid"] = g.iid
            let spec = RemoteResolver.Spec(
                host: p.host,
                path: multiPath,
                query: q,
                body: multiBody(vid),
                ua: ua,
                headers: Dictionary(p.headers, uniquingKeysWith: { a, _ in a })
            )
            guard let r = await RemoteResolver.resolve(spec), r.ok else { continue }
            let tracks = RemoteResolver.parseTracks(r)
            guard !tracks.isEmpty else { continue }
            out = tracks.map { t in
                var v = VideoTrack()
                v.definition = t.definition
                v.width = t.width
                v.height = t.height
                v.size = Int(t.size)
                v.codec = t.codec
                v.url = t.url
                v.spadeA = t.spadeA
                return v
            }
            break
        }
        return out
    }

    /// 取流（单入口）：先问服务端网关，再走本地直连；全不通抛错。
    static func videoModel(_ vid: String) async throws -> [VideoTrack] {
        let remote = await remoteTracks(vid)
        if !remote.isEmpty { return remote }
        for p in profiles {
            if case .success(let t) = await multiAttempt(p, vid: vid), !t.isEmpty { return t }
        }
        for p in profiles {
            if case .success(let t) = await attempt(p, vid: vid), !t.isEmpty { return t }
        }
        throw ApiError.noData
    }

    // MARK: - 公网明文备用源

    /// 公网明文档位候选（从高到低）。实测站点目前只放了 360p，
    /// 但探测很便宜，哪天放出更高档位就能自动用上。
    static let publicQualities: [(String, Int, Int)] = [
        ("1080p", 1080, 1920), ("720p", 720, 1280), ("540p", 540, 960),
        ("480p", 480, 854), ("360p", 360, 640),
    ]

    /// 探测单个公网档位是否存在
    static func publicProbe(_ vid: String, _ name: String, _ w: Int, _ h: Int,
                            note: String) async -> VideoTrack? {
        let s = "https://hongguoduanju.com/video/public/\(vid)/\(name).mp4"
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 12
        r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let hh = resp as? HTTPURLResponse, hh.statusCode == 200 else { return nil }
        var t = VideoTrack()
        t.definition = "公开\(name)"
        t.width = w; t.height = h
        t.size = Int(max(hh.expectedContentLength, 0))
        t.codec = "avc1"; t.url = s; t.spadeA = ""
        t.note = note
        return t
    }

    /// 并发探测全部公网档位，取存在的最高一档
    static func publicBest(_ vid: String, note: String) async -> VideoTrack? {
        let found = await withTaskGroup(of: VideoTrack?.self) { group -> [VideoTrack] in
            for c in publicQualities {
                group.addTask { await publicProbe(vid, c.0, c.1, c.2, note: note) }
            }
            var acc: [VideoTrack] = []
            for await t in group { if let t { acc.append(t) } }
            return acc
        }
        return found.max {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            return a < b
        }
    }

    // MARK: - 编解码判断

    /// 该编码能否**直接**交给 AVFoundation 解码。
    /// bytevc1 -> MP4 里是 hvc1（标准 HEVC），AVPlayer 能解；h265 / hev1 / hevc 同理；
    /// avc1 / avc3 是 H.264。
    /// bytevc2 -> MP4 里是 bvc2（字节自研私有编码），VideoToolbox 明确返回
    ///            kVTCouldNotFindVideoDecoderErr(-12906)，直接播必然黑屏 ——
    ///            这类档位不再丢弃，而是交给本机转码补齐（见 Transcoder.swift）。
    static func isPlayableCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        if c.isEmpty { return true }
        return c == "bytevc1" || c == "hvc1" || c == "hev1" || c == "h265"
            || c == "hevc" || c == "avc1" || c == "avc3"
    }

    /// 这条档位需要本机转码才能播（源站给了，但 iOS 没有这个解码器）
    static func needsTranscode(_ track: VideoTrack) -> Bool {
        guard !track.spadeA.isEmpty else { return false }
        return !isPlayableCodec(track.codec)
    }

    /// 清晰度从高到低：先比短边，再比体量
    static func sorted(_ list: [VideoTrack]) -> [VideoTrack] {
        list.sorted {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            if a != b { return a > b }
            return $0.size > $1.size
        }
    }

    /// 能直接播的档位子集
    static func playable(_ list: [VideoTrack]) -> [VideoTrack] {
        list.filter { isPlayableCodec($0.codec) }
    }

    /// 本机转码的输入源：可解码档位里清晰度最高的一条
    static func transcodeSource(_ list: [VideoTrack]) -> VideoTrack? {
        playable(list).max {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            if a != b { return a < b }
            return $0.size < $1.size
        }
    }

    // MARK: - 对外入口

    /// 把多次失败原因压成一句人话：相同原因合并计数
    static func reasonSummary(_ reasons: [String]) -> String {
        var order: [String] = []
        var count: [String: Int] = [:]
        for r in reasons {
            if count[r] == nil { order.append(r) }
            count[r, default: 0] += 1
        }
        return order.map { c in
            let n = count[c] ?? 1
            return n > 1 ? "\(c)×\(n)" : c
        }.joined(separator: "、")
    }

    /// 全部档位，**一条都不过滤**，按清晰度从高到低。
    /// 播不了的档位也照样返回，由播放器决定走本机转码。
    /// 三条线路全不通时回退公网明文，并把失败原因写进 `note`。
    static func allTracks(for vid: String) async -> [VideoTrack] {
        var reasons: [String] = []
        // 0) 服务端签名网关（当前唯一能稳定拿 1080p 的路径）
        let remote = await remoteTracks(vid)
        if !remote.isEmpty { return sorted(remote) }
        reasons.append("网关无档位")
        // 1) 批量接口（本地直连；2026-10 起匿名请求多半返回空体）
        for p in profiles {
            switch await multiAttempt(p, vid: vid) {
            case .success(let t):
                if !t.isEmpty { return sorted(t) }
                reasons.append("批量空档位")
            case .failure(let e):
                reasons.append("批量" + e.why)
            }
        }
        // 2) 旧的单条接口
        for p in profiles {
            switch await attempt(p, vid: vid) {
            case .success(let t):
                if !t.isEmpty { return sorted(t) }
                reasons.append("空档位")
            case .failure(let e):
                reasons.append(e.why)
            }
        }
        let why = "高清接口无档位(\(reasonSummary(reasons)))"
        if let f = await publicBest(vid, note: why) { return [f] }
        return []
    }

    /// 统一取流：优先给能直接播的档位；一条都直接播不了时，把原始档位交出去
    /// 交给 prepareForPlayback 做本机转码，而不是回退成「没有片源」。
    static func tracks(for vid: String) async -> [VideoTrack] {
        let all = await allTracks(for: vid)
        let ok = playable(all)
        return ok.isEmpty ? all : sorted(ok)
    }
}

/// 取流失败原因（单句，给用户看）
struct FetchError: Error {
    let why: String
    init(_ w: String) { why = w }
}