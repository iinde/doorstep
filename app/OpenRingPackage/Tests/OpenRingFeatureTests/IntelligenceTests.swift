import Testing
import Foundation
@testable import OpenRingFeature

@Suite struct CarrierTextTests {
    @Test func readsPaintedNames() {
        #expect(IdentityAnalyzer.carrier(inText: "ROYAL MAIL") == .royalMail)
        #expect(IdentityAnalyzer.carrier(inText: "dpd local") == .dpd)
        #expect(IdentityAnalyzer.carrier(inText: "amazon.co.uk") == .amazon)
        #expect(IdentityAnalyzer.carrier(inText: "Tesco") == .tesco)
    }

    @Test func shortNamesNeedWholeWords() {
        #expect(IdentityAnalyzer.carrier(inText: "GROUPS") == nil)    // not UPS
        #expect(IdentityAnalyzer.carrier(inText: "ADPDX") == nil)     // not DPD
        #expect(IdentityAnalyzer.carrier(inText: "STOP") == nil)
    }
}

@Suite struct ParcelParserTests {
    @Test func royalMailOutForDelivery() {
        let p = ParcelParser.parse(subject: "Your item is out for delivery",
                                   from: "Royal Mail <no-reply@royalmail.com>",
                                   body: "Your item AB123456789GB from ASOS is out for delivery today.")
        #expect(p.count == 1)
        #expect(p.first?.tracking == "AB123456789GB")
        #expect(p.first?.carrier == .royalMail)
        #expect(p.first?.status == .outForDelivery)
    }

    @Test func dpdDeliveredWithShop() {
        let p = ParcelParser.parse(subject: "Your DPD parcel has been delivered",
                                   from: "DPD <noreply@dpd.co.uk>",
                                   body: "Your order from Currys has been delivered. Parcel number 15501234567890.")
        #expect(p.first?.carrier == .dpd)
        #expect(p.first?.status == .delivered)
        #expect(p.first?.tracking == "15501234567890")
        #expect(p.first?.deliveredAt != nil)
    }

    @Test func upsShapeAloneNamesCarrier() {
        let p = ParcelParser.parse(body: "Tracking: 1Z999AA10123456784 dispatched")
        #expect(p.first?.carrier == .ups)
    }

    @Test func ignoresOrderAndPhoneNumbers() {
        let p = ParcelParser.parse(subject: "Thanks for your order",
                                   from: "Shop <hi@shop.com>",
                                   body: "Order number 12345678901234. Call 01793123456.")
        #expect(p.allSatisfy { $0.tracking == nil })
    }

    @Test func plainNewsletterIsNotAParcel() {
        let p = ParcelParser.parse(subject: "Black Friday deals", from: "Shop <hi@shop.com>", body: "Save 50% today")
        #expect(p.isEmpty)
    }

    @Test func emlHeaders() {
        let raw = "From: =?utf-8?Q?Evri?= <noreply@evri.com>\r\nSubject: Your parcel is out for delivery\r\nDate: Wed, 18 Nov 2026 09:12:00 +0000\r\n\r\nParcel H01HYA0012345678 is on its way to you today."
        let mail = EmailFile.parse(raw)
        #expect(mail.from.hasPrefix("Evri"))
        #expect(mail.date != nil)
        let p = ParcelParser.parse(subject: mail.subject, from: mail.from, body: mail.body)
        #expect(p.first?.carrier == .evri)
        #expect(p.first?.status == .outForDelivery)
    }
}
