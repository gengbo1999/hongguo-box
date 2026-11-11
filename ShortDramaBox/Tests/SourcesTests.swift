import XCTest
@testable import ShortDramaBox

/// 作品/来源模型（work + work_source）里，服务端会给同一部剧带上 `sources`。
/// 客户端靠它生成「换源」菜单、按成员 sid 请求对应来源的剧集，
/// 解析错了会菜单为空或者换源后拿不到片源。
final class SourcesTests: XCTestCase {
    func testSeriesDecodesSourcesWithStableIdentity() throws {
        let json = """
        {"id":"7704327885581995070","title":"罐中骗局","cover":"","intro":"",
         "episodeCount":9,"accessibleCount":9,"rightText":"","tags":[],"source":"hg",
         "sources":[
           {"source":"hg","sid":"7704327885581995070","eps":9,"title":"罐中骗局"},
           {"source":"dy","sid":"dy:7704331051820124200","eps":9,"title":"罐中骗局"}
         ]}
        """
        let s = try JSONDecoder().decode(Series.self, from: Data(json.utf8))
        XCTAssertEqual(s.id, "7704327885581995070")
        XCTAssertEqual(s.sources?.count, 2)
        XCTAssertEqual(s.sources?.map(\.source), ["hg", "dy"])
        XCTAssertEqual(s.sources?.map(\.id), ["7704327885581995070", "dy:7704331051820124200"])
        XCTAssertEqual(Set(s.sources!.map(\.id)).count, 2, "成员 sid 必须唯一")
    }

    func testSingleSourceOmitsSourcesAndKeepsFallback() throws {
        let json = """
        {"id":"222","title":"单来源","cover":"","intro":"","episodeCount":3,
         "accessibleCount":3,"rightText":"","tags":[],"source":"hg"}
        """
        let s = try JSONDecoder().decode(Series.self, from: Data(json.utf8))
        XCTAssertNil(s.sources, "单来源不需要换源菜单")
        XCTAssertTrue(s.sources?.isEmpty ?? true)
    }

    func testSourceIdentityDoesNotCollideWithWorkId() {
        let a = SeriesSource(source: "hg", sid: "111", eps: 9, title: "剧")
        let b = SeriesSource(source: "dy", sid: "dy:111", eps: 9, title: "剧")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(Set([a, b]).count, 2)
    }
}