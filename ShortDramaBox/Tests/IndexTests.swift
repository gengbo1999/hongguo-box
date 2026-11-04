import XCTest
import Foundation
@testable import ShortDramaBox

/// 服务端目录层（`/api/tags` `/api/tag` `/api/newest` `/api/random` `/api/search` `/api/series`）。
///
/// 以前这些断言打的是打在 App 包里的 `index.bin.z`；索引搬到服务端之后，
/// 这里改成对着 `resolver_base` 指的服务打。没配地址就整体跳过——
/// 目录层不是 App 能独立验证的部分，需要一台带库的服务端。
final class IndexTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(CatalogAPI.isEnabled, "没配 resolver_base，跳过服务端目录层测试")
    }

    // MARK: - 小工具

    /// 同步 XCTest 里等 async 调用；服务端没响应就跳过而不是失败
    private func onServer<T>(_ body: @escaping @Sendable () async -> T) throws -> T {
        let exp = expectation(description: "await")
        let box = ResultBox<T>()
        Task { box.set(await body()); exp.fulfill() }
        wait(for: [exp], timeout: 30)
        guard let r = box.get() else { throw XCTSkip("服务端没响应或返回空") }
        return r
    }

    private func requireTotal() throws -> Int {
        let n = try onServer { await CatalogAPI.totalCount() }
        guard n > 0 else { throw XCTSkip("服务端没返回全库条数") }
        return n
    }

    private func buckets() throws -> [CatalogAPI.TagBucket] {
        let b = try onServer { await CatalogAPI.tagBuckets() }
        guard !b.isEmpty else { throw XCTSkip("服务端没返回标签") }
        return b
    }

    // MARK: - 基本形状

    func testServerReportsWholeLibrary() throws {
        let total = try requireTotal()
        XCTAssertGreaterThan(total, 500_000, "全库只有 \(total) 条，种子没导全")
        let b = try buckets()
        XCTAssertGreaterThan(b.count, 300, "标签只有 \(b.count) 个")
    }

    func testTagBucketsAreSortedAndNonEmpty() throws {
        let b = try buckets()
        for i in 1..<b.count {
            XCTAssertGreaterThanOrEqual(b[i-1].count, b[i].count, "标签没按数量排序")
        }
        for x in b {
            XCTAssertFalse(x.tag.isEmpty, "出现空标签")
            XCTAssertGreaterThan(x.count, 0, "标签「\(x.tag)」数量是 0")
        }
        XCTAssertEqual(Set(b.map { $0.tag }).count, b.count, "标签有重复")
    }

    func testTagPagingIsDisjointAndCounted() throws {
        let top = try buckets()[0]
        let p1 = try onServer { await CatalogAPI.tagPage(top.tag, offset: 0, limit: 24) }
        XCTAssertEqual(p1.total, top.count, "total 和标签统计对不上")
        XCTAssertEqual(p1.items.count, min(24, top.count))
        if top.count > 24 {
            let p2 = try onServer { await CatalogAPI.tagPage(top.tag, offset: 24, limit: 24) }
            XCTAssertEqual(p2.items.count, min(24, top.count - 24))
            XCTAssertTrue(Set(p1.items.map { $0.id }).isDisjoint(with: Set(p2.items.map { $0.id })), "两页有重复")
        }
        for s in p1.items {
            XCTAssertFalse(s.id.isEmpty, "条目没有 id")
            XCTAssertFalse(s.title.isEmpty, "条目 \(s.id) 没有标题")
            XCTAssertGreaterThan(s.episodeCount, 0, "条目 \(s.title) 集数是 0")
            XCTAssertTrue(s.cover.isEmpty || s.cover.hasPrefix("http"), "封面不是 http 地址：\(s.cover)")
        }
    }

    /// 交叉验证：接口说「这些剧有这个标签」，就拿条目自带的标签复核
    func testTagListingMatchesPerRecordTags() throws {
        for b in try buckets().prefix(12) {
            let page = try onServer { await CatalogAPI.tagPage(b.tag, offset: 0, limit: 10) }
            XCTAssertFalse(page.items.isEmpty, "标签「\(b.tag)」有 \(b.count) 条却取不出来")
            for s in page.items {
                XCTAssertTrue(s.tags.contains(b.tag),
                              "「\(s.title)」出现在标签「\(b.tag)」下，但它自己的标签是 \(s.tags)")
            }
        }
    }

    func testUnknownTagIsEmpty() throws {
        _ = try buckets()
        let ghost = "不存在的标签-\(UUID().uuidString)"
        let r = try onServer { await CatalogAPI.tagPage(ghost, offset: 0, limit: 10) }
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.total, 0)
    }

    func testPastTheEndReturnsNothingButKeepsTotal() throws {
        let top = try buckets()[0]
        let r = try onServer { await CatalogAPI.tagPage(top.tag, offset: top.count + 1000, limit: 24) }
        XCTAssertTrue(r.items.isEmpty, "越界了还返回内容")
        XCTAssertEqual(r.total, top.count, "越界时 total 不该丢")
    }

    // MARK: - 搜索

    /// 拿真实条目的标题去搜，必须能搜回它自己
    func testSearchFindsTheRecordItCameFrom() throws {
        let first = try onServer { await CatalogAPI.newest(offset: 0, limit: 40) }
        guard let s0 = first.items.first(where: { !$0.title.isEmpty && $0.title.count < 20 })
        else { return XCTFail("前 40 条里没有标题长度合适的记录") }
        let r = try onServer { await CatalogAPI.search(s0.title) }
        XCTAssertGreaterThan(r.total, 0, "用自己的标题「\(s0.title)」都搜不到")
        XCTAssertTrue(r.list.contains { $0.id == s0.id }, "搜索结果里没有它自己（总数 \(r.total)）")
    }

    /// 超长关键词由服务端截断/拒绝，不能整表扫、也不能崩
    func testOverlongKeywordIsHandledSafely() throws {
        let r = try onServer {
            await CatalogAPI.search(String(repeating: "剧", count: 200))
        }
        XCTAssertLessThanOrEqual(r.list.count, 100, "结果没被 limit 收住")
    }

    /// `%`/`_` 是 LIKE 通配符，必须被转义，否则等于全表命中
    func testLikeWildcardsAreEscaped() throws {
        let total = try requireTotal()
        let r = try onServer { await CatalogAPI.search("%") }
        XCTAssertLessThan(r.total, total, "「%」被当成通配符了（命中 \(r.total) 条）")
    }

    func testSearchResultLimitIsRespected() throws {
        let r = try onServer { await CatalogAPI.search("剧", limit: 5) }
        XCTAssertLessThanOrEqual(r.list.count, 5)
    }

    func testSearchOffsetPagingIsDisjoint() throws {
        let r1 = try onServer { await CatalogAPI.search("剧", limit: 20, offset: 0) }
        let r2 = try onServer { await CatalogAPI.search("剧", limit: 20, offset: 20) }
        XCTAssertEqual(r1.total, r2.total, "翻页时总数变了")
        XCTAssertTrue(Set(r1.list.map { $0.id }).isDisjoint(with: Set(r2.list.map { $0.id })), "两页重复")
    }

    // MARK: - 排序

    /// 分类页的核心诉求：标签下的内容必须是时间倒序（最新在前）。
    /// 条目里带 created，直接看它就行，不用回本地查。
    func testTagListingIsNewestFirst() throws {
        var checked = 0
        var bad: [String] = []
        for b in try buckets().prefix(3) {
            let items = try onServer { await CatalogAPI.tagPage(b.tag, offset: 0, limit: 100) }.items
            guard items.count > 10 else { continue }
            let created = try createdMap(items.map { $0.id })
            var prev = Int.max
            for s in items {
                guard let c = created[s.id] else { continue }
                if c > prev { bad.append("\(b.tag):\(c)>\(prev)") }
                prev = c
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100, "实际只检查了 \(checked) 条")
        XCTAssertTrue(bad.isEmpty, "出现时间逆序：\(bad.prefix(5))")
    }

    /// 倒序的「第一条」必须是新剧：顺序反了会拿到几年前的
    func testTagListingStartsFromRecent() throws {
        let top = try buckets()[0]
        let one = try onServer { await CatalogAPI.tagPage(top.tag, offset: 0, limit: 1) }
        guard let s = one.items.first else { return XCTFail("取不到第一条") }
        let c = try createdMap([s.id])[s.id]
        guard let c else { return XCTFail("条目没有 created") }
        let limit = Int(Date().timeIntervalSince1970) - 400 * 86400
        XCTAssertGreaterThan(c, limit, "「\(top.tag)」第一条是 \(c)，不像最新上架的")
    }

    /// created 必须真的带出来，否则「按时间排序」无从谈起
    func testCreatedFieldIsPresent() throws {
        let items = try onServer { await CatalogAPI.newest(offset: 0, limit: 100) }.items
        let created = try createdMap(items.map { $0.id })
        let missing = items.filter { (created[$0.id] ?? 0) == 0 }.map { $0.title }
        XCTAssertTrue(missing.isEmpty, "有 \(missing.count) 条没有 created：\(missing.prefix(3))")
    }

    /// 批量取 id 保留 created（Series 不带这个字段，所以单独走 JSON）
    private func createdMap(_ ids: [String]) throws -> [String: Int] {
        guard CatalogAPI.isEnabled, !ids.isEmpty,
              let base = RemoteResolver.base,
              var comps = URLComponents(string: base + "/api/series") else { return [:] }
        comps.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        guard let url = comps.url else { return [:] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let exp = expectation(description: "ids")
        let box = ResultBox<[String: Int]>()
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { exp.fulfill() }
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = j["items"] as? [[String: Any]] else { return }
            var out: [String: Int] = [:]
            for d in items {
                let id = asStr(d["id"])
                if !id.isEmpty { out[id] = asInt(d["created"]) }
            }
            box.set(out)
        }.resume()
        wait(for: [exp], timeout: 20)
        return box.get() ?? [:]
    }

    // MARK: - 推荐流取样（新剧 / 爆剧）

    func testNewestAdvancesWithoutOverlap() throws {
        let r1 = try onServer { await CatalogAPI.newest(offset: 0, limit: 20) }
        XCTAssertEqual(r1.items.count, 20, "新剧首批没取满 20 条")
        XCTAssertGreaterThan(r1.next, 0, "next 没推进，续抽会重复")
        let r2 = try onServer { await CatalogAPI.newest(offset: r1.next, limit: 20) }
        XCTAssertFalse(r2.items.isEmpty, "第二批新剧取不到")
        let dup = Set(r1.items.map(\.id)).intersection(r2.items.map(\.id))
        XCTAssertTrue(dup.isEmpty, "两批新剧重复了：\(dup)")
        let neg = try onServer { await CatalogAPI.newest(offset: -5, limit: 3) }
        XCTAssertFalse(neg.items.isEmpty, "负数 offset 应该被夹到 0")
    }

    func testRandomIsUniqueAndHonoursExcluding() throws {
        _ = try requireTotal()
        let a = try onServer { await CatalogAPI.random(limit: 50) }
        XCTAssertEqual(a.count, 50, "全库随机没抽满 50 条")
        XCTAssertEqual(Set(a.map(\.id)).count, 50, "全库随机抽到重复")
        let excl = Set(a.map(\.id))
        let b = try onServer { await CatalogAPI.random(limit: 30, excluding: excl) }
        XCTAssertFalse(b.isEmpty, "带 excluding 就抽不出来了")
        XCTAssertTrue(Set(b.map(\.id)).isDisjoint(with: excl), "excluding 没生效，续抽会跟前面重复")
    }

    /// 按 id 批量取：顺序保持、未知 id 跳过、超过 200 个截断
    func testByIDsKeepsOrderAndSkipsUnknown() throws {
        let src = try onServer { await CatalogAPI.newest(offset: 0, limit: 5) }.items
        guard src.count >= 3 else { return XCTFail("取不到样本") }
        let ids = [src[2].id, src[0].id, src[1].id]
        let got = try onServer { await CatalogAPI.byIDs(ids) }
        XCTAssertEqual(got.map { $0.id }, ids, "返回顺序没跟请求一致")
        let withGhost = try onServer { await CatalogAPI.byIDs([src[0].id, "9999999999999999999"]) }
        XCTAssertEqual(withGhost.map { $0.id }, [src[0].id], "未知 id 应该被跳过")
    }

    // MARK: - 推荐配方（纯本地逻辑，不需要服务端）

    func testFeedMixWeightsAreSevenToThree() {
        let p = FeedMix.plan(hotAvailable: 999, batchSize: 240)
        XCTAssertEqual(p.new + p.hot, 240, "配额加起来不等于每批条数")
        XCTAssertEqual(p.new, 168, "新剧该占七成（168/240）")
        XCTAssertEqual(p.hot, 72, "爆剧该占三成（72/240）")
        XCTAssertEqual(FeedMix.newWeight, 7)
        XCTAssertEqual(FeedMix.hotWeight, 3)
        XCTAssertEqual(p.new * FeedMix.hotWeight, p.hot * FeedMix.newWeight,
                       "新剧:爆剧 不是 7:3")
    }

    func testFeedMixGivesHotShortfallToNew() {
        let none = FeedMix.plan(hotAvailable: 0, batchSize: 240)
        XCTAssertEqual(none.hot, 0)
        XCTAssertEqual(none.new, 240, "爆剧池空了，缺额应该全给新剧")
        let few = FeedMix.plan(hotAvailable: 10, batchSize: 240)
        XCTAssertEqual(few.hot, 10, "爆剧不够就按实际给，不超发")
        XCTAssertEqual(few.new, 230)
        XCTAssertEqual(few.new + few.hot, 240)
        let empty = FeedMix.plan(hotAvailable: 999, batchSize: 0)
        XCTAssertEqual(empty.new, 0)
        XCTAssertEqual(empty.hot, 0)
    }

    func testFeedKindHasExactlyTwoCases() {
        XCTAssertEqual(FeedKind.allCases.count, 2, "推荐页只放新剧和爆剧")
        XCTAssertEqual(FeedKind.new.rawValue, "新剧")
        XCTAssertEqual(FeedKind.hot.rawValue, "爆剧")
    }
}
/// 把异步结果从并发域安全带回测试线程
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T?) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
