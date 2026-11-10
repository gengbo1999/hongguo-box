import XCTest
@testable import ShortDramaBox

/// 列表「同剧多源」合并规则。
/// 合并错了要么丢剧、要么把不同季拼到一起，用户会直接看到重复卡片或错集，
/// 所以这些边界用测试钉住。
final class DedupeTests: XCTestCase {

    private func series(_ id: String, _ title: String,
                        episodes: Int, source: String) -> Series {
        var s = Series(id: id)
        s.title = title
        s.episodeCount = episodes
        s.source = source
        return s
    }

    /// 同一部剧在红果/抖音各一条时合成一条，抖音作主条目，红果留在 alternates。
    func testSameTitleMergesAndPrefersDouyin() {
        let hg = series("7704327885581995070", "罐中骗局", episodes: 9, source: "hg")
        let dy = series("dy:7704331051820124200", "罐中骗局", episodes: 9, source: "dy")

        let merged = Series.dedupe([hg, dy])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, dy.id)
        XCTAssertEqual(merged[0].source, "dy")
        XCTAssertEqual(merged[0].alternates?.map(\.id), [hg.id])
        // 备用源保持扁平，不能再套一层 alternates
        XCTAssertNil(merged[0].alternates?.first?.alternates)
    }

    /// 集数不同说明不是同一部（同名不同长度），不能合并。
    func testDifferentEpisodeCountStaysSeparate() {
        let a = series("a", "同名剧", episodes: 9, source: "hg")
        let b = series("b", "同名剧", episodes: 24, source: "dy")

        let merged = Series.dedupe([a, b])

        XCTAssertEqual(merged.count, 2)
        XCTAssertNil(merged[0].alternates)
        XCTAssertNil(merged[1].alternates)
    }

    /// 标题里的空格、中英文标点不应影响判重。
    func testTitleNormalizationIgnoresSpacesAndPunctuation() {
        let a = series("a", "我有六个黄毛爹 第二季", episodes: 12, source: "hg")
        let b = series("b", "我有六个黄毛爹·第二季", episodes: 12, source: "dy")

        XCTAssertEqual(a.dedupeKey, b.dedupeKey)
        XCTAssertEqual(Series.dedupe([a, b]).count, 1)
    }

    /// 已是主条目时再合并同源/异源条目不能把自己塞进 alternates，也不能重复添加。
    func testMergeAlternateIsIdempotentAndBidirectional() {
        var dy = series("dy:1", "测试剧", episodes: 9, source: "dy")
        let hg = series("1", "测试剧", episodes: 9, source: "hg")

        dy.mergeAlternate(hg)
        dy.mergeAlternate(hg)

        XCTAssertEqual(dy.id, "dy:1")
        XCTAssertEqual(dy.alternates?.map(\.id), ["1"])

        // 从红果侧合并抖音：红果让位成备用源，抖音成为主条目
        var hg2 = series("1", "测试剧", episodes: 9, source: "hg")
        hg2.mergeAlternate(dy)
        XCTAssertEqual(hg2.id, "dy:1")
        XCTAssertEqual(hg2.alternates?.map(\.id), ["1"])
    }

    /// 空标题按 id 判重，避免所有无标题条目被并成一条。
    func testEmptyTitleFallsBackToId() {
        let a = series("a", "", episodes: 0, source: "hg")
        let b = series("b", "", episodes: 0, source: "dy")

        XCTAssertEqual(a.dedupeKey, "id:a")
        XCTAssertEqual(Series.dedupe([a, b]).count, 2)
    }
}