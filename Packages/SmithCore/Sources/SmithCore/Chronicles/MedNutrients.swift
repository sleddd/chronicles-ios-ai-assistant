import Foundation

/// Taking a dose of something with vitamins or minerals adds a row to that
/// day's Meals log (meal type "medication"), so Chronicles' nutrient totals
/// include it — a port of Chronicles' utils/medNutrients.ts and
/// hooks/useDoseToMeals.ts. Nutrients come from values typed on the medication,
/// or from its name and dosage ("Vitamin D3" + "1,000 IU" → 25 mcg vitamin D).
/// Smith doesn't ask the AI here (Chronicles caches that answer on the
/// medication, and Smith never edits a medication).
public enum MedNutrients {
    public static let keys = ["iron", "vitaminD", "vitaminB12", "vitaminC"]

    static let patterns: [(String, String)] = [
        ("vitaminD", #"\bvit(?:amin)?\.?\s*d\s*[23]?\b|\bd3\b|\bd2\b|cholecalciferol|ergocalciferol"#),
        ("vitaminB12", #"\bb[-\s]?12\b|cobalamin"#),
        ("vitaminC", #"\bvit(?:amin)?\.?\s*c\b|ascorbic"#),
        ("iron", #"\biron\b|ferrous|ferric"#),
    ]
    static let amount = #"(\d+(?:\.\d+)?)\s*(iu|mcg|µg|ug|mg|g)\b"#

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func toUnit(_ key: String, _ n: Double, _ unit: String) -> Double? {
        let u = unit == "µg" || unit == "ug" ? "mcg" : unit
        switch key {
        case "vitaminD": return u == "iu" ? n / 40 : u == "mcg" ? n : u == "mg" ? n * 1000 : nil
        case "vitaminB12": return u == "mcg" ? n : u == "mg" ? n * 1000 : nil
        case "vitaminC", "iron": return u == "mg" ? n : u == "g" ? n * 1000 : u == "mcg" ? n / 1000 : nil
        default: return nil
        }
    }

    static func noThousands(_ s: String) -> String {
        s.replacingOccurrences(of: #"(\d),(\d{3})\b"#, with: "$1$2", options: .regularExpression)
    }

    /// A single-nutrient supplement read from its name and dosage; multivitamins and anything ambiguous → [:].
    public static func parse(name: String, dosage: String) -> [String: Double] {
        let text = noThousands("\(name) \(dosage)".lowercased())
        if matches(text, "multi|complex|prenatal") { return [:] }
        let found = patterns.filter { matches(text, $0.1) }.map(\.0)
        guard found.count == 1 else { return [:] }
        func firstAmount(_ s: String) -> (Double, String)? {
            guard let r = s.range(of: amount, options: .regularExpression) else { return nil }
            let m = String(s[r])
            guard let numR = m.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression), let n = Double(m[numR]) else { return nil }
            let unit = m[numR.upperBound...].trimmingCharacters(in: .whitespaces)
            return (n, unit)
        }
        guard let (n, unit) = firstAmount(noThousands(dosage.lowercased())) ?? firstAmount(text),
              let v = toUnit(found[0], n, unit), v.isFinite, v > 0 else { return [:] }
        return [found[0]: (v * 100).rounded() / 100]
    }

    /// Values typed on the medication entry (blank fields ignored).
    public static func stored(_ cf: JSONValue) -> [String: Double] {
        var out: [String: Double] = [:]
        for k in keys {
            if let n = cf[k]?.double ?? cf[k]?.string.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), n >= 0 { out[k] = n }
        }
        return out
    }

    /// What one dose adds: typed values (unless an AI answer is stale), else the name and dosage.
    public static func forDose(medicationFields cf: JSONValue, name: String) -> [String: Double] {
        let dosage = cf["dosage"]?.string ?? ""
        let basis = "\(name)|\(dosage)".lowercased()
        let stored = stored(cf)
        let aiStale = cf["doseNutrientSource"]?.string == "ai" && cf["doseNutrientBasis"]?.string != basis
        if !stored.isEmpty && !aiStale { return stored }
        return parse(name: name, dosage: dosage)
    }

    public static func hasAny(_ v: [String: Double]) -> Bool { v.values.contains { $0 > 0 } }

    /// Ties a Meals row to one taken dose (Chronicles' doseLinkKey).
    public static func linkKey(medicationID: Int, date: String, time: String) -> String {
        "\(medicationID)|\(date)|\(time.prefix(5))"
    }

    /// The Meals row for a taken dose, as Chronicles' dashboard saves it.
    public static func mealRow(name: String, dosage: String, values: [String: Double], date: String, time: String,
                               topicID: Int, link: String, createdAt: String?) -> (content: String, metadata: JSONValue) {
        var cf: [String: JSONValue] = [
            "mealDescription": .string(name), "mealType": "medication", "consumedDate": .string(date), "consumedTime": .string(time),
            "notes": .string(dosage.isEmpty ? "From your medication schedule" : "\(dosage) · from your medication schedule"),
        ]
        var source: [String: JSONValue] = [:]
        for k in keys {
            if let v = values[k] {
                cf[k] = .string(Int(exactly: v).map { String($0) } ?? String(v))
                source[k] = "manual"
            } else {
                cf[k] = ""
            }
        }
        cf["nutrientSource"] = .object(source)
        var meta: [String: JSONValue] = ["_taxonomyId": .number(Double(topicID)), "_doseLink": .string(link), "_customFields": .object(cf)]
        if let createdAt { meta["_createdAt"] = .string(createdAt) }
        return ("<p>\(ChroniclesShapes.escape(name))</p>", .object(meta))
    }
}
