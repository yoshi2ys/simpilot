import Foundation
import XCTest
import CoreLocation

final class LocationHandler {
    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let latitude = json["latitude"] as? Double,
              let longitude = json["longitude"] as? Double else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'latitude' and 'longitude'",
                code: "invalid_request"
            )
        }

        let clLocation = CLLocation(latitude: latitude, longitude: longitude)
        let xcuiLocation = XCUILocation(location: clLocation)
        XCUIDevice.shared.location = xcuiLocation

        return HTTPResponseBuilder.json([
            "latitude": latitude,
            "longitude": longitude
        ])
    }
}
