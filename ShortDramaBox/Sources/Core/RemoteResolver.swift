import Foundation

/// 服务端取流网关（signing gateway）的客户端。
///
/// 为什么需要这一层：红果的取流接口在 2026-10-21 之后对匿名请求静默拒绝
/// （HTTP 200 + `content-length: 0`），而真正能拿到 1080p 的请求需要
/// X-Argus / X-Gorgon / X-Khronos / X-Soter / x-ss-stub 这些签名头。
/// 生成它们的逻辑只在 Android 的 libhongguo_signer.so 里（纯 bionic、
/// 只有 arm64-v8a、且只导出 JNI_OnLoad）。
///
/// 结论：签名永远不可能在 iOS 上做。那就把它放到服务端——
/// 签名方案一旦打通，**服务端部署即全量生效**，
/// 不用重新打包、不用让用户重新侧载。
///
/// 安全设计：
///   - 默认关闭，地址必须显式配置（UserDefaults 的 `resolver_base`）；
///   - 超时 8 秒，比本地直连的 20 秒短，失败时能及时回退；
///   - 任何一步失败都静默返回 nil，调用方自然回退本地直连。
/// 所以打开它不会让现状变差。
enum RemoteResolver {

    /// 服务地址，例如 "http://1.2.3.4:30087"。为空表示不启用。
    static var base: String? {
        let v = (UserDefaults.standard.string(forKey: "resolver_base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static var isEnabled: Bool { base != nil }

    /// 一次取流请求的描述。字段名与服务端 `/resolve` 的入参一一对应。
    struct Spec {
        var host: String
        var path: String
        var method: String = "POST"
        var query: [String: String] = [:]
        var body: [String: Any] = [:]
        var ua: String?
        var headers: [String: String] = [:]
    }

    /// 网关返回的一条清晰度。
    struct Track {
        let definition: String
        let width: Int
        let height: Int
        let url: String
        let size: Int64
        let codec: String
        let spadeA: String
    }

    /// 网关的原始返回。
    struct Result {
        let ok: Bool
        /// 上游 JSON（成功时）
        let data: [String: Any]?
        /// 失败原因：empty_body / upstream / bad
        let error: String?
    }

    static let timeout: TimeInterval = 8

    // MARK: - 调用

    /// 把请求交给网关。失败返回 nil，调用方回退本地直连。
    static func resolve(_ spec: Spec) async -> Result? {
        guard let base, let url = URL(string: base + "/resolve") else { return nil }

        var payload: [String: Any] = [
            "host": spec.host,
            "path": spec.path,
            "method": spec.method,
            "query": spec.query,
            "body": spec.body,
        ]
        if let ua = spec.ua { payload["ua"] = ua }
        if !spec.headers.isEmpty { payload["headers"] = spec.headers }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ShortDramaBox-Resolver/1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard
                let obj = try? JSONSerialization.jsonObject(with: data),
                let dict = obj as? [String: Any]
            else { return nil }

            return Result(
                ok: (dict["ok"] as? Bool) ?? false,
                data: dict["data"] as? [String: Any],
                error: dict["error"] as? String
            )
        } catch {
            // 网关不可达很正常（没部署、不在同一网络），不打扰用户。
            return nil
        }
    }

    // MARK: - 解析

    /// 从网关返回里取出全部清晰度。
    ///
    /// 兼容两种位置：`data.video_model.video_list`（当前接口层级）
    /// 和 `data.video_list`（万一上游改了层级）。
    static func parseTracks(_ result: Result) -> [Track] {
        guard result.ok, let data = result.data else { return [] }

        var list: [[String: Any]] = []
        if let model = data["video_model"] as? [String: Any],
           let arr = model["video_list"] as? [[String: Any]] {
            list = arr
        } else if let arr = data["video_list"] as? [[String: Any]] {
            list = arr
        }

        return list.compactMap { item -> Track? in
            let meta = item["video_meta"] as? [String: Any] ?? [:]
            let definition = (meta["definition"] as? String)
                ?? (item["definition"] as? String)
                ?? ""
            guard !definition.isEmpty else { return nil }

            // URL 可能是明文 http，也可能是 base64
            var raw = (item["main_url"] as? String)
                ?? (item["backup_url"] as? String)
                ?? ""
            if raw.isEmpty { return nil }
            if !raw.lowercased().hasPrefix("http") {
                if let decoded = Data(base64Encoded: raw),
                   let text = String(data: decoded, encoding: .utf8) {
                    raw = text
                }
            }
            guard raw.lowercased().hasPrefix("http") else { return nil }

            let width = (meta["vwidth"] as? Int) ?? (item["vwidth"] as? Int) ?? 0
            let height = (meta["vheight"] as? Int) ?? (item["vheight"] as? Int) ?? 0
            let size = (meta["size"] as? NSNumber)?.int64Value ?? 0
            let codec = (meta["codec_type"] as? String) ?? (item["codec_type"] as? String) ?? ""

            // 加密信息：有 spade_a 说明需要本机解密
            var spade = ""
            if let enc = item["encrypt_info"] as? [String: Any] {
                spade = (enc["spade_a"] as? String) ?? ""
            }

            return Track(
                definition: definition,
                width: width,
                height: height,
                url: raw,
                size: size,
                codec: codec,
                spadeA: spade
            )
        }
    }
}