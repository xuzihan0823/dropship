import Foundation
import XCTest
@testable import Dropship

/// 回归：SFTP 降级路径原先固定使用 `find -printf`，那是 GNU findutils 专有选项。
/// BSD（macOS/FreeBSD）与部分精简系统上不存在，会导致列目录直接失败。
/// 下面的样本取自真机实测输出：Ubuntu 24.04（GNU findutils 4.9.0 / coreutils 9.4）
/// 与 macOS 26（BSD stat）。
final class RemoteListingCompatTests: XCTestCase {
    private static let sep = "\u{1F}"

    // MARK: - GNU find -printf（原有快路径不得回归）

    func testParsesGNUFindOutput() {
        let record = [
            "link.txt", "/tmp/x/link.txt", "l", "7", "777",
            "1786761908.5330000000", "ankangxu", "ankangxu", "a b.txt",
        ].joined(separator: "\0") + "\0"

        let entries = SFTPTransport.parseGNUFindListing(Data(record.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = try? XCTUnwrap(entries.first)
        XCTAssertEqual(entry?.name, "link.txt")
        XCTAssertEqual(entry?.path, "/tmp/x/link.txt")
        XCTAssertTrue(entry?.isSymlink == true)
        XCTAssertFalse(entry?.isDir == true)
        XCTAssertEqual(entry?.symlinkTarget, "a b.txt")
        XCTAssertEqual(entry?.mode, "0777")
        XCTAssertEqual(entry?.owner, "ankangxu")
        XCTAssertEqual(entry?.modTime.timeIntervalSince1970 ?? 0, 1786761908.533, accuracy: 0.01)
    }

    // MARK: - GNU stat -c（busybox / 无 find -printf 的系统）

    func testParsesGNUStatOutput() {
        let output = [
            statRecord("/tmp/x/link.txt", "7", "777", "1786761908", "symbolic link"),
            statRecord("/tmp/x/a b.txt", "3", "664", "1786761908", "regular file"),
            statRecord("/tmp/x/sub dir", "4096", "775", "1786761908", "directory"),
        ].joined()

        let entries = SFTPTransport.parseStatListing(Data(output.utf8))
        XCTAssertEqual(entries.map(\.name), ["link.txt", "a b.txt", "sub dir"])
        XCTAssertTrue(entries[0].isSymlink)
        XCTAssertEqual(entries[1].size, 3)
        XCTAssertEqual(entries[1].mode, "0664")
        XCTAssertTrue(entries[2].isDir)
        // 文件名里带空格不能把字段切散
        XCTAssertEqual(entries[1].path, "/tmp/x/a b.txt")
    }

    // MARK: - BSD stat -f（macOS / FreeBSD）

    func testParsesBSDStatOutput() {
        let output = [
            statRecord("/T/tmp.X/a b.txt", "3", "0644", "1786761927", "Regular File"),
            statRecord("/T/tmp.X/link.txt", "7", "0755", "1786761927", "Symbolic Link"),
            statRecord("/T/tmp.X/sub dir", "64", "0755", "1786761927", "Directory"),
        ].joined()

        let entries = SFTPTransport.parseStatListing(Data(output.utf8))
        XCTAssertEqual(entries.count, 3)
        // BSD 的类型描述是首字母大写的，不能大小写敏感地比较
        XCTAssertTrue(entries[1].isSymlink)
        XCTAssertTrue(entries[2].isDir)
        XCTAssertFalse(entries[0].isDir)
        XCTAssertEqual(entries[0].mode, "0644")
    }

    /// 记录之间靠 stat 自己补的换行分隔；文件名内部的换行必须保留。
    func testFilenameContainingNewlineSurvives() {
        let output = statRecord("/tmp/x/a", "1", "644", "1", "regular file")
            + statRecord("/tmp/x/we\nird", "2", "644", "1", "regular file")

        let entries = SFTPTransport.parseStatListing(Data(output.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "/tmp/x/a")
        XCTAssertEqual(entries[1].path, "/tmp/x/we\nird")
    }

    func testEmptyDirectoryYieldsNoEntries() {
        XCTAssertTrue(SFTPTransport.parseStatListing(Data()).isEmpty)
        XCTAssertTrue(SFTPTransport.parseGNUFindListing(Data()).isEmpty)
    }

    // MARK: - 过滤与排序

    func testFinalizeHidesDotFilesAndSortsDirectoriesFirst() {
        let entries = [
            makeEntry(name: "zeta.txt", isDir: false),
            makeEntry(name: ".hidden", isDir: false),
            makeEntry(name: "alpha", isDir: true),
        ]
        XCTAssertEqual(
            SFTPTransport.finalize(entries, showHidden: false).map(\.name),
            ["alpha", "zeta.txt"]
        )
        XCTAssertEqual(
            SFTPTransport.finalize(entries, showHidden: true).map(\.name),
            ["alpha", ".hidden", "zeta.txt"]
        )
    }

    // MARK: - 辅助

    private func statRecord(
        _ path: String, _ size: String, _ mode: String,
        _ mtime: String, _ kind: String
    ) -> String {
        let s = Self.sep
        return "\(path)\(s)\(size)\(s)\(mode)\(s)\(mtime)\(s)ankangxu\(s)ankangxu\(s)\(kind)\(s)\n"
    }

    private func makeEntry(name: String, isDir: Bool) -> RemoteEntry {
        RemoteEntry(
            name: name, path: "/tmp/\(name)", isDir: isDir, isSymlink: false,
            symlinkTarget: nil, size: 0, mode: "0644",
            modTime: Date(timeIntervalSince1970: 0), owner: "u", group: "g"
        )
    }
}
