import Foundation

/// Weather from Open-Meteo: free, no key, the same service Chronicles uses.
/// Only rounded coordinates are sent (about 1 km), nothing else.
public struct WeatherReport: Equatable, Sendable {
    public var temperature: Double
    public var description: String
    public var high: Double
    public var low: Double
    public var rainChance: Int
    public var unit: String

    public var chip: String { "\(Int(temperature.rounded()))°" }
    public var line: String {
        "\(Int(temperature.rounded()))\(unit) and \(description.lowercased()) now; today \(Int(high.rounded()))\(unit) high, \(Int(low.rounded()))\(unit) low, \(rainChance)% chance of rain."
    }
}

public enum OpenMeteo {
    /// First match for a city ("Portland" or "Portland, OR"), the way Chronicles looks it up.
    public static func findPlace(_ query: String, session: URLSession = .shared) async throws -> HomePlace {
        let parts = query.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let qualifier = parts.count > 1 ? parts[1].lowercased() : ""
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: parts.first ?? query), .init(name: "count", value: "10"),
                        .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        let (data, _) = try await session.data(from: c.url!)
        let results = (try JSONValue.parse(data))["results"]?.array ?? []
        let hit = (qualifier.isEmpty ? nil : results.first { r in
            (r["admin1"]?.string?.lowercased().hasPrefix(qualifier) ?? false)
                || r["country_code"]?.string?.lowercased() == qualifier
                || (r["country"]?.string?.lowercased().hasPrefix(qualifier) ?? false)
        }) ?? results.first
        guard let hit, let place = HomePlace(hit) else { throw URLError(.cannotFindHost) }
        let region = [hit["admin1"]?.string, hit["country_code"]?.string].compactMap { $0 }.joined(separator: ", ")
        return HomePlace(name: region.isEmpty ? place.name : "\(place.name), \(region)", latitude: place.latitude,
                         longitude: place.longitude, timezone: place.timezone)
    }

    public static func url(latitude: Double, longitude: Double, fahrenheit: Bool) -> URL {
        let lat = (latitude * 100).rounded() / 100, lon = (longitude * 100).rounded() / 100
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: "1"), .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        return c.url!
    }

    public static func fetch(latitude: Double, longitude: Double, fahrenheit: Bool, session: URLSession = .shared) async throws -> WeatherReport {
        let (data, _) = try await session.data(from: url(latitude: latitude, longitude: longitude, fahrenheit: fahrenheit))
        return try parse(data, fahrenheit: fahrenheit)
    }

    public static func parse(_ data: Data, fahrenheit: Bool) throws -> WeatherReport {
        let v = try JSONValue.parse(data)
        guard let t = v["current"]?["temperature_2m"]?.double else { throw ClaudeError.malformed }
        let code = v["current"]?["weather_code"]?.int ?? 0
        return WeatherReport(temperature: t, description: describe(code),
                             high: v["daily"]?["temperature_2m_max"]?.array?.first?.double ?? t,
                             low: v["daily"]?["temperature_2m_min"]?.array?.first?.double ?? t,
                             rainChance: v["daily"]?["precipitation_probability_max"]?.array?.first?.int ?? 0,
                             unit: fahrenheit ? "°F" : "°C")
    }

    /// WMO weather codes.
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"; case 1: "Mostly clear"; case 2: "Partly cloudy"; case 3: "Overcast"
        case 45, 48: "Foggy"; case 51, 53, 55, 56, 57: "Drizzle"; case 61, 63, 65, 66, 67: "Rain"
        case 71, 73, 75, 77: "Snow"; case 80, 81, 82: "Showers"; case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorms"; default: "Mixed"
        }
    }
}
