import Foundation

enum ElementsCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        var bundleId: String?
        var depth: String?
        var level: String?
        var actionable = false
        var compact = false
        var i = 0

        while i < args.count {
            switch args[i] {
            case "--app":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot elements [--app <bundleId>] [--depth <n>] [--level <n>] [--actionable] [--compact]")
                }
                bundleId = args[i]
            case "--depth":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot elements [--app <bundleId>] [--depth <n>] [--level <n>] [--actionable] [--compact]")
                }
                depth = args[i]
            case "--level":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot elements [--app <bundleId>] [--depth <n>] [--level <n>] [--actionable] [--compact]")
                }
                level = args[i]
            case "--actionable":
                actionable = true
            case "--compact":
                compact = true
            default:
                break
            }
            i += 1
        }

        var queryItems: [String] = []
        if let bundleId {
            queryItems.append("bundleId=\(bundleId)")
        }
        if let depth {
            queryItems.append("depth=\(depth)")
        }
        // --level takes precedence over --actionable/--compact
        if let level {
            queryItems.append("level=\(level)")
        } else if actionable {
            queryItems.append("mode=actionable")
        } else if compact {
            queryItems.append("mode=compact")
        }

        var path = "/elements"
        if !queryItems.isEmpty {
            path += "?" + queryItems.joined(separator: "&")
        }

        let data = try client.get(path)
        printResponse(data: data, pretty: pretty)
    }
}
