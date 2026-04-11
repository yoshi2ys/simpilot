import Foundation

enum ActionCommand: SimpilotCommand {
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
        ] + WaitFlags.flags
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "action <type> <query> [--screenshot <path>] [--scale <N|native>] [--level <n>] [--settle <s>] [--text <t>] [--direction <d>] [--method <m>] [--x <n>] [--y <n>] \(WaitFlags.synopsis)"
    static let description = "Compound action with screenshot/elements"
    static let example = "simpilot action tap 'About' --screenshot /tmp/s.png --scale 1 --level 0"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
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
        WaitFlags.apply(parsed, to: &body)

        let data = try context.client.post("/action", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
