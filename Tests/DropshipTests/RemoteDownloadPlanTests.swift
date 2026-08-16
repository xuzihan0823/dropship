import XCTest
@testable import Dropship

final class RemoteDownloadPlanTests: XCTestCase {
    private let serverID = UUID()

    func testClassifiesMixedLocalAndRemoteURLs() {
        let localURL = URL(fileURLWithPath: "/tmp/local.txt")
        let payload = makePayload(path: "/srv/remote.txt", name: "remote.txt")

        let classified = LocalFileDropPayloads.classify([
            localURL,
            payload.dragURL,
            URL(string: "https://example.com/ignored")!,
        ])

        XCTAssertEqual(classified.localURLs, [localURL])
        XCTAssertEqual(classified.remotePayloads, [payload])
    }

    func testBuildsSourceAndTargetForCurrentDirectoryDrop() throws {
        let payload = makePayload(path: "/srv/releases/archive.zip", name: "archive.zip")
        let currentDirectory = URL(fileURLWithPath: "/Users/tester/Downloads", isDirectory: true)

        let plan = try RemoteDownloadPlan.make(
            payload: payload,
            targetDirectory: currentDirectory,
            selectedServerID: serverID
        )

        XCTAssertEqual(plan.sourcePath, "/srv/releases/archive.zip")
        XCTAssertEqual(plan.localDirectory, currentDirectory)
        XCTAssertEqual(plan.targetLocalURL.path, "/Users/tester/Downloads/archive.zip")
    }

    func testUsesDirectoryRowAsLocalTarget() throws {
        let payload = makePayload(path: "/srv/report.csv", name: "report.csv")
        let directoryRow = URL(fileURLWithPath: "/Users/tester/Documents/Reports", isDirectory: true)

        let plan = try RemoteDownloadPlan.make(
            payload: payload,
            targetDirectory: directoryRow,
            selectedServerID: serverID
        )

        XCTAssertEqual(plan.localDirectory, directoryRow)
        XCTAssertEqual(plan.targetLocalURL.path, "/Users/tester/Documents/Reports/report.csv")
    }

    func testRejectsPayloadFromAnotherServer() {
        let payload = RemoteFileDragPayload(
            serverID: UUID(),
            path: "/srv/archive.zip",
            name: "archive.zip",
            isDirectory: false
        )

        XCTAssertThrowsError(try RemoteDownloadPlan.make(
            payload: payload,
            targetDirectory: URL(fileURLWithPath: "/Users/tester/Downloads", isDirectory: true),
            selectedServerID: serverID
        )) { error in
            XCTAssertEqual(error as? RemoteDownloadPlanError, .differentServer)
            XCTAssertEqual(
                error.localizedDescription,
                "不能从另一台服务器下载文件，请先切换到对应服务器"
            )
        }
    }

    private func makePayload(path: String, name: String) -> RemoteFileDragPayload {
        RemoteFileDragPayload(
            serverID: serverID,
            path: path,
            name: name,
            isDirectory: false
        )
    }
}
