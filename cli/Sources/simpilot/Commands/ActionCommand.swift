import Foundation

enum ActionCommand {
    static let argSpec = ArgSpec(
        command: "action",
        positionals: [
            .init(name: "type", required: true),
            .init(name: "query", required: true),
        ],
        flags: [
            .init("--screenshot", .string),
            .init("--scale", .string),
            .init("--level", .int),
            .init("--settle", .double),
            .init("--text", .string),
            .init("--direction", .string),
            .init("--x", .double),
            .init("--y", .double),
            .init("--method", .string),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let action = parsed.positionals[0]
        let query = parsed.positionals[1]

        var body: [String: Any] = ["action": action, "query": query]

        if let screenshot = parsed.string("--screenshot") {
            body["screenshot"] = screenshot
        }
        if let rawScale = parsed.string("--scale") {
            let validated = try ScaleArg.validate(rawScale)
            body["screenshot_scale"] = (validated == "native") ? ("native" as Any) : (Double(validated)! as Any)
        }
        if let level = parsed.int("--level") {
            body["elements_level"] = level
        }
        if let settle = parsed.double("--settle") {
            body["settle_timeout"] = settle
        }
        if let text = parsed.string("--text") {
            body["text"] = text
        }
        if let direction = parsed.string("--direction") {
            body["direction"] = direction
        }
        if let x = parsed.double("--x") {
            body["x"] = x
        }
        if let y = parsed.double("--y") {
            body["y"] = y
        }
        if let method = parsed.string("--method") {
            body["method"] = method
        }

        let data = try client.post("/action", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
