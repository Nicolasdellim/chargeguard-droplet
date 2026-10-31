import XCTest
@testable import Chargeguard

final class ChargePolicyTests: XCTestCase {
    func testRefusesOverlappingAndOutOfBoundsRanges() {
        for value in [ChargeRange(lower: 80, upper: 20), .init(lower: 20, upper: 20), .init(lower: 20, upper: 21), .init(lower: 0, upper: 80), .init(lower: 20, upper: 100)] {
            XCTAssertFalse(value.valid)
        }
        XCTAssertTrue(ChargeRange(lower: 20, upper: 80).valid)
        XCTAssertTrue(ChargeRange(lower: 11, upper: 13).valid)
    }
    func testLegacyChargingResumesAtExactlyTwentyAndStopsAtEighty() {
        let range = ChargeRange(lower: 20, upper: 80)
        var charging = false
        let percentages = [50, 21, 20, 40, 79, 80, 60, 21, 20]
        let expected = [false, false, true, true, true, false, false, false, true]
        for (percent, want) in zip(percentages, expected) {
            // Model the upstream batt v0.8 legacy comparison operators.
            if percent < range.engineLower(mode: "legacy") { charging = true }
            if percent >= range.upper { charging = false }
            XCTAssertEqual(charging, want, "At \(percent)%")
        }
        XCTAssertEqual(range.engineLower(mode: "firmware"), 20)
    }
    func testReadsActualDaemonCompatibilityAndConfiguration() throws {
        let json = #"{"charging":{"pluggedIn":true,"allowCharging":false},"battery":{"currentChargePercent":80,"state":"notCharging"},"configuration":{"enabled":true,"upperLimitPercent":80,"lowerLimitPercent":21},"compatibility":{"chargingControl":true,"chargeControlMode":"legacy"}}"#
        let status = try JSONDecoder().decode(EngineStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.battery.currentChargePercent, 80)
        XCTAssertEqual(status.configuration.lowerLimitPercent, 21)
        XCTAssertEqual(status.charging.allowCharging, false)
        XCTAssertTrue(status.compatibility.chargingControl)
        let unsupported = json.replacingOccurrences(of: #""chargingControl":true"#, with: #""chargingControl":false"#)
        XCTAssertFalse(try JSONDecoder().decode(EngineStatus.self, from: Data(unsupported.utf8)).compatibility.chargingControl)
    }
    func testMalformedTelemetryCannotBecomeAHealthyStatus() {
        XCTAssertThrowsError(try JSONDecoder().decode(EngineStatus.self, from: Data("{}".utf8)))
    }
    func testInstallerPathsRemainLiteralShellArguments() async throws {
        let input = "Folder with 'quotes' and $HOME and `date`"
        let data = try await Engine.run(["-c", "printf %s " + Engine.shellQuote(input)], executable: "/bin/sh")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), input)
    }
}
