import SwiftUI

struct DetailView: View {
    let series: Series
    @State private var detail: Series
    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var play: Episode?
    @State private var siblings: [Series] = []
    /// 多季拼接后的播放列表：跨季自动连播靠它。
    @State private var playlist: [Episode] = []
    /// 换源后的轻提示（「已切换到抖音源」）。
    @State private var sourceNotice: String?
    @ObservedObject private var store = WatchStore.shared
    @ObservedObject private var follows = FollowStore.shared

    init(series: Series) { self.series = series; _detail = State(initialValue: series) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !detail.intro.isEmpty {
                    Text(detail.intro).font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65)).padding(.horizontal)
                }
                if let p = store.progress(seriesId: detail.id) {
                    Button {
                        if p.episode >= 1 && p.episode <= episodes.count {
                            play = playlistEpisode(for: episodes[p.episode - 1])
                        }
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
        .overlay(alignment: .top) {
            if let sourceNotice {
                Text(sourceNotice)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.78)).foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sourceNotice)
        .fullScreenCover(item: $play) { ep in
            PlayerView(series: detail,
                       episodes: playlist.isEmpty ? episodes : playlist,
                       start: ep,
                       onSwitchSource: { alt in
                           let number = ep.displayNumber
                           play = nil          // 先收起播放器，切源后再自动续播同一集
                           Task { await switchSource(to: alt, resumeAt: number) }
                       })
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
                HStack(spacing: 8) {
                    SourceBadge(series: detail, fontSize: 10)
                    Text("共 \(max(detail.episodeCount, episodes.count)) 集")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if !alternates.isEmpty { sourceMenu }
                }
                if !detail.tags.isEmpty {
                    Text(detail.tags.prefix(4).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.pink.opacity(0.9))
                }
                Button {
                    follows.toggle(series: detail, siblings: siblings)
                } label: {
                    Label(follows.isFollowing(detail) ? "已关注" : "关注",
                          systemImage: follows.isFollowing(detail) ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.pink)
                .controlSize(.small)
            }
            Spacer()
        }.padding(.horizontal)
    }

    private var episodeGrid: some View {
        // 「看到第几集」只查一次。原来写在 ForEach 里、每集查两遍：
        // 一百集就是两百次历史表线性扫描，而且 WatchStore 每 5 秒记一次进度
        // 都会让整个网格重算一遍 —— 选集页卡顿主要来自这里。
        let watching = store.progress(seriesId: detail.id)?.episode
        return VStack(alignment: .leading, spacing: 8) {
            Text("选集").font(.headline).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                ForEach(episodes) { ep in
                    Button { play = playlistEpisode(for: ep) } label: {
                        Text("\(ep.displayNumber)")
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
        let sid = detail.id
        if let (s, e) = try? await Catalog.detail(sid) {
            if !s.title.isEmpty {
                var fetched = s
                // 服务端详情不含「多源」信息，换源列表要保留下来。
                fetched.alternates = detail.alternates
                if fetched.source.isEmpty { fetched.source = detail.source }
                detail = fetched
            }
            episodes = e
        }
        // 先让当前季能点，再慢慢把其它季拼进来。
        playlist = episodes.map { ep in
            Episode(index: ep.index, vid: ep.vid,
                    seriesId: detail.id, seriesTitle: detail.title, seriesCover: detail.cover,
                    seasonNumber: detail.seasonNumber ?? 1, episodeNumber: ep.index)
        }
        loading = false
        await loadSiblings()
        await buildPlaylist()
        if follows.isFollowing(detail) {
            follows.merge(series: detail, siblings: siblings)
        }
        follows.markSeen(base: detail.seasonBase ?? detail.title, season: detail.seasonNumber ?? 0)
    }

    /// 当前季第 N 集 → 多季播放列表里的那一项（全局序号）。
    private func playlistEpisode(for ep: Episode) -> Episode {
        playlist.first { $0.seriesId == detail.id && $0.episodeNumber == ep.index } ?? ep
    }

    /// 把所有兄弟季的集数按季号接起来。没有季标记时保持当前季不变。
    private func buildPlaylist() async {
        let merged = await MultiSeasonPlaylist.build(
            series: detail, episodes: episodes, siblings: siblings)
        if merged.count > playlist.count { playlist = merged }
    }

    /// 当前详情之外的可换来源（已合并进来的抖音/红果条目）。
    private var alternates: [Series] {
        (detail.alternates ?? []).filter { $0.id != detail.id }
    }

    private var sourceMenu: some View {
        Menu {
            ForEach([detail] + alternates) { s in
                Button {
                    Task { await switchSource(to: s) }
                } label: {
                    if s.id == detail.id {
                        Label("\(s.sourceName)（当前）", systemImage: "checkmark")
                    } else {
                        Text("\(s.sourceName) · \(s.episodeCount) 集")
                    }
                }
            }
        } label: {
            Label("换源", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(.gray)
    }

    /// 切换到同一部剧的另一个来源；resumeAt 传入时切完自动续播这一集。
    private func switchSource(to s: Series, resumeAt number: Int? = nil) async {
        guard s.id != detail.id else { return }
        // 换源后仍要能换回来：把旧来源放进新详情的 alternates。
        var target = s
        var old = detail
        old.alternates = nil
        var alts = (target.alternates ?? []).filter { $0.id != target.id && $0.id != old.id }
        alts.insert(old, at: 0)
        target.alternates = alts
        detail = target
        episodes = []
        playlist = []
        siblings = []
        loading = true
        await load()
        if let n = number, let ep = episodes.first(where: { $0.displayNumber == n }) {
            play = playlistEpisode(for: ep)
        }
        sourceNotice = "已切换到\(s.sourceName)源"
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if sourceNotice == "已切换到\(s.sourceName)源" { sourceNotice = nil }
    }

    private func loadSiblings() async {
        // 第一季标题可能不带「第N季」，用完整标题作基准，才能找到「…第2季」。
        let base = detail.seasonBase ?? series.seasonBase ?? detail.title
        var found = Series.dedupe(await CatalogAPI.search(base, limit: 60).list)
        if found.isEmpty, let p = try? await SearchAPI.remote(base) {
            found = Series.dedupe(p.list)
        }
        siblings = found
            .filter {
                $0.id != detail.id
                    && $0.dedupeKey != detail.dedupeKey   // 同剧的另一个来源不算「其它季」
                    && ($0.seasonBase ?? $0.title) == base
            }
            .sorted { ($0.seasonNumber ?? 9999) < ($1.seasonNumber ?? 9999) }

        // 顺手记住同剧的另一个来源：从首页/推荐进来的卡片没带 alternates，
        // 详情页也应有「换源」入口。
        var extras: [Series] = []
        for s in found where s.dedupeKey == detail.dedupeKey {
            if s.id != detail.id { extras.append(s) }
            extras.append(contentsOf: s.alternates ?? [])
        }
        absorbAlternates(extras)
    }

    /// 把额外来源并入当前详情的 alternates（按 id 去重、保持扁平）。
    private func absorbAlternates(_ extras: [Series]) {
        var alts = detail.alternates ?? []
        for var e in extras where e.id != detail.id {
            guard !alts.contains(where: { $0.id == e.id }) else { continue }
            e.alternates = nil
            alts.append(e)
        }
        if !alts.isEmpty { detail.alternates = alts }
    }
}
