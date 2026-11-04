import SwiftUI

/// 首页区块 -> 站内频道 slug。
///
/// 首页每个区块只给 9 条，想看全得去 /category/<slug> 按页拉。
/// tab_type 是站内短名（all/human/comic/ai），和 slug 不是一套命名，
/// 所以名称也对一遍，站点改名也不会静默走到错频道。
extension HomeSection {
    var channelSlugs: [String] {
        switch id {
        case "human": return ["real-drama"]
        case "comic": return ["comic-drama"]
        case "ai":    return ["ai-drama"]
        // 「热播短剧」= 三种短剧频道合起来（漫画不算短剧）
        case "all":   return ["real-drama", "comic-drama", "ai-drama"]
        default:
            if name.contains("真人") { return ["real-drama"] }
            if name.contains("漫剧") { return ["comic-drama"] }
            if name.contains("漫画") { return ["comic"] }
            if name.uppercased().contains("AI") { return ["ai-drama"] }
            return ["real-drama", "comic-drama", "ai-drama"]
        }
    }
}

struct HomeView: View {
    @State private var sections: [HomeSection] = []
    @State private var err: String?
    @State private var loading = true
    @State private var showAbout = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("加载中…") }
                else if let e = err { CompatUnavailable("加载失败", systemImage: "wifi.slash", desc: e) }
                else { list }
            }
            .navigationTitle("短剧盒子")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLog = true } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAbout = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showLog) { LogView() }
            .task { await load() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { sec in
                    VStack(alignment: .leading, spacing: 8) {
                        // 标题行：右边「查看更多」进频道分页，不再只给 9 条
                        HStack(alignment: .firstTextBaseline) {
                            Text(sec.name).font(.headline)
                            Spacer()
                            NavigationLink {
                                ChannelGridView(title: sec.name, slugs: sec.channelSlugs)
                            } label: {
                                HStack(spacing: 2) {
                                    Text("查看更多")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(sec.items) { s in
                                    NavigationLink { DetailView(series: s) } label: { PosterCard(series: s) }
                                        .buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
            }.padding(.vertical)
        }
    }

    private func load() async {
        loading = true; err = nil
        do {
            let s = try await Catalog.home()
            sections = s
            if s.isEmpty { err = "暂无数据" }
        } catch { err = "\(error)" }
        loading = false
    }
}

/// 按频道分页浏览，滚到底自动续下一页。
///
/// 首页每个区块只有 9 条、站内单页 24 条，想看全只能这样一页页翻。
/// 传多个 slug 时（「热播短剧」= 真人剧 + 漫剧 + AI剧）每翻一页各取一页再合并去重。
struct ChannelGridView: View {
    let title: String
    let slugs: [String]

    @State private var items: [Series] = []
    @State private var seen = Set<String>()
    @State private var page = 1
    @State private var loading = false
    @State private var finished = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { s in
                    NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                        .buttonStyle(.plain)
                        .onAppear {
                            // 最后一张露面就去取下一页
                            if s.id == items.last?.id { Task { await more() } }
                        }
                }
            }.padding()

            Group {
                if loading { ProgressView().padding(.bottom, 24) }
                else if finished && !items.isEmpty {
                    Text("没有更多了").font(.footnote)
                        .foregroundStyle(.secondary).padding(.bottom, 24)
                } else if items.isEmpty && finished {
                    // 只在真的翻完一轮还是空的时候才说没内容，
                    // 否则第一次进页面会闪一下「暂无内容」
                    CompatUnavailable("暂无内容", systemImage: "tray",
                                       desc: "这个频道暂时没有可展示的剧集")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reset(); await more() }
        .task { await more() }
    }

    private func more() async {
        // 这个守卫在主 actor 上同步跑完，连点也只会进来一次
        guard !loading, !finished else { return }
        loading = true
        defer { loading = false }

        var added = 0
        for slug in slugs {
            guard let list = try? await Catalog.category(slug, page: page), !list.isEmpty else { continue }
            for s in list where !seen.contains(s.id) {
                seen.insert(s.id); items.append(s); added += 1
            }
        }
        if added == 0 { finished = true } else { page += 1 }
    }

    private func reset() {
        items = []; seen = []; page = 1; finished = false
    }
}

/// 分类页 = **按标签翻库**。
///
/// 原来这里是「频道」（真人剧 / 漫剧 / AI剧），但那和首页那几行是同一批数据、
/// 只是换个排版，等于没有分类价值。改成按标签浏览：服务端目录层维护全库
/// 站方全库的标签倒排（现在 400 个出头，会慢慢长），翻页是一次索引切片，这里只管连翻。
struct BrowseView: View {
    @State private var buckets: [CatalogAPI.TagBucket] = []
    @State private var tag: String?
    @State private var building = true
    @State private var showAll = false

    /// 顶部只展示最热的一批，其余标签进「查看更多」
    private static let hotCount = 16
    private var hot: [CatalogAPI.TagBucket] { Array(buckets.prefix(Self.hotCount)) }

    /// 选中的标签若不在热门里（从「查看更多」挑的），也插到最前面显示，
    /// 否则顶部会看不出当前选的是哪个。
    private var shown: [CatalogAPI.TagBucket] {
        guard let t = tag, !hot.contains(where: { $0.tag == t }),
              let b = buckets.first(where: { $0.tag == t }) else { return hot }
        return [b] + hot
    }

    var body: some View {
        NavigationStack {
            Group {
                if building {
                    ProgressView("正在整理标签…")
                } else if buckets.isEmpty {
                    CompatUnavailable("没有标签数据", systemImage: "tag.slash",
                                       desc: CatalogAPI.isEnabled
                                           ? "服务端没返回标签，稍后再试"
                                           : "没配服务端地址，标签浏览不可用")
                } else {
                    VStack(spacing: 0) {
                        tagHeader
                        chips
                        Divider()
                        if let t = tag {
                            // 换标签就换一份新的分页状态
                            TagResultGrid(tag: t).id(t)
                        } else {
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("分类")
            .sheet(isPresented: $showAll) {
                AllTagsView(buckets: buckets, selected: $tag, dismissTo: $showAll)
            }
            .task {
                guard buckets.isEmpty else { return }
                buckets = await CatalogAPI.tagBuckets()
                if tag == nil { tag = buckets.first?.tag }
                building = false
            }
        }
    }

    /// 「热门标签」标题行 + 「查看更多」入口
    private var tagHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("热门标签").font(.headline)
            Spacer()
            Button { showAll = true } label: {
                HStack(spacing: 2) {
                    Text("查看更多（\(buckets.count)）")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 热门标签整块换行铺开（不做横向滚动），一眼能看全
    private var chips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(shown, id: \.tag) { b in
                Button { tag = b.tag } label: {
                    Text(b.tag)
                        .font(.system(size: 13, weight: tag == b.tag ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(tag == b.tag ? Color.pink.opacity(0.85)
                                                 : Color.white.opacity(0.12))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// 全部标签。几百个标签靠一个搜索框找。
private struct AllTagsView: View {
    let buckets: [CatalogAPI.TagBucket]
    @Binding var selected: String?
    @Binding var dismissTo: Bool
    @State private var q = ""

    private var list: [CatalogAPI.TagBucket] {
        let k = q.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return buckets }
        return buckets.filter { $0.tag.localizedCaseInsensitiveContains(k) }
    }

    var body: some View {
        NavigationStack {
            List(list, id: \.tag) { b in
                Button {
                    selected = b.tag
                    dismissTo = false
                } label: {
                    HStack {
                        Text(b.tag).foregroundStyle(.primary)
                        if selected == b.tag {
                            Image(systemName: "checkmark").foregroundStyle(.pink)
                        }
                        Spacer()
                        Text("\(b.count) 部").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("全部标签（\(buckets.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $q, prompt: "找标签")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismissTo = false }
                }
            }
        }
    }
}

/// 某个标签下的剧集，滚到底自动续。
private struct TagResultGrid: View {
    let tag: String

    @State private var items: [Series] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = false
    @State private var finished = false

    private let per = 24
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        ScrollView {
            if total > 0 {
                HStack {
                    Text("「\(tag)」共 \(total) 部")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text("按最新排序")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.top, 10)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { s in
                    NavigationLink { DetailView(series: s) } label: {
                        PosterCard(series: s, width: 110)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if s.id == items.last?.id { Task { await more() } }
                    }
                }
            }.padding()

            Group {
                if loading { ProgressView().padding(.bottom, 24) }
                else if finished && !items.isEmpty {
                    Text("没有更多了").font(.footnote)
                        .foregroundStyle(.secondary).padding(.bottom, 24)
                } else if items.isEmpty && finished {
                    CompatUnavailable("暂无内容", systemImage: "tray",
                                       desc: "这个标签下暂时没有可展示的剧集")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { reset(); await more() }
        .task { await more() }
    }

    private func more() async {
        guard !loading, !finished else { return }
        loading = true
        defer { loading = false }
        let off = page * per
        let r = await CatalogAPI.tagPage(tag, offset: off, limit: per)
        total = r.total
        if r.items.isEmpty { finished = true } else {
            items.append(contentsOf: r.items)
            page += 1
        }
    }

    private func reset() {
        items = []; page = 0; total = 0; finished = false
    }
}
