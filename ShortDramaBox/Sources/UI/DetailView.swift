import SwiftUI

struct DetailView: View {
    let series: Series
    @State private var detail: Series
    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var play: Episode?
    @State private var siblings: [Series] = []
    @ObservedObject private var store = WatchStore.shared

    init(series: Series) { self.series = series; _detail = State(initialValue: series) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !detail.intro.isEmpty {
                    Text(detail.intro).font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65)).padding(.horizontal)
                }
                if let p = store.progress(seriesId: series.id) {
                    Button {
                        if p.episode >= 1 && p.episode <= episodes.count { play = episodes[p.episode - 1] }
                    } label: {
                        Label("继续观看 第\(p.episode)集", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.pink).padding(.horizontal)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else { episodeGrid }
                if !siblings.isEmpty { otherSeasons }
            }.padding(.vertical)
        }
        .navigationTitle(detail.title).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $play) { ep in
            PlayerView(series: detail, episodes: episodes, start: ep)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 110, height: 146)
                .overlay {
                    AsyncImage(url: URL(string: detail.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { Rectangle().fill(Color.white.opacity(0.08)) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title).font(.headline)
                Text("共 \(max(detail.episodeCount, episodes.count)) 集")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !detail.tags.isEmpty {
                    Text(detail.tags.prefix(4).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.pink.opacity(0.9))
                }
            }
            Spacer()
        }.padding(.horizontal)
    }

    private var episodeGrid: some View {
        // 「看到第几集」只查一次。原来写在 ForEach 里、每集查两遍：
        // 一百集就是两百次历史表线性扫描，而且 WatchStore 每 5 秒记一次进度
        // 都会让整个网格重算一遍 —— 选集页卡顿主要来自这里。
        let watching = store.progress(seriesId: series.id)?.episode
        return VStack(alignment: .leading, spacing: 8) {
            Text("选集").font(.headline).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                ForEach(episodes) { ep in
                    Button { play = ep } label: {
                        Text("\(ep.index)")
                            .font(.system(size: 14, weight: watching == ep.index ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(watching == ep.index
                                        ? Color.pink.opacity(0.35) : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(.white)
                }
            }.padding(.horizontal)
        }
    }

    /// 同名其它季：季是独立剧集（标题带「第N季」）。
    /// 先用站内搜索（它按站方相关度给），但站方已改成前端渲染、多半拿不到，
    /// 所以回落到服务端全库的片名包含匹配 —— 一样能把兄弟季捞出来。
    private var otherSeasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("其它季（\(siblings.count)）").font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(siblings) { s in
                        NavigationLink { DetailView(series: s) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AsyncImage(url: URL(string: s.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                                    placeholder: { Rectangle().fill(Color.white.opacity(0.08)) }
                                    .frame(width: 88, height: 117)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(s.seasonMarker ?? s.title)
                                    .font(.system(size: 11)).lineLimit(2)
                                    .frame(width: 88, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                    }
                }.padding(.horizontal)
            }
        }
    }

    private func load() async {
        loading = true
        if let (s, e) = try? await Catalog.detail(series.id) {
            if !s.title.isEmpty { detail = s }
            episodes = e
        }
        loading = false
        await loadSiblings()
    }

    private func loadSiblings() async {
        guard let base = detail.seasonBase ?? series.seasonBase else { return }
        var found: [Series] = []
        if let p = try? await SearchAPI.remote(base) { found = p.list }
        if found.isEmpty {
            found = await CatalogAPI.search(base, limit: 60).list
        }
        siblings = found
            .filter { $0.id != series.id && $0.title.hasPrefix(base) }
            .sorted { ($0.seasonNumber ?? 9999) < ($1.seasonNumber ?? 9999) }
    }
}
