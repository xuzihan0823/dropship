import Foundation

/// App-internal payload for moving a remote entry without pretending that its
/// server path is a local file URL.
struct RemoteFileDragPayload: Codable, Hashable, Sendable {
    private static let dragScheme = "dropship-remote"
    private static let dragHost = "move"

    let serverID: UUID
    let path: String
    let name: String
    let isDirectory: Bool

    init(serverID: UUID, path: String, name: String, isDirectory: Bool) {
        self.serverID = serverID
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }

    init?(dragURL: URL) {
        guard dragURL.scheme == Self.dragScheme,
              dragURL.host == Self.dragHost,
              let encoded = URLComponents(url: dragURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = Data(base64URLEncoded: encoded),
              let payload = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = payload
    }

    var dragURL: URL {
        let data = try! JSONEncoder().encode(self)
        var components = URLComponents()
        components.scheme = Self.dragScheme
        components.host = Self.dragHost
        components.queryItems = [
            URLQueryItem(name: "payload", value: data.base64URLEncodedString())
        ]
        return components.url!
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerObject(ofClass: NSURL.self, visibility: .ownProcess) { completion in
            completion(self.dragURL as NSURL, nil)
            return nil
        }
        return provider
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        self.init(base64Encoded: encoded)
    }
}

struct RemoteDownloadPlan: Equatable {
    let sourcePath: String
    let targetLocalURL: URL

    var localDirectory: URL {
        targetLocalURL.deletingLastPathComponent()
    }

    static func make(
        payload: RemoteFileDragPayload,
        targetDirectory: URL,
        selectedServerID: UUID
    ) throws -> RemoteDownloadPlan {
        guard payload.serverID == selectedServerID else {
            throw RemoteDownloadPlanError.differentServer
        }

        let source = (payload.path as NSString).standardizingPath
        let filename = (source as NSString).lastPathComponent
        guard source.hasPrefix("/"), !filename.isEmpty, filename == payload.name,
              targetDirectory.isFileURL else {
            throw RemoteDownloadPlanError.invalidPayload
        }

        let directory = targetDirectory.standardizedFileURL
        return RemoteDownloadPlan(
            sourcePath: source,
            targetLocalURL: directory.appendingPathComponent(filename)
        )
    }
}

enum RemoteDownloadPlanError: LocalizedError, Equatable {
    case differentServer
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .differentServer:
            return "不能从另一台服务器下载文件，请先切换到对应服务器"
        case .invalidPayload:
            return "拖拽的服务器文件信息无效"
        }
    }
}

struct LocalFileDropPayloads: Equatable {
    let localURLs: [URL]
    let remotePayloads: [RemoteFileDragPayload]

    static func classify(_ urls: [URL]) -> LocalFileDropPayloads {
        LocalFileDropPayloads(
            localURLs: urls.filter(\.isFileURL),
            remotePayloads: urls.compactMap(RemoteFileDragPayload.init(dragURL:))
        )
    }
}

struct RemoteFileMovePlan: Equatable {
    let sourcePath: String
    let targetPath: String

    static func make(
        payload: RemoteFileDragPayload,
        targetDirectory: String,
        selectedServerID: UUID
    ) throws -> RemoteFileMovePlan {
        guard payload.serverID == selectedServerID else {
            throw RemoteFileMoveError.differentServer
        }

        let source = normalized(payload.path)
        let directory = normalized(targetDirectory)
        let filename = (source as NSString).lastPathComponent
        guard source.hasPrefix("/"), directory.hasPrefix("/"),
              !filename.isEmpty, filename == payload.name else {
            throw RemoteFileMoveError.invalidPayload
        }

        if payload.isDirectory,
           (directory == source || directory.hasPrefix(source + "/")) {
            throw RemoteFileMoveError.directoryInsideItself
        }

        let target = normalized((directory as NSString).appendingPathComponent(filename))
        guard target != source else {
            throw RemoteFileMoveError.alreadyInDirectory
        }
        return RemoteFileMovePlan(sourcePath: source, targetPath: target)
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

enum RemoteFileMoveError: LocalizedError, Equatable {
    case differentServer
    case invalidPayload
    case directoryInsideItself
    case alreadyInDirectory
    case targetExists(String)

    var errorDescription: String? {
        switch self {
        case .differentServer:
            return "不能把文件移动到另一台服务器"
        case .invalidPayload:
            return "拖拽的服务器文件信息无效"
        case .directoryInsideItself:
            return "不能把文件夹移动到它自身或它的子文件夹中"
        case .alreadyInDirectory:
            return "文件已经在这个文件夹中"
        case .targetExists(let name):
            return "目标文件夹中已存在「\(name)」"
        }
    }
}
