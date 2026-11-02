import SwiftUI

/// 搜索 = 服务端全库（约 58.8 万部）＋ 站内服务端搜索（按站方相关度排序）。
///
/// 为什么要两份：站内搜索只覆盖它自己的索引，实测拿全库随机片名去搜，
/// 精确命中率只有约 50%（冷门老剧基本搜不到）；我们的全库覆盖 99.96%，
/// 但它是"片名包含"匹配，没有站方的相关度。两者合并去重才既不漏又好找。
///
/// 同名各季是独立剧集（标题带「第N季」），两边都会把它们一起返回。
struct SearchView: View {
    @State private var q = ""

    // 服务端全库
    @State private var local: [Series] = []
    @State private var localTotal = 0
    @State private var indexCount = 0
    @State private var indexReady = false
    @State private var loadingIndex = true
    @State private var localTask: Task<Void, Never>?

    // 站内搜索
    @State private var remote: [Series] = []
    @State private var remoteTotal = 0
    @State private var remoteNote = ""
    @State private var remoteBusy = false
    @State private var remoteTask: Task<Void, Never>?

    /// 全库一页前端最多展示多少条（服务端单次上限 100）
    private static let localLimit = 100

    private var keyword: String { q.trimmingCharacters(in: .whitespaces) }

    private var results: [Series] {
        let k = keyword
        guard !k.isEmpty else { return [] }
        var out: [Series] = []
        var ids = Set<String>()
        // 站内结果按站方相关度在前，全库结果补充在后
        for s in remote where ids.insert(s.id).inserted { out.append(s) }
        for s in local where ids.insert(s.id).inserted { out.append(s) }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if keyword.isEmpty {
                    emptyState
                } else if results.isEmpty {
                    searchingState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                            ForEach(results) { s in
                                NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                                    .buttonStyle(.plain)
                            }
                        }.padding()
                    }
                    .safeAreaInset(edge: .top) { noteBar }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "输入片名")
            .onChange(of: q) { v in schedule(v) }
            .task { await warmUp() }
        }
    }

    // MARK: - 各状态视图

    private var emptyState: some View {
        VStack(spacing: 12) {
            if loadingIndex {
                ProgressView()
                Text("正在连接全库…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                CompatUnavailable(
                    "搜索短剧", systemImage: "magnifyingglass",
                    desc: indexReady
                        ? "输入片名，在 \(indexCount) 部里搜索\n同时也会去站内再找一遍"
                        : "输入片名搜索站内\n（没配服务端地址，全库不可用）")
            }
        }
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            if remoteBusy || localTask != nil { ProgressView() }
            Text(remoteBusy || localTask != nil ? "正在搜索…" : "没有找到「\(keyword)」")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }

    private var noteBar: some View {
        VStack(spacing: 2) {
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            if !remoteNote.isEmpty {
                Text(remoteNote).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(.ultraThinMaterial)
    }

    private var summary: String {
        var parts: [String] = []
        if localTotal > 0 {
            parts.append("全库命中 \(localTotal) 部")
            if local.count < localTotal { parts.append("显示前 \(local.count) 部") }
        }
        if remoteTotal > 0 { parts.append("站内命中 \(remoteTotal) 部") }
        if parts.isEmpty { return remoteBusy ? "正在搜索…" : "没有找到" }
        return parts.joined(separator: " · ")
    }

    // MARK: - 搜索调度

    /// 输入停顿 260ms 后再动手：两个请求都走网络，别把每个按键都发出去
    @MainActor
    private func schedule(_ raw: String) {
        remoteTask?.cancel()
        localTask?.cancel()
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            local = []; localTotal = 0; remote = []; remoteTotal = 0; remoteNote = ""; remoteBusy = false
            return
        }
        local = []; localTotal = 0; remote = []; remoteTotal = 0; remoteNote = ""; remoteBusy = false

        localTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            let r = await CatalogAPI.search(key, limit: Self.localLimit)
            guard !Task.isCancelled, key == keyword else { return }
            local = r.list
            localTotal = r.total
            localTask = nil
        }

        remoteBusy = true
        remoteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            do {
                let p = try await SearchAPI.remote(key)
                guard !Task.isCancelled, key == keyword else { return }
                remote = p.list
                remoteTotal = p.total
            } catch {
                guard !Task.isCancelled, key == keyword else { return }
                remote = []; remoteTotal = 0
                remoteNote = "站内搜索没通，只用了全库索引"
            }
            remoteBusy = false
        }
    }

    /// 进页面时先问一下服务端全库有多少条，用来显示「在 N 部里搜」。
    /// 拿不到就当作没有全库（0），这时只搜站内。
    private func warmUp() async {
        let n = await CatalogAPI.totalCount()
        indexCount = n
        indexReady = n > 0
        loadingIndex = false
    }
}

struct HistoryView: View {
    @ObservedObject private var store = WatchStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    CompatUnavailable("暂无观看记录", systemImage: "clock", desc: "播放后会自动记录进度")
                } else {
                    List {
                        ForEach(store.items) { it in
                            NavigationLink {
                                DetailView(series: Series(id: it.seriesId, title: it.title, cover: it.cover))
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: it.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                                        placeholder: { Rectangle().fill(Color.white.opacity(0.1)) }
                                        .frame(width: 46, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(it.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text("看到第 \(it.episode) 集 · \(Int(it.seconds / 60)) 分 \(Int(it.seconds) % 60) 秒")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx where i < store.items.count {
                                store.remove(seriesId: store.items[i].seriesId)
                            }
                        }
                    }
                }
            }
            .navigationTitle("观看记录")
        }
    }
}