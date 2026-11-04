import SwiftUI
import AVKit
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 单条推荐

/// 推荐流里的两种片子，也是卡片左上角那枚标签。页面上只有这两种。
enum FeedKind: String, CaseIterable {
    /// 新剧：服务端全库「最新上架在前」，占七成
    case new = "新剧"
    /// 爆剧：首页板块 + 频道首页的站方推荐位，占三成
    case hot = "爆剧"

    var icon: String {
        switch self {
        case .new: return "sparkles"
        case .hot: return "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .new: return .pink
        case .hot: return .orange
        }
    }
}

struct FeedItem: Identifiable {
    enum Status: Equatable {
        case pending              // 还没开始解析
        case resolving            // 正在解析片源
        case downloading(Double)  // 正在下载解密
        case ready(URL)
        case failed(String)
    }

    var series: Series
    /// 这部剧是从哪个池子来的（新剧 / 爆剧），卡片上照着它打标签
    var kind: FeedKind = .new
    var episode: Episode?
    /// 解析时顺手存下的全集列表，点画面时直接起播，不用再请求一次
    var episodes: [Episode] = []
    var track: VideoTrack?
    var status: Status = .pending
    var id: String { series.id }
}

// MARK: - 纯播放器视图
//
// 不用 SwiftUI 的 VideoPlayer：它自带一套控制层，放进分页容器里
// 会按自己的方式算尺寸，容易导致画面被裁或比例不对。
// 这里直接用 AVPlayerLayer，videoGravity 自己定。
//
// 关于「铺满」：实测片库里 58% 的片源是横屏 1920x1080（抽样 31 部，18 部横屏）。
// 竖屏手机上按铺满渲染：缩放 max(393/1920, 852/1080)=0.789，渲染成 1515x852，
// 屏幕上一共只能看到中间 25.9% 的宽度，而且相对「适应」放大了 3.85 倍 ——
// 表现就是"横屏被截了一条铺满屏幕"，又糊又看不到内容。
// 竖屏片源同样按铺满只保留约 80% 宽度，属于正常的满屏裁边。
// 所以默认交给自动判定：裁太多就改成完整显示。
#if os(iOS)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// nil = 自动按比例决定；true = 强制铺满；false = 强制完整显示
    var fill: Bool? = nil
    /// 片源尺寸提示（接口的 vwidth/vheight）。.zero 表示未知
    var videoSize: CGSize = .zero

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.userFill = fill
        v.hint = videoSize
        v.attach(player)
        return v
    }

    func updateUIView(_ v: PlayerHostView, context: Context) {
        v.userFill = fill
        v.hint = videoSize
        v.attach(player)
    }

    static func dismantleUIView(_ v: PlayerHostView, coordinator: ()) {
        v.attach(nil)
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// nil = 自动；true = 强制铺满；false = 强制完整显示
    var userFill: Bool? { didSet { if userFill != oldValue { applyGravity() } } }
    /// 接口给的片源尺寸（可能为 .zero）
    var hint: CGSize = .zero { didSet { if hint != oldValue { applyGravity() } } }

    private var sizeObs: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?

    // 关键：UIKit 承载视图默认参与触摸，会吃掉上层 SwiftUI 按钮（选集等）的点击，
    // 表现就是"点了没反应"。播放器只负责画面，不接收任何手势。
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }
    deinit { sizeObs?.invalidate() }

    func attach(_ player: AVPlayer?) {
        if playerLayer.player !== player { playerLayer.player = player }
        let item = player?.currentItem
        // updateUIView 每次刷新都会走到这里，item 没换就别重建 KVO
        if observedItem === item { applyGravity(); return }
        observedItem = item
        sizeObs?.invalidate(); sizeObs = nil
        guard let item else { applyGravity(); return }
        sizeObs = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] it, _ in
            let s = it.presentationSize
            guard s.width > 0, s.height > 0 else { return }
            DispatchQueue.main.async { self?.applyGravity() }
        }
        applyGravity()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }

    /// 解码出来的真实尺寸优先于接口值：公开备用源那种情况下接口值是估的
    private var videoSize: CGSize {
        if let s = playerLayer.player?.currentItem?.presentationSize, s.width > 0, s.height > 0 {
            return s
        }
        return hint
    }

    func applyGravity() {
        let fill = userFill ?? Self.autoFill(video: videoSize, view: bounds.size)
        let g: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }

    /// 自动判定：铺满后可见画面不足七成就改成完整显示。
    /// 竖屏片源铺满约保留 80%，横屏只剩 25.9%，阈值取在两者之间。
    static func autoFill(video: CGSize, view: CGSize) -> Bool {
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else {
            return false   // 尺寸未知时先完整显示，绝不裁掉画面
        }
        let s = max(view.width / video.width, view.height / video.height)
        let visible = min(view.width / (video.width * s), view.height / (video.height * s))
        return visible >= 0.70
    }
}
#else
/// 非 iOS（仅用于本机编译检查）
struct PlayerLayerView: View {
    let player: AVPlayer
    var fill: Bool? = nil
    var videoSize: CGSize = .zero
    var body: some View { Color.black }
}
#endif

/// 画面填充偏好：推荐页与播放器页共用同一个设置
enum VideoFit {
    static let auto = 0, fill = 1, fit = 2

    /// nil 交给自动判定
    static func forced(_ mode: Int) -> Bool? {
        switch mode {
        case fill: return true
        case fit: return false
        default: return nil
        }
    }
    static func label(_ mode: Int) -> String {
        switch mode {
        case fill: return "铺满"
        case fit: return "适应"
        default: return "自动"
        }
    }
    static func icon(_ mode: Int) -> String {
        switch mode {
        case fill: return "rectangle.expand.vertical"
        case fit: return "rectangle.arrowtriangle.2.inward"
        default: return "wand.and.stars"
        }
    }
    static func next(_ mode: Int) -> Int { (mode + 1) % 3 }
}

// MARK: - 推荐流混合配方

/// 推荐流的混合配方：**新剧 : 爆剧 = 7 : 3**，页面上只有这两种，每个卡片都带标签。
///
/// 新剧来自服务端全库「最新在前」，池子用不完；爆剧是首页板块 + 频道首页的
/// 站方推荐位，池子有限。爆剧抽完之后缺额**全部并给新剧**——宁可多给新剧，
/// 也不拿冷门老剧凑数。
///
/// 想调整比例只改这两个权重，别的都不用动。
enum FeedMix {
    /// 新剧（服务端全库「最新在前」）
    static let newWeight = 7
    /// 爆剧（首页板块 + 频道首页的站方推荐位）
    static let hotWeight = 3
    /// 每批条数（首批 + 每次续抽）
    static let batchSize = 240

    /// 算一批的配额。爆剧池不够时缺额让给新剧，每批条数保持 `batchSize`。
    static func plan(hotAvailable: Int, batchSize: Int = FeedMix.batchSize) -> (new: Int, hot: Int) {
        guard batchSize > 0 else { return (0, 0) }
        let hotIdeal = batchSize * hotWeight / (newWeight + hotWeight)
        let hot = min(hotIdeal, max(0, hotAvailable))
        return (batchSize - hot, hot)
    }
}

@MainActor
/// 推荐流数据。
///
/// 卡在「解密中 100%」的成因不是线程问题（这个类一直是 @MainActor），而是两处：
/// 进度回调是 `Task { @MainActor }` 排队过来的，可能晚于最终状态落地，把已经写好的
/// `.ready`（或 pause() 刚收回的 `.pending`）又盖回 `.downloading`；而被取消的
/// resolve 什么都不写、prepareOne 又不再重试 `.downloading` —— 一次丢失的回写
/// 就成了永久卡死，文件其实早已下好，所以点进详情页反而能播。
final class FeedModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    /// 全库总量（界面上如实显示），以及推荐流「还能不能再抽一批」
    private(set) var sampleTotal = 0
    /// 追加抽样是否在进行中（防重入）
    private var appending = false
    /// 推荐流常驻条数上限：约 1200 条，内存恒定在 1MB 以内，不随库大小膨胀
    static let itemCap = 1200

    /// 爆剧池：首页板块 + 各频道第 1 页的站方推荐位。有限池，抽完为止。
    private var hotPool: [Series] = []
    private var hotCursor = 0
    /// 新剧游标：已经扫到「最新在前」顺序的第几条（跨批次推进，不重复）
    private var newCursor = 0
    /// 本会话已经放进推荐流的剧 id，跨批次全局去重
    private var seenIDs = Set<String>()

    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published private(set) var poolNote = ""

    private var inFlight: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var paused = false
    private var currentIndex = 0
    private let prefetchAhead = 1

    /// 推荐池：**新剧 : 爆剧 = 7 : 3**，只从这两个池子取；全部按 id 去重后整批打乱。
    func load() async {
        loading = true; error = nil
        hotCursor = 0; newCursor = 0; seenIDs.removeAll()

        // 爆剧池 = 首页板块 + 各频道第 1 页（站方推荐位）。网络挂了也不影响新剧池。
        var hot: [Series] = []
        if let secs = try? await Catalog.home() { hot = secs.flatMap { $0.items } }
        if hot.count < 40 {
            for c in Catalog.categories {
                if let more = try? await Catalog.category(c.slug, page: 1) { hot += more }
                if hot.count >= 160 { break }
            }
        }
        var hotSeen = Set<String>()
        hotPool = hot.filter { !$0.title.isEmpty && hotSeen.insert($0.id).inserted }

        // 全库条数从服务端拿；拿不到就当没有全库，只用爆剧池。
        sampleTotal = await CatalogAPI.totalCount()

        var batch = await nextBatch()
        if batch.isEmpty && sampleTotal == 0 {
            // 服务端不可用时兜底：至少把爆剧池打乱放出去
            batch = hotPool.shuffled().map { FeedItem(series: $0, kind: .hot) }
            poolNote = "站方推荐 \(batch.count) 部，随机播放"
        } else {
            poolNote = "新剧 7 : 爆剧 3 · 全库 \(sampleTotal) 部"
        }
        guard !batch.isEmpty else {
            error = "没有拿到推荐内容，检查下网络"
            loading = false
            return
        }
        items = batch
        loading = false
    }

    /// 组一批：按 `FeedMix.plan` 的配额取新剧和爆剧，全局去重后打乱。
    /// 爆剧池有限，抽完（或不够）的缺额自动并给新剧，每批条数仍是 240。
    private func nextBatch() async -> [FeedItem] {
        let plan = FeedMix.plan(hotAvailable: max(0, hotPool.count - hotCursor))
        var picked: [FeedItem] = []

        // 1) 爆剧：有限池，抽完为止
        var hotTaken = 0
        while hotTaken < plan.hot, hotCursor < hotPool.count {
            let s = hotPool[hotCursor]
            hotCursor += 1
            guard seenIDs.insert(s.id).inserted else { continue }
            picked.append(FeedItem(series: s, kind: .hot))
            hotTaken += 1
        }

        // 2) 新剧：全库「最新在前」，把这一批补满（含爆剧的缺额）。
        // 服务端单页最多 100 条，240 条要分几轮拿；遇到重复就多要一轮。
        var want = FeedMix.batchSize - picked.count
        var rounds = 0
        while want > 0, rounds < 6 {
            rounds += 1
            let page = await CatalogAPI.newest(offset: newCursor, limit: min(want, 100))
            guard !page.items.isEmpty else { break }
            newCursor = page.next
            for s in page.items {
                guard seenIDs.insert(s.id).inserted else { continue }
                picked.append(FeedItem(series: s, kind: .new))
                want -= 1
                if want == 0 { break }
            }
        }

        return picked.shuffled()
    }

    /// 把离当前位置太远的待办丢掉，避免滑太久后一堆任务堆积
    func prepare(_ index: Int) {
        currentIndex = index
        guard !paused else { return }
        guard items.indices.contains(index) else { return }
        for k in index...(index + prefetchAhead) where items.indices.contains(k) {
            prepareOne(k)
        }
        // 快滑到底了就再抽一批补上，新剧游标一直往下走，能无限滑。
        // 总量封顶 itemCap：推荐流常驻内存始终是几百条，不随库大小膨胀。
        if index > items.count - 6, items.count < Self.itemCap, sampleTotal > items.count {
            appendSample()
        }
    }

    /// 再抽一批（去重后追加）。抽样/解码在后台线程，不占主线程。
    private func appendSample() {
        guard !appending else { return }
        appending = true
        Task { @MainActor in
            defer { appending = false }
            let add = await nextBatch()
            guard !add.isEmpty else { return }
            let room = max(0, Self.itemCap - items.count)
            items += add.prefix(room)
        }
    }

    /// 系统内存告警：停预取、把**非当前页**已解析的地址丢掉、缓存按上限收紧。
    /// 当前正在看的那一页不动，免得画面被打断（内存告急时这一下往往就是
    /// 「被杀」和「活着」的区别）。
    func relaxMemory() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll(); inFlight.removeAll()
        for i in items.indices where i != currentIndex {
            switch items[i].status {
            case .ready, .resolving, .downloading: items[i].status = .pending
            default: break
            }
        }
        MediaStore.pruneIfNeeded()
    }

    /// 切走这个 Tab：把预取全部停掉。
    /// 不停的话，人在详情页/选集页时后台还在下两三路 1080p，
    /// 带宽被占满，拉详情就「加载老半天」。
    func pause() {
        paused = true
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
        inFlight.removeAll()
        for i in items.indices {
            switch items[i].status {
            case .resolving, .downloading:
                items[i].status = .pending   // 恢复时会重新解析，已缓存的会秒开
            default:
                break
            }
        }
    }

    /// 切回来：从当前这一页重新排预取
    func resume() {
        paused = false
        prepare(currentIndex)
    }

    /// 从播放器回来后重新解析这一页，让它接着新进度播
    func refresh(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].status = .pending
        prepareOne(index)
    }

    /// 这个条目该不该起一次解析。
    ///
    /// `.resolving` / `.downloading` 只有在「确实还有任务在跑」时才等；任务已经没了
    /// （回调被取消或丢掉）就必须重来 —— 否则一次丢失的回写会让这一页永远卡在
    /// 「解密中 100%」，怎么划回来都不会自己恢复。
    nonisolated static func shouldStart(status: FeedItem.Status, inFlight: Bool) -> Bool {
        // 有任务在飞就一律等它：重复起任务会对同一部剧下两路，还会搅乱 inFlight 跟踪。
        if inFlight { return false }
        switch status {
        case .ready: return false
        case .resolving, .downloading, .pending, .failed: return true
        }
    }

    private func prepareOne(_ i: Int) {
        guard !paused else { return }
        guard items.indices.contains(i) else { return }
        let item = items[i]
        guard Self.shouldStart(status: item.status,
                               inFlight: inFlight.contains(item.series.id)) else { return }
        inFlight.insert(item.series.id)
        items[i].status = .resolving

        let t = Task { [weak self] in
            guard let self else { return }
            await self.resolve(i)
        }
        tasks[item.series.id] = t
    }

    private func resolve(_ i: Int) async {
        guard items.indices.contains(i) else { return }
        let series = items[i].series
        defer { inFlight.remove(series.id); tasks.removeValue(forKey: series.id) }
        guard !Task.isCancelled else { return }

        // 详情（拿集数）
        guard let (full, eps) = try? await Catalog.detail(series.id), !eps.isEmpty else {
            HGLog.w("推荐", "\(series.title) 拿不到剧集，标记暂无片源")
            if isCurrent(i, series.id) { setStatus(i, .failed("暂无片源")) }
            return
        }
        guard isCurrent(i, series.id), !Task.isCancelled else { return }

        // 简介只有详情接口才有（目录层的条目不带简介，省流量），补进这一页
        if items[i].series.intro.isEmpty, !full.intro.isEmpty {
            items[i].series.intro = full.intro
        }
        if items[i].series.episodeCount == 0 { items[i].series.episodeCount = full.episodeCount }

        // 固定从第 1 集开始。
        //
        // 这里以前是「有记录就接着上次那集，没有就随机一集」。推荐流是刷到就
        // 顺眼看一眼的场景，一进来就是第 47 集、还是从半截开始，前情全断了，
        // 接着看反而更割裂。想续看走「历史」页，或者在播放页里选集。
        let ep = eps.first { $0.index == 1 } ?? eps[0]
        items[i].episode = ep
        items[i].episodes = eps
        HGLog.i("推荐", "\(series.title) 共 \(eps.count) 集")

        // 取流：全部档位都要，播不了的留给本机转码
        let tracks = await PlayerAPI.allTracks(for: ep.vid)
        guard !Task.isCancelled else { return }
        guard let best = Self.pick(tracks) else {
            setStatus(i, .failed("无可用清晰度")); return
        }
        guard isCurrent(i, series.id) else { return }
        items[i].track = best

        // 下载 + 解密（必要时本机转码）
        do {
            let url = try await MediaStore.prepareForPlayback(
                vid: ep.vid, track: best, pool: tracks) { p in
                Task { @MainActor in self.setProgress(i, seriesID: series.id, p) }
            }
            guard items.indices.contains(i) else { return }
            if Task.isCancelled || paused {
                // 切走了这个 Tab、任务被取消：文件其实已经下好解密完（回来是秒开），
                // 但这里必须落一个确定状态 —— 原来直接 return，条目就永远停在
                // 「解密中 100%」，而 prepareOne 又不会再碰 .downloading。
                setStatus(i, .pending)
                return
            }
            setStatus(i, .ready(url))
        } catch {
            guard items.indices.contains(i) else { return }
            // 取消不是错误：留成 .pending 等下次重来；真失败才报错。
            setStatus(i, (Task.isCancelled || paused) ? .pending : .failed("加载失败"))
        }
    }

    /// 选档：优先能直接播的 1080p；一条都直接播不了就挑最高档走本机转码。
    /// 传入的 tracks 已按清晰度从高到低排好，一条都不过滤。
    static func pick(_ tracks: [VideoTrack]) -> VideoTrack? {
        let ok = PlayerAPI.playable(tracks)
        let list = ok.isEmpty ? tracks : ok
        if let p = list.first(where: { $0.definition.contains("1080") }) { return p }
        return list.first
    }

    /// 这个下标现在还是不是同一部剧。load() 会把 items 整体换掉（去重 + 洗牌），
    /// 换掉之后老的解析回调若照下标写，就写到别的剧身上了。
    private func isCurrent(_ i: Int, _ seriesID: String) -> Bool {
        items.indices.contains(i) && items[i].series.id == seriesID
    }

    /// 进度回调能不能盖住这个状态（抽成静态函数，便于单测把规则锁死）。
    ///
    /// `.ready` / `.failed` 是终态，不能被后到的进度冲掉；`.pending` 也不行 ——
    /// 它表示「已被 pause() 收回、等着重来」，此刻还在飞的下载回调一旦写进
    /// `.downloading`，条目就会永远停在「解密中 100%」（prepareOne 又不会再碰它）。
    nonisolated static func acceptsProgress(_ s: FeedItem.Status) -> Bool {
        switch s {
        case .resolving, .downloading: return true
        case .pending, .ready, .failed: return false
        }
    }
    /// 进度回写：只有还是同一部剧、且当前确实在「解析中 / 下载中」才接受。
    private func setProgress(_ i: Int, seriesID: String, _ p: Double) {
        guard isCurrent(i, seriesID), Self.acceptsProgress(items[i].status) else { return }
        items[i].status = .downloading(min(max(p, 0), 1))
    }

    private func setStatus(_ i: Int, _ s: FeedItem.Status) {
        guard items.indices.contains(i) else { return }
        items[i].status = s
    }
}

// MARK: - 单页

private struct FeedCard: View {
    let item: FeedItem
    let isActive: Bool
    var onPlay: () -> Void      // 点画面：接着上次进度播放
    var onDetail: () -> Void    // 右侧「选集」：进详情页

    @State private var player: AVPlayer?
    @State private var muted = false
    @State private var liked = false
    @State private var showQuality = false
    @State private var ended: NSObjectProtocol?
    /// 画面填充模式（0 自动 / 1 铺满 / 2 适应），与播放器页共用
    @AppStorage("video_fit_mode") private var fitMode = 0

    var body: some View {
        ZStack {
            Color.black

            // 封面（视频没准备好时铺底）
            //
            // 必须用 Color.clear + overlay 把这一层的尺寸钉死在容器上。
            // 直接把 .fill 的图片塞进 ZStack，图片会按自身宽高比把 ZStack 撑大
            // （竖屏 3:4 的封面在 9:19.5 的屏幕上会撑宽 60%），
            // 于是播放层和底部文字全部跟着偏移、被推出屏幕 —— 这就是「出画」。
            // 注意 .clipped() 只裁绘制、不裁布局，光加它一点用都没有。
            Color.clear
                .overlay {
                    AsyncImage(url: URL(string: item.series.cover)) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else { Color.black }
                    }
                }
                .clipped()
                .overlay(Color.black.opacity(player == nil ? 0.1 : 0.55))

            if let p = player {
                Color.clear.overlay {
                    PlayerLayerView(player: p,
                                    fill: VideoFit.forced(fitMode),
                                    videoSize: CGSize(width: item.track?.width ?? 0,
                                                      height: item.track?.height ?? 0))
                }
            } else {
                loadingOverlay
            }

            // 整屏可点：点画面任意处接着上次进度播放
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onPlay() }

            // 左上角：种类标签（新剧 / 爆剧）+ 清晰度角标
            VStack {
                HStack(spacing: 6) {
                    kindBadge
                    if let t = item.track, player != nil {
                        Text((t.note.isEmpty ? "" : "⚠️ ") + "\(t.definition) · \(t.codec)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 14).padding(.top, 8)
            .allowsHitTesting(false)

            // 右侧操作栏
            VStack(spacing: 20) {
                Button { liked.toggle() } label: {
                    sideIcon(liked ? "heart.fill" : "heart", "喜欢",
                             color: liked ? .pink : .white)
                }
                Button { muted.toggle(); player?.isMuted = muted } label: {
                    sideIcon(muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             muted ? "已静音" : "有声")
                }
                Button(action: onDetail) {
                    sideIcon("list.bullet", "选集")
                }
                // 自动按片源比例决定；不合胃口时能当场切：铺满(裁边) / 适应(留黑边)
                Button { fitMode = VideoFit.next(fitMode) } label: {
                    sideIcon(VideoFit.icon(fitMode), VideoFit.label(fitMode))
                }
            }
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 底部信息
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let ep = item.episode {
                        Text("第 \(ep.index) 集")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.pink.opacity(0.85)).clipShape(Capsule())
                    }
                    Text("共 \(item.series.episodeCount) 集")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                }
                Text(item.series.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2)
                if !item.series.intro.isEmpty {
                    Text(item.series.intro)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Text("上滑看下一部 · 点画面继续观看")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
            // 必须显式贴底：ZStack 默认垂直居中，只设 maxWidth 会让这块文字
            // 飘在屏幕中间挡住画面（简介尤其明显）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 260).frame(maxHeight: .infinity, alignment: .bottom)
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: isActive) { active in
            if active { start() } else { player?.pause() }
        }
        // 片源就绪后自动起播。
        // 原来挂在 .onChange(of: item.status) 上：下载过程中每报一次进度 status
        // 就变一次、每次都要比一遍，而且就绪那一刻如果视图正在重建，这个变化
        // 会被漏掉 —— 表现就是「进度条满了不动，上滑下滑才开播」。
        // 改成按「就绪地址」触发：地址一变这里必定跑一次，不依赖差分。
        .task(id: readyURL) {
            guard readyURL != nil else { return }
            if isActive { start() }
        }
        .onAppear { if isActive { start() } }
        .onDisappear { teardown() }
    }

    /// 左上角的种类标签：新剧 / 爆剧。每张卡片都挂，比例一眼能看出来。
    private var kindBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 9, weight: .bold))
            Text(item.kind.rawValue)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(item.kind.tint.opacity(0.92))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func sideIcon(_ name: String, _ label: String, color: Color = .white) -> some View {
        VStack(spacing: 4) {
            Image(systemName: name).font(.system(size: 24)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.white)
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            switch item.status {
            case .downloading(let p):
                ProgressView(value: p).tint(.pink).frame(width: 180)
                Text("解密中 \(Int(p * 100))%").font(.footnote).foregroundStyle(.white.opacity(0.85))
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(m).font(.footnote).foregroundStyle(.white.opacity(0.85))
                Text("上滑看下一部").font(.caption2).foregroundStyle(.white.opacity(0.5))
            default:
                ProgressView().tint(.pink)
                Text("正在准备片源…").font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(20)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 片源就绪后的本地地址（没就绪时为 nil），用作自动起播的触发键
    private var readyURL: URL? {
        if case .ready(let u) = item.status { return u }
        return nil
    }

    private func start() {
        syncPlayer()
        player?.play()
    }

    private func syncPlayer() {
        guard case .ready(let url) = item.status else { return }
        if let cur = player?.currentItem?.asset as? AVURLAsset, cur.url == url { return }
        teardown()
        let p = AVPlayer(url: url)
        // 同播放页：限住前向缓冲，推荐页常驻的播放器不要越读越多
        p.currentItem?.preferredForwardBufferDuration = 6
        p.automaticallyWaitsToMinimizeStalling = false
        p.isMuted = muted
        player = p
        // 申请全局播放权：会把上一个还在播的画面停掉
        PlaybackCenter.shared.claim("feed:\(item.id)") { [weak p] in p?.pause() }
        // 一集播完回到开头重播，画面一直在动
        ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
        if isActive { p.play() }
    }

    private func teardown() {
        player?.pause()
        PlaybackCenter.shared.release("feed:\(item.id)")
        if let e = ended { NotificationCenter.default.removeObserver(e); ended = nil }
        player = nil
    }
}

// MARK: - 推荐流

/// 点画面要起播的目标（播放器需要全集列表 + 起始集）
private struct PlayTarget: Identifiable {
    let series: Series
    let episodes: [Episode]
    let start: Episode
    var id: String { series.id }
}

struct FeedView: View {
    /// 本 Tab 是否在前台。切走时停掉后台预取，别在背后抢带宽
    var active: Bool = true

    @StateObject private var model = FeedModel()
    @State private var scrolledID: Int?
    @State private var open: FeedItem?
    @State private var play: PlayTarget?

    private var index: Int { scrolledID ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView().tint(.pink)
                    Text("正在准备推荐…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            } else if let e = model.error {
                CompatUnavailable("加载失败", systemImage: "wifi.slash", desc: e)
            } else {
                pager
            }
        }
        .task { if model.items.isEmpty { await model.load() } }
        // 内存告警：立刻把非必要的东西放掉，别等系统来杀。
        // 用 canImport(UIKit) 包住只是为了保住「macOS 上也能跑类型检查」这道本地闸门
        // （iOS 构建时这段照常生效）。
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.relaxMemory()
        }
        #endif
        .onChange(of: active) { a in
            if a { model.resume() } else { model.pause() }
        }
        // 右侧「选集」才进详情页
        .sheet(item: $open) { it in
            NavigationStack { DetailView(series: it.series) }
        }
        // 点画面直接接着进度播，不再绕一层详情页
        // 关掉播放页后这一页自己会续上：onDisappear 把播放器拆了，
        // 回来 onAppear + isActive 会重新 start()。
        // 原来这里还在 onDismiss 里按观看记录重解析 —— 推荐页现在固定在
        // 第 1 集、不跟随记录，那个分支已经没有意义了。
        .fullScreenCover(item: $play) { t in
            PlayerView(series: t.series, episodes: t.episodes, start: t.start)
        }
    }

    /// 点画面：接着上次进度起播。集列表在解析时就顺手存下来了，
    /// 万一是还没解析完就抢点，这里补一次请求。
    private func startPlay(_ i: Int) {
        guard model.items.indices.contains(i) else { return }
        let it = model.items[i]
        if !it.episodes.isEmpty {
            play = PlayTarget(series: it.series, episodes: it.episodes, start: resumeEpisode(it))
            return
        }
        Task {
            guard let (s, eps) = try? await Catalog.detail(it.series.id), !eps.isEmpty else { return }
            var filled = it
            filled.episodes = eps
            play = PlayTarget(series: s, episodes: eps, start: resumeEpisode(filled))
        }
    }

    /// 推荐页进来的固定从第 1 集起（和上面卡片里播的是同一集，不会对不上）。
    /// 续看走「历史」页。
    private func resumeEpisode(_ it: FeedItem) -> Episode {
        let want = it.episode?.index ?? 1
        return it.episodes.first { $0.index == want } ?? it.episodes[0]
    }

    /// 原生竖向分页：每页正好一屏。
    /// containerRelativeFrame 直接取滚动容器尺寸（不再手算 GeometryReader），
    /// 页面高度与可见区域严格一致，切页不会错位、比例不会怪。
    private var pager: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, it in
                    // 弹出播放页 / 详情页时底下的卡片必须停：
                    // fullScreenCover 和 sheet 都不会让下面这层 onDisappear，
                    // 它照播不误 —— 于是和播放页两个声音叠在一起。
                    FeedCard(item: it,
                             isActive: i == index && active && play == nil && open == nil,
                             onPlay: { startPlay(i) },
                             onDetail: { open = it })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .onChange(of: scrolledID) { v in if let v { model.prepare(v) } }
        .onAppear { model.prepare(0) }
        .overlay(alignment: .bottom) {
            if !model.poolNote.isEmpty {
                Text(model.poolNote)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 2)
            }
        }
    }
}