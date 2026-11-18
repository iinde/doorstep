import Foundation

/// Who delivers to UK doors. Each knows the words painted on its vans and jackets,
/// the shape of its tracking numbers, and the domains its emails come from.
public enum Carrier: String, Codable, CaseIterable, Sendable, Identifiable {
    case royalMail = "Royal Mail"
    case parcelforce = "Parcelforce"
    case dpd = "DPD"
    case dhl = "DHL"
    case evri = "Evri"
    case amazon = "Amazon"
    case ups = "UPS"
    case fedex = "FedEx"
    case yodel = "Yodel"
    case inpost = "InPost"
    case tesco = "Tesco"
    case sainsburys = "Sainsbury's"
    case asda = "Asda"
    case ocado = "Ocado"
    case waitrose = "Waitrose"

    public var id: String { rawValue }

    public var isGrocery: Bool {
        switch self {
        case .tesco, .sainsburys, .asda, .ocado, .waitrose: return true
        default: return false
        }
    }

    /// Whole words (after upper-casing and stripping punctuation) that identify the carrier
    /// when read off a van, jacket or bag. Short ones must match a whole word exactly.
    var paintedWords: [String] {
        switch self {
        case .royalMail: return ["ROYAL MAIL", "ROYALMAIL"]
        case .parcelforce: return ["PARCELFORCE"]
        case .dpd: return ["DPD"]
        case .dhl: return ["DHL"]
        case .evri: return ["EVRI", "HERMES"]
        case .amazon: return ["AMAZON"]
        case .ups: return ["UPS"]
        case .fedex: return ["FEDEX"]
        case .yodel: return ["YODEL"]
        case .inpost: return ["INPOST"]
        case .tesco: return ["TESCO"]
        case .sainsburys: return ["SAINSBURYS", "SAINSBURY"]
        case .asda: return ["ASDA"]
        case .ocado: return ["OCADO"]
        case .waitrose: return ["WAITROSE"]
        }
    }

    /// Email sender domains.
    var mailDomains: [String] {
        switch self {
        case .royalMail: return ["royalmail.com", "royalmail.co.uk"]
        case .parcelforce: return ["parcelforce.co.uk", "parcelforce.com"]
        case .dpd: return ["dpd.co.uk", "dpdlocal.co.uk", "dpd.com"]
        case .dhl: return ["dhl.com", "dhl.co.uk", "dhlparcel.co.uk"]
        case .evri: return ["evri.com", "myhermes.co.uk", "hermes-europe.co.uk"]
        case .amazon: return ["amazon.co.uk", "amazon.com"]
        case .ups: return ["ups.com"]
        case .fedex: return ["fedex.com"]
        case .yodel: return ["yodel.co.uk", "yodeldirect.co.uk"]
        case .inpost: return ["inpost.co.uk"]
        case .tesco: return ["tesco.com", "tesco.co.uk"]
        case .sainsburys: return ["sainsburys.co.uk"]
        case .asda: return ["asda.com", "asda.co.uk"]
        case .ocado: return ["ocado.com"]
        case .waitrose: return ["waitrose.com"]
        }
    }

    /// Tracking number shapes. Only used once the carrier is otherwise unknown, or to
    /// pull the number out of an email we already know is from this carrier.
    var trackingPatterns: [String] {
        switch self {
        case .royalMail: return [#"\b[A-Z]{2}\d{9}GB\b"#, #"\b[A-Z]{2}\d{8}[A-Z]{0,2}\b"#]
        case .parcelforce: return [#"\b[A-Z]{2}\d{7}\b"#, #"\b[A-Z]{2}\d{9}GB\b"#]
        case .dpd: return [#"\b\d{14}\b"#, #"\b\d{10}\b"#]
        case .dhl: return [#"\bJJD\d{10,20}\b"#, #"\b\d{10}\b"#]
        case .evri: return [#"\b[HT][0-9A-Z]{15}\b"#]
        case .amazon: return [#"\bTBA\d{12}\b"#]
        case .ups: return [#"\b1Z[0-9A-Z]{16}\b"#]
        case .fedex: return [#"\b\d{12}\b"#, #"\b\d{15}\b"#]
        case .yodel: return [#"\bJD\d{16,18}\b"#]
        case .inpost: return [#"\b\d{24}\b"#]
        default: return []
        }
    }

    /// Shapes distinctive enough to name the carrier on their own.
    static let distinctiveShapes: [(Carrier, String)] = [
        (.royalMail, #"\b[A-Z]{2}\d{9}GB\b"#),
        (.ups, #"\b1Z[0-9A-Z]{16}\b"#),
        (.amazon, #"\bTBA\d{12}\b"#),
        (.dhl, #"\bJJD\d{10,20}\b"#),
        (.yodel, #"\bJD\d{16,18}\b"#),
        (.evri, #"\b[HT][0-9A-Z]{15}\b"#),
    ]

    public var symbol: String {
        isGrocery ? "basket" : "shippingbox"
    }
}
