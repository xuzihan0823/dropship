import XCTest
@testable import Dropship

/// 钉住「右键下载不回退到硬编码路径」这条规则，与 UploadDestinationTests 对称。
/// 以前 downloadSelected 写死 ~/Downloads，既不跟本地面板当前目录，
/// 也和拖拽下载（落到拖放目标目录）行为不一致。
final class DownloadDestinationTests: XCTestCase {
    /// 建一个可写的临时目录，测试结束后清理。
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testUsesCurrentLocalDirectory() throws {
        let dir = try makeTempDirectory()
        XCTAssertEqual(DownloadDestination.resolve(localDirectory: dir), dir)
    }

    func testRejectsMissingDirectoryInsteadOfFallingBackToDownloads() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertNil(DownloadDestination.resolve(localDirectory: missing))
    }

    func testRejectsPlainFilePath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(DownloadDestination.resolve(localDirectory: file))
    }

    func testResolvedResultIsNeverHardcodedDownloads() throws {
        // 合法目录原样返回：目标不是 ~/Downloads。
        let dir = try makeTempDirectory()
        let resolved = try XCTUnwrap(DownloadDestination.resolve(localDirectory: dir))
        XCTAssertNotEqual(resolved.path, NSHomeDirectory() + "/Downloads")

        // 非法目录直接拒绝：也不会被替换成 ~/Downloads。
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertNil(DownloadDestination.resolve(localDirectory: missing))
    }
}
