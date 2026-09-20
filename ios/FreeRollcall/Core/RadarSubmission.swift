// Adapted from KrsMt-0113/XMU-Rollcall-Bot c7de02b (verify.py).
// Copyright (c) 2025 KrsMt. MIT License; see THIRD_PARTY_NOTICES.md.
import Foundation

public struct Coordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public enum RadarSubmission {
    public static let first = Coordinate(24.3, 118.0)
    public static let second = Coordinate(24.6, 118.2)

    public static func payload(_ point: Coordinate, deviceID: String = UUID().uuidString.lowercased()) -> JSONValue {
        .object(["accuracy": .number(35), "altitude": .number(0), "altitudeAccuracy": .null,
                 "deviceId": .string(deviceID), "heading": .null, "latitude": .number(point.latitude),
                 "longitude": .number(point.longitude), "speed": .null])
    }

    public static func solve(distance1: Double, distance2: Double) -> [Coordinate]? {
        guard distance1.isFinite, distance2.isFinite, distance1 >= 0, distance2 >= 0 else { return nil }
        let radius = 6_371_000.0
        let lat0 = (first.latitude + second.latitude) / 2
        let lon0 = (first.longitude + second.longitude) / 2
        func radians(_ v: Double) -> Double { v * .pi / 180 }
        func degrees(_ v: Double) -> Double { v * 180 / .pi }
        func xy(_ point: Coordinate) -> (Double, Double) {
            (radians(point.longitude - lon0) * radius * cos(radians(lat0)), radians(point.latitude - lat0) * radius)
        }
        let (x1, y1) = xy(first), (x2, y2) = xy(second)
        let d = hypot(x2 - x1, y2 - y1)
        guard d > 0, d <= distance1 + distance2, d >= abs(distance1 - distance2) else { return nil }
        let a = (distance1 * distance1 - distance2 * distance2 + d * d) / (2 * d)
        let hSquared = distance1 * distance1 - a * a
        guard hSquared >= 0 else { return nil }
        let h = sqrt(hSquared)
        let xm = x1 + a * (x2 - x1) / d, ym = y1 + a * (y2 - y1) / d
        let rx = -(y2 - y1) * (h / d), ry = (x2 - x1) * (h / d)
        func latlon(_ x: Double, _ y: Double) -> Coordinate {
            Coordinate(lat0 + degrees(y / radius), lon0 + degrees(x / (radius * cos(radians(lat0)))))
        }
        return [latlon(xm + rx, ym + ry), latlon(xm - rx, ym - ry)]
    }

    public static func run(transport: any HTTPTransport, id: String) async throws -> Bool {
        func send(_ point: Coordinate) async throws -> APIResponse {
            try await transport.send(APIRequest("/api/rollcall/\(id)/answer", method: "PUT", body: payload(point), radarHeaders: true))
        }
        let r1 = try await send(first)
        let j1 = try r1.json() // Keep the reference's first two JSON/200 branch order.
        if r1.status == 200 { return true }
        let r2 = try await send(second)
        let j2 = try r2.json()
        if r2.status == 200 { return true }
        guard let d1 = j1["distance"].double, let d2 = j2["distance"].double else {
            throw RollcallError.message("雷达响应缺少距离信息，本次签到未完成")
        }
        guard let candidates = solve(distance1: d1, distance2: d2) else { return false }
        let r3 = try await send(candidates[0])
        if r3.status == 200 { return true }
        _ = try r3.json()
        let r4 = try await send(candidates[1])
        return r4.status == 200
    }
}
