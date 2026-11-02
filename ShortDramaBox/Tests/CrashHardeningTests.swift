import XCTest
import Foundation
@testable import ShortDramaBox

/// 「看着看着闪退」的回归测试。
///
/// 这一批全是**恶意/残缺输入**下的崩溃回归：
/// 1080p 档位每条都带 `spade_a` + `cenc-aes-ctr`，也就是说**每一集都要走解密**；
/// 而以前只有公网明文的 360p 会跳过解密（明文档 spade 为空 → 直接短路）。
/// 于是「解密器 + MP4 盒子解析」这条路径从「偶尔走到」变成「每集必走」，
/// 里面原本够不着的越界/强解包就全被踩出来了 —— 现象正是「看着看着闪退」。
///
/// 这里按「输入不可信」来写：不要求它一定成功，只要求它**永远不崩**，
/// 而且失败要能被上层识别（成功样本数为 0 / skipped 记账）。
final class CrashHardeningTests: XCTestCase {

    // MARK: - 测试用的小工具

    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count + 8
        return be32(n) + Array(type.utf8) + payload
    }

    /// 造一个「stco 指向 stcoOffset、senc 里带 base_iv」的最小 MP4。
    private func makeMP4(stcoOffset: Int, sampleSize: Int, sampleCount: Int) -> [UInt8] {
        let stsz = box("stsz", be32(0) + be32(sampleSize) + be32(sampleCount)
                       + (0..<sampleCount).flatMap { _ in be32(sampleSize) })
        let stsc = box("stsc", be32(0) + be32(1) + be32(1) + be32(sampleCount) + be32(1))
        let stco = box("stco", be32(0) + be32(1) + be32(stcoOffset))
        let stbl = box("stbl", stsz + stsc + stco)
        let minf = box("minf", stbl)
        let hdlr = box("hdlr", be32(0) + be32(0) + Array("vide".utf8)
                       + [UInt8](repeating: 0, count: 12) + [0])
        let mdia = box("mdia", hdlr + minf)
        let senc = box("senc", be32(0) + be32(1) + [UInt8](repeating: 0x11, count: 16))
        return box("ftyp", Array("isom".utf8) + be32(512))
            + box("moov", box("trak", mdia + senc))
            + box("mdat", [UInt8](repeating: 0xAB, count: 4096))
    }

    private func write(_ bytes: [UInt8], _ name: String) -> String {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? Data(bytes).write(to: u)
        return u.path
    }

    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(name).path
    }

    private let goodKey = String(repeating: "ab", count: 16)

    // MARK: - 1. hex 解析：原来 UInt8(_, radix:16)! 强解包 + 奇数长度越界

    func testHexBytesRejectsMalformed() {
        XCTAssertNil(hexBytes("zz"), "非 hex 必须返回 nil，不能强解包")
        XCTAssertNil(hexBytes("abc"), "奇数长度必须返回 nil，不能索引越界")
        XCTAssertNil(hexBytes(""))
        XCTAssertNil(hexBytes("0g"))
        XCTAssertEqual(hexBytes("00ff10"), [0, 255, 16])
        XCTAssertEqual(hexBytes("A1b2"), [161, 178], "大小写混排要能解")
    }

    func testDecryptAVWithMalformedKeyDoesNotCrash() {
        let file = write(makeMP4(stcoOffset: 0, sampleSize: 256, sampleCount: 4), "key.mp4")
        XCTAssertTrue(decryptAV(file, keyHex: "zzzz", outPath: tempPath("key.out")).isEmpty)
        XCTAssertTrue(decryptAV(file, keyHex: "", outPath: tempPath("key2.out")).isEmpty)
        XCTAssertTrue(decryptAV(file, keyHex: "abc", outPath: tempPath("key3.out")).isEmpty)
    }

    // MARK: - 2. spade 解包：原来 iVar9 > L 时 spade[L - iVar9 - 2] 负下标直接崩

    func testUnwrapV1HostileInputs() {
        XCTAssertNil(unwrapV1([0xff, 0xff, 0xff]), "首字节巨大时修复前是负下标崩溃")
        XCTAssertNil(unwrapV1([0xff, 0xfe, 0xfd, 0x30]))
        XCTAssertNil(unwrapV1([]))
        XCTAssertNil(unwrapV1([0x00]), "长度不足时不能越界")
        XCTAssertNil(unwrapV1([0x01, 0x41]), "声明长度大于实际长度时必须返回 nil")
    }

    func testUnwrapV1FuzzNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let n = Int.random(in: 0...160, using: &rng)
            var bytes = [UInt8]()
            bytes.reserveCapacity(n)
            for _ in 0..<n { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            _ = unwrapV1(bytes)   // 只要不崩就算过
        }
    }

    func testSpadeToKeyRejectsGarbage() {
        XCTAssertNil(spadeToKey("!!!"), "非法 base64 必须返回 nil")
        XCTAssertNil(spadeToKey(""))
        _ = spadeToKey("YWJj")   // 合法 base64 但不合法明文：允许 nil，不允许崩
    }

    // MARK: - 3. 样本表：样本偏移/大小来自文件，越界就是越界

    func testDecryptAVSkipsOutOfRangeSamples() {
        // stco 指向 9999999，远在文件末尾之外。修复前这里是
        // buf[o..<(o+sz)] 越界 → SIGABRT（正是「看着看着闪退」的一种）。
        let file = write(makeMP4(stcoOffset: 9_999_999, sampleSize: 512, sampleCount: 4), "oor.mp4")
        let stats = decryptAV(file, keyHex: goodKey, outPath: tempPath("oor.out"))
        XCTAssertEqual(stats["vide"]?.0 ?? 0, 0, "越界样本不能算作自证成功")
        XCTAssertGreaterThan(stats["skipped"]?.0 ?? 0, 0, "越界样本必须被记账，便于上层拒绝")
    }

    func testDecryptAVDoesNotOverRejectInRangeSamples() {
        let file = write(makeMP4(stcoOffset: 0, sampleSize: 256, sampleCount: 4), "in.mp4")
        let stats = decryptAV(file, keyHex: goodKey, outPath: tempPath("in.out"))
        XCTAssertEqual(stats["skipped"]?.0 ?? 0, 0, "偏移在范围内不能被误判为越界")
        XCTAssertEqual(stats["vide"]?.1, 4, "4 个样本都要走到处理")
    }

    func testParseTrackSamplesRejectsAbsurdCounts() {
        // 把 stsz 的 sample_count 改成约 20 亿。
        // 修复前 [Int](repeating: 0, count: cnt) 会直接分配爆炸。
        var bytes = makeMP4(stcoOffset: 0, sampleSize: 256, sampleCount: 1)
        guard let at = findFourCC(bytes, "stsz") else { return XCTFail("构造失败：找不到 stsz") }
        let cntOff = at + 4 + 4 + 4
        for (i, b) in be32(1_999_999_999).enumerated() where cntOff + i < bytes.count {
            bytes[cntOff + i] = b
        }
        let sample = parseTrackSamples(bytes, handler: "vide")
        XCTAssertTrue(sample.0.isEmpty && sample.1.isEmpty, "天文数字样本数必须被上限挡住")
    }

    func testDecryptAVHandlesGarbageAndMissingFiles() {
        let junk = write(Array("this is not an mp4".utf8), "junk.mp4")
        XCTAssertTrue(decryptAV(junk, keyHex: goodKey, outPath: tempPath("j.out")).isEmpty)
        let empty = write([], "empty.mp4")
        XCTAssertTrue(decryptAV(empty, keyHex: goodKey, outPath: tempPath("e.out")).isEmpty)
        XCTAssertTrue(decryptAV("/tmp/definitely-missing-\(UUID().uuidString).mp4",
                                keyHex: goodKey, outPath: tempPath("m.out")).isEmpty)
    }

    // MARK: - 4. strip：去掉 CENC 盒子不能移动 mdat（否则 stco 全部失效）

    func testStripCENCFailsSafelyOnGarbage() {
        let junk = write(Array("not an mp4 at all".utf8), "strip.mp4")
        XCTAssertEqual(stripCENC(junk, outPath: tempPath("strip.out")), -1, "解析不了必须返回 -1")
        XCTAssertEqual(stripCENC("/tmp/missing-\(UUID().uuidString).mp4",
                                 outPath: tempPath("strip2.out")), -1)
    }

    func testStripCENCPreservesMdatOffset() {
        let src = write(makeMP4(stcoOffset: 0, sampleSize: 256, sampleCount: 2), "off.mp4")
        let out = tempPath("off.strip.mp4")
        let delta = stripCENC(src, outPath: out)
        XCTAssertNotEqual(delta, -1, "含 moov 的正常文件应当能 strip")
        guard let a = try? Data(contentsOf: URL(fileURLWithPath: src)),
              let b = try? Data(contentsOf: URL(fileURLWithPath: out)) else {
            return XCTFail("输出文件没写出来")
        }
        let ab = [UInt8](a), bb = [UInt8](b)
        let ma = boxes(ab, 0, ab.count).first { $0.type == "mdat" }
        let mb = boxes(bb, 0, bb.count).first { $0.type == "mdat" }
        XCTAssertNotNil(ma); XCTAssertNotNil(mb)
        XCTAssertEqual(ma?.start, mb?.start, "mdat 绝对偏移必须不变（用 free 盒补齐就是为了这个）")
        XCTAssertTrue(boxes(bb, 0, bb.count).contains { $0.type == "moov" }, "输出必须还有 moov")
        XCTAssertFalse(boxes(bb, 0, bb.count).contains { dropBoxes.contains($0.type) },
                       "senc/saiz/saio 必须被摘掉")
    }

    // MARK: - 5. 目录层取样：推荐页不再本地解全量 58 万条，越界与极端参数都不能崩

    /// 服务端没配地址就没法测目录层，直接跳过（本地/CI 都不必为此起服务）
    private func requireCatalog() throws -> Int {
        guard CatalogAPI.isEnabled else {
            throw XCTSkip("没配 resolver_base，跳过服务端目录层测试")
        }
        let total = try awaitBlock { await CatalogAPI.totalCount() }
        guard total > 0 else { throw XCTSkip("服务端没返回全库条数") }
        return total
    }

    /// 让同步 XCTest 方法里能等一个 async 调用；返回值恒非空的用这个
    private func awaitBlock<T>(_ body: @escaping @Sendable () async -> T) throws -> T {
        let exp = expectation(description: "await")
        let box = ResultBox<T>()
        Task { box.set(await body()); exp.fulfill() }
        wait(for: [exp], timeout: 30)
        guard let r = box.get() else { throw XCTSkip("服务端没响应") }
        return r
    }

    /// 新剧按上架时间倒序续抽：越界 offset 只能返回空，不能回绕或崩
    func testNewestHandlesOutOfRangeOffsets() throws {
        let total = try requireCatalog()
        let far = try awaitBlock { await CatalogAPI.newest(offset: total + 10_000, limit: 5) }
        XCTAssertTrue(far.items.isEmpty, "越界 offset 不该有结果")
        XCTAssertGreaterThan(far.next, 0, "越界时 next 不该回绕到 0")
        let after = try awaitBlock { await CatalogAPI.newest(offset: far.next, limit: 5) }
        XCTAssertTrue(after.items.isEmpty, "越界之后还能抽到东西，说明下标回绕了")
        // 负数 offset 由客户端夹到 0，服务端也会夹
        let neg = try awaitBlock { await CatalogAPI.newest(offset: -5, limit: 3) }
        XCTAssertFalse(neg.items.isEmpty, "负数 offset 应被夹到 0 后照常取")
    }

    /// 极端 limit：0 或负数夹到 1，超大 limit 也不能抽到重复
    func testRandomSeriesHandlesExtremeLimits() throws {
        _ = try requireCatalog()
        // 超上限由服务端夹到 100，这里只要求不重复、不超过请求数
        let big = try awaitBlock { await CatalogAPI.random(limit: 3000) }
        XCTAssertEqual(Set(big.map(\.id)).count, big.count, "超大 limit 也不能抽到重复")
        XCTAssertLessThanOrEqual(big.count, 100, "服务端单次上限 100")
    }

    /// 连续多批新剧必须互不重叠（推荐页滑到底会反复续抽）
    func testNewestManyBatchesStayDisjoint() throws {
        _ = try requireCatalog()
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<5 {
            let r = try awaitBlock { await CatalogAPI.newest(offset: offset, limit: 50) }
            XCTAssertEqual(r.items.count, 50, "每批应取满 50 条")
            for s in r.items {
                XCTAssertTrue(seen.insert(s.id).inserted, "跨批重复：\(s.id)")
            }
            offset = r.next
        }
        XCTAssertEqual(seen.count, 250)
    }

    /// 全库随机带 excluding 连抽三轮，整体仍不重复（推荐页去重就靠它）
    func testRandomSeriesExcludingAcrossRoundsStaysUnique() throws {
        _ = try requireCatalog()
        var seen = Set<String>()
        for _ in 0..<3 {
            let got = try awaitBlock { await CatalogAPI.random(limit: 40, excluding: seen) }
            XCTAssertFalse(got.isEmpty, "excluding 之后抽不出来了")
            for s in got {
                XCTAssertTrue(seen.insert(s.id).inserted, "跨轮重复：\(s.id)")
            }
        }
        XCTAssertEqual(seen.count, 120)
    }

    // MARK: - 6. 转码档位与路径

    func testTranscoderRenditionAndOutputPath() {
        guard let r1080 = Rendition.matching(shortEdge: 1080) else {
            return XCTFail("1080 档位应当存在")
        }
        let src = URL(fileURLWithPath: "/tmp/x/7694961195043785752_1080p.mp4")
        let out = Transcoder.outputURL(for: src, rendition: r1080)
        XCTAssertNotEqual(out, src, "转码输出不能覆盖源文件")
        XCTAssertTrue(out.lastPathComponent.contains("1080"), "输出名要带清晰度标记")
        XCTAssertEqual(out.pathExtension, "mp4")
        XCTAssertNotNil(Rendition.nearest(atMost: 480), "就近档位推断要有结果")
        XCTAssertGreaterThanOrEqual(Rendition.allCases.count, 3, "档位表至少 3 档")
        XCTAssertNotEqual(Rendition.matching(shortEdge: 1080), Rendition.matching(shortEdge: 360),
                          "不同短边要映射到不同档位")
    }

    // MARK: - 7. 批量预取：一次最多 5 个 vid，选片函数必须与播放共用

    func testBatchBodyCapsAtFiveVids() {
        let six = (0..<6).map { "vid\($0)" }
        let body = PlayerAPI.multiBody(six)
        guard let map = body["mixed_video_id_map"] as? [String: [String]] else {
            return XCTFail("批量请求体缺少 mixed_video_id_map")
        }
        XCTAssertEqual(map["1"]?.count, 5, "官方一次最多 5 个 vid")
        XCTAssertEqual(map["1"], Array(six.prefix(5)))
        guard let biz = body["biz_param"] as? [String: Any] else { return XCTFail("缺少 biz_param") }
        XCTAssertEqual(biz["video_platform"] as? Int, 1024, "只有 1024 被服务端接受")
        // 旧的单条请求体不能被批量版改坏
        let one = PlayerAPI.multiBody("solo")
        XCTAssertEqual((one["mixed_video_id_map"] as? [String: [String]])?["1"], ["solo"])
    }

    func testPickIsSharedBetweenPlaybackAndPrefetch() {
        // 预取和播放必须用同一个 pick，否则预取下的片子切集时命中不了缓存
        let list = PlayerAPI.sorted([
            VideoTrack(definition: "1080p", width: 1080, height: 1920, size: 6_600_000,
                       url: "https://x/1.mp4", spadeA: "k", codec: "bytevc1"),
            VideoTrack(definition: "360p", width: 360, height: 640, size: 2_200_000,
                       url: "https://x/2.mp4", spadeA: "k", codec: "bytevc1"),
        ])
        XCTAssertEqual(PlayerAPI.pick(list, force: nil)?.definition, "1080p", "自动选片优先最高可播档")
        XCTAssertEqual(PlayerAPI.pick(list, force: "360p")?.definition, "360p", "手动指定优先")
        XCTAssertEqual(PlayerAPI.pick(list, force: "720p")?.definition, "1080p",
                       "指定档位不存在时回落到自动选择")
    }
}

/// 在字节数组里找 fourCC（测试用）
func findFourCC(_ hay: [UInt8], _ fourcc: String) -> Int? {
    let needle = Array(fourcc.utf8)
    guard hay.count >= needle.count else { return nil }
    for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
        if Array(hay[i..<(i + needle.count)]) == needle { return i }
    }
    return nil
}
/// 把异步结果从并发域安全带回测试线程
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T?) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
