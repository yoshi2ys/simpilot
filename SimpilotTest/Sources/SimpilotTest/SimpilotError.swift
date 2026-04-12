import Foundation

public enum SimpilotError: Error, Sendable {
    case agentUnreachable(String)
    case commandFailed(code: String, message: String)
    case assertionFailed(code: String, message: String)
    case invalidURL(String)
}
