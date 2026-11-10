import SwiftUI

/// 搜索 = 服务端全库（片名包含匹配）。
///
/// 服务端索引了站方全部剧集（含抖音补充源），按片名做包含匹配，冷门老剧也搜得到；
/// 站方自己的搜索页是前端渲染的，客户端拿不到数据，所以不再直连站内搜索。
///
/// 同名各季是独立剧集（标题带「第N季」），会一起返回。
struct SearchView: View {
    @State private var q = ""
    @FocusState private var searchFocused: Bool

    // 服务端全库
    @State private var local: [Series] = []
    @State private var localTotal = 0
    @State private var indexCount = 0
    @State private var indexReady = false
    @State private var loadingIndex = true
    @State private var localTask: Task<Void, Never>?

    /// 全库一页前端最多展示多少条（服务端单次上限 100）
    private static let localLimit = 100

    private var keyword: String { q.trimmingCharacters(in: .whitespaces) }

    private var results: [Series] {
        guard !keyword.isEmpty else { return [] }
        // 同剧在红果/抖音各有一条时合并成一张卡，优先抖音源并保留换源入口。
        return Series.dedupe(local)
    }

    var body: some View {
        NavigationStack {
            // 用固定的 ZStack 承载三种状态，搜索框挂在外层：
            // 系统 .searchable 在结果页点「取消」时会把整条搜索栏收走，
            // 这里换成常驻输入框，取消只是收起键盘，输入入口始终在。
            ZStack {
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
                        .contentMargins(.bottom, 24, for: .scrollContent)
                        .safeAreaInset(edge: .top) { noteBar }
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
                // 点空白处收键盘：点击落点没被结果卡片/按钮消费时触发；
                // 用 simultaneousGesture，点卡片仍能正常进详情。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("搜索")
            .safeAreaInset(edge: .top) { searchBar }
            .onChange(of: q) { v in schedule(v) }
            .task { await warmUp() }
        }
    }

    /// 常驻搜索框：不再用 .searchable，避免它随结果页切换被销毁。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("输入片名", text: $q)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { searchFocused = false }
            if !q.isEmpty {
                Button {
                    q = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
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
                        ? "输入片名，在 \(indexCount) 部里搜索\n按片名包含匹配，冷门老剧也找得到"
                        : "服务端暂时连不上\n全库搜索需要它，检查下网络再试")
            }
        }
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            if localTask != nil { ProgressView() }
            Text(localTask != nil
                 ? "正在搜索…"
                 : "没有找到「\(keyword)」\n换个片名试试")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }

    private var noteBar: some View {
        VStack(spacing: 2) {
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(.ultraThinMaterial)
    }

    private var summary: String {
        var parts: [String] = []
        if localTotal > 0 {
            parts.append("全库命中 \(localTotal) 部")
            if localTotal > Self.localLimit { parts.append("显示前 \(Self.localLimit) 部") }
            let merged = local.count - results.count
            if merged > 0 { parts.append("合并 \(merged) 条同剧多源") }
        }
        if parts.isEmpty { return localTask != nil ? "正在搜索…" : "没有找到" }
        return parts.joined(separator: " · ")
    }

    // MARK: - 搜索调度

    /// 输入停顿 260ms 后再动手：两个请求都走网络，别把每个按键都发出去
    @MainActor
    private func schedule(_ raw: String) {
        localTask?.cancel()
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            local = []; localTotal = 0
            return
        }
        local = []; localTotal = 0

        localTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            let r = await CatalogAPI.search(key, limit: Self.localLimit)
            guard !Task.isCancelled, key == keyword else { return }
            local = r.list
            localTotal = r.total
            localTask = nil
        }

    }

    /// 进页面时先问一下服务端全库有多少条，用来显示「在 N 部里搜」。
    /// 拿不到（多半是服务端没起来/网络不通）就按 0 展示，搜索本身仍会试一次。
    private func warmUp() async {
        let n = await CatalogAPI.totalCount()
        indexCount = n
        indexReady = n > 0
        loadingIndex = false
    }
}

struct HistoryView: View {
    private enum Tab: String, CaseIterable { case history = "观看记录", follows = "我的关注" }
    @State private var tab: Tab = .history
    @ObservedObject private var store = WatchStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("记录类型", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)

                switch tab {
                case .history: historyList
                case .follows: FollowListView()
                }
            }
            .navigationTitle("记录")
        }
        .task { await FollowStore.shared.refreshAll() }
    }

    @ViewBuilder
    private var historyList: some View {
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
}
