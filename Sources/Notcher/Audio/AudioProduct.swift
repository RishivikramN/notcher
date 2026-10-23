import Foundation

/// Apple audio products recognised from the output device's model UID (spec §9.7).
///
/// For Bluetooth devices CoreAudio's model UID starts with the Bluetooth product ID in hex,
/// e.g. "201B …". Product IDs follow public tables; the shipped app matches 2002, 200f, 2013,
/// 2019, 201b, 2014, 2027, 202d and 200a.
enum AudioProduct: Equatable {
    case airPods1, airPods2, airPods3, airPods4
    case airPodsPro, airPodsPro2, airPodsPro3
    case airPodsMax

    init?(modelUID: String, name: String) {
        let token = modelUID
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," })
            .first
            .map { $0.lowercased() } ?? ""
        switch token {
        case "2002": self = .airPods1
        case "200f": self = .airPods2
        case "2013": self = .airPods3
        case "2019", "201b": self = .airPods4
        case "200e": self = .airPodsPro
        case "2014", "2024": self = .airPodsPro2
        case "2027", "202d": self = .airPodsPro3
        case "200a", "201f": self = .airPodsMax
        default:
            // Fall back to the name when the model UID carries no product ID.
            let lower = name.lowercased()
            if lower.contains("airpods max") { self = .airPodsMax }
            else if lower.contains("airpods pro") { self = .airPodsPro2 }
            else { return nil }
        }
    }

    /// Looping product render bundled in Resources, if there is one for this model.
    /// [?] AirPods Max colour comes from the Bluetooth colour ID, whose mapping isn't known yet,
    /// so every Max uses the Space Gray render for now.
    var renderName: String? {
        switch self {
        case .airPods1, .airPods2: nil
        case .airPods3: "airpods-3"
        case .airPods4: "airpods-4"
        case .airPodsPro: "airpods-pro"
        case .airPodsPro2: "airpods-pro-2"
        case .airPodsPro3: "airpods-pro-3"
        case .airPodsMax: "airpods-max-space-gray"
        }
    }

    var symbolName: String {
        switch self {
        case .airPods1, .airPods2: "airpods"
        case .airPods3: "airpods.gen3"
        case .airPods4: "airpods.gen4"
        case .airPodsPro, .airPodsPro2, .airPodsPro3: "airpodspro"
        case .airPodsMax: "airpodsmax"
        }
    }
}
