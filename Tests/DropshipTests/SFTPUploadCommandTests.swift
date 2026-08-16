import XCTest
@testable import Dropship

final class SFTPUploadCommandTests: XCTestCase {
    func testNonAlignedOffsetUsesExactByteSeekAndAppend() {
        let command = SFTPTransport.uploadCommand(
            remote: "/tmp/archive.bin",
            offset: 3_000_000,
            expectedSize: 5_000_000
        )

        XCTAssertTrue(command.contains("dd if=/dev/null of='/tmp/archive.bin.dropship-part' bs=1 seek=3000000 2>/dev/null"))
        XCTAssertTrue(command.contains("cat >> '/tmp/archive.bin.dropship-part'"))
        XCTAssertFalse(command.contains("seek=2"))
        XCTAssertFalse(command.contains("bs=1048576"))
    }

    func testBothOffsetBranchesValidateBeforeRename() {
        let fresh = SFTPTransport.uploadCommand(
            remote: "/tmp/new.bin",
            offset: 0,
            expectedSize: 12
        )
        let resumed = SFTPTransport.uploadCommand(
            remote: "/tmp/resumed.bin",
            offset: 3_000_000,
            expectedSize: 5_000_000
        )

        for command in [fresh, resumed] {
            XCTAssertTrue(command.contains("size=$(wc -c <"))
            XCTAssertTrue(command.contains("if [ \"$size\" != "))
            XCTAssertTrue(command.contains("ESIZE:"))
            let failure = command.range(of: "exit 1")
            let rename = command.range(of: "mv -f --")
            XCTAssertNotNil(failure)
            XCTAssertNotNil(rename)
            if let failure, let rename {
                XCTAssertLessThan(failure.lowerBound, rename.lowerBound)
            }
        }
        XCTAssertTrue(fresh.contains("cat > '/tmp/new.bin.dropship-part'"))
        XCTAssertFalse(fresh.contains("cat >> '/tmp/new.bin.dropship-part'"))
    }

    func testUsesOnlyPortableShellSizeAndTruncationCommands() {
        let command = SFTPTransport.uploadCommand(
            remote: "/tmp/file",
            offset: 3_000_000,
            expectedSize: 5_000_000
        )

        XCTAssertFalse(command.contains("iflag="))
        XCTAssertFalse(command.contains("oflag="))
        XCTAssertFalse(command.contains("stat -c"))
        XCTAssertFalse(command.contains("truncate "))
        XCTAssertFalse(command.contains("find -printf"))
        XCTAssertFalse(command.contains("wc --bytes"))
    }

    func testQuotesRemotePathAndPartWithSpacesAndApostrophes() {
        let remote = "/tmp/with space/owner's file.bin"
        let command = SFTPTransport.uploadCommand(
            remote: remote,
            offset: 0,
            expectedSize: 10
        )

        XCTAssertTrue(command.contains("mkdir -p -- '/tmp/with space'"))
        XCTAssertTrue(command.contains("cat > '/tmp/with space/owner'\\''s file.bin.dropship-part'"))
        XCTAssertTrue(command.contains("mv -f -- '/tmp/with space/owner'\\''s file.bin.dropship-part' '/tmp/with space/owner'\\''s file.bin'"))
    }
}

/// 回归：校验分支原先写作 `[ "$size" -ne N ]`。当 `wc -c` 失败（.part 被删、
/// 权限变化、磁盘异常）时 size 为空串，`[` 会报 "integer expression expected"
/// 并返回 2，`if` 把它当成假 —— **校验失败反而放行了 mv**，半截文件照样覆盖原文件。
/// `set -e` 也抓不到，因为管道的退出码取的是末端 `tr` 的 0。
/// 字符串比较对空串天然成立（"" != "N"），必须保持这个写法。
final class SFTPUploadSizeGuardTests: XCTestCase {
    func testSizeCheckUsesStringComparisonSoEmptyOutputStillFails() {
        let command = SFTPTransport.uploadCommand(
            remote: "/srv/data.bin",
            offset: 0,
            expectedSize: 5_000_000
        )
        XCTAssertTrue(
            command.contains(#"[ "$size" != "5000000" ]"#),
            "必须用字符串比较；数值比较 -ne 遇到空 size 会放行 mv"
        )
        XCTAssertFalse(
            command.contains(#"-ne"#),
            "不得退回数值比较"
        )
    }

    /// mv 必须排在校验之后，否则校验毫无意义。
    func testRenameHappensStrictlyAfterTheSizeCheck() {
        for offset in [Int64(0), 3_000_000] {
            let command = SFTPTransport.uploadCommand(
                remote: "/srv/data.bin",
                offset: offset,
                expectedSize: 5_000_000
            )
            let checkIndex = command.range(of: #"[ "$size" != "#)?.lowerBound
            let mvIndex = command.range(of: "mv -f --")?.lowerBound
            XCTAssertNotNil(checkIndex, "offset=\(offset) 缺少大小校验")
            XCTAssertNotNil(mvIndex, "offset=\(offset) 缺少 mv")
            if let checkIndex, let mvIndex {
                XCTAssertLessThan(checkIndex, mvIndex, "offset=\(offset) 的 mv 早于校验")
            }
        }
    }
}
