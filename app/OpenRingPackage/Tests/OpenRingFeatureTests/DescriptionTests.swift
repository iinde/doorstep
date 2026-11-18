import Testing
@testable import OpenRingFeature

@Suite struct DescriptionWordingTests {
    @Test func joinsNaturally() {
        #expect(VideoDescription.join(["rang the doorbell"]) == "rang the doorbell")
        #expect(VideoDescription.join(["walked up", "rang", "left a parcel"]) == "walked up, rang and left a parcel")
    }
    @Test func places() {
        #expect(VideoDescription.placeName("Front Door") == "at the front door")
        #expect(VideoDescription.placeName("Garden") == "in the garden")
    }
}
