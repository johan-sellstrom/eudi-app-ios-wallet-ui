/*
 * Copyright (c) 2025 European Commission
 *
 * Licensed under the EUPL, Version 1.2 or - as soon they will be approved by the European
 * Commission - subsequent versions of the EUPL (the "Licence"); You may not use this work
 * except in compliance with the Licence.
 *
 * You may obtain a copy of the Licence at:
 * https://joinup.ec.europa.eu/software/page/eupl
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the Licence is distributed on an "AS IS" basis, WITHOUT WARRANTIES OR CONDITIONS OF
 * ANY KIND, either express or implied. See the Licence for the specific language
 * governing permissions and limitations under the Licence.
 */
import XCTest
@testable import feature_presentation

final class TestIProovPresentationGate: XCTestCase {

  func testResolveIProovConfiguration_WhenInfoDictionaryContainsSettings_ThenReturnEnabledConfiguration() {
    let configuration = resolveIProovConfiguration(
      infoDictionary: [
        "IProov Enabled": true,
        "IProov Issuer Base URL": "https://issuer.ipid.me"
      ]
    )

    XCTAssertEqual(configuration.enabled, true)
    XCTAssertEqual(configuration.issuerBaseURL?.absoluteString, "https://issuer.ipid.me")
    XCTAssertEqual(configuration.callbackURL?.absoluteString, "eudi-wallet://iproov")
  }

  func testParseIProovCallback_WhenSessionMatches_ThenReturnPassed() {
    let result = parseIProovCallback(
      url: URL(string: "eudi-wallet://iproov?session=session-123&passed=true")!,
      expectedSession: "session-123"
    )

    XCTAssertEqual(result, .passed("session-123"))
  }

  func testParseIProovCallback_WhenSessionDoesNotMatch_ThenReturnFailure() {
    let result = parseIProovCallback(
      url: URL(string: "eudi-wallet://iproov?session=session-999&passed=true")!,
      expectedSession: "session-123"
    )

    XCTAssertEqual(
      result,
      .failure(.init(message: "The iProov callback did not match the active session."))
    )
  }

  func testResolveIProovPresentationMode_WhenRealCeremonyAndNativeSupported_ThenReturnNative() {
    XCTAssertEqual(
      resolveIProovPresentationMode(
        realCeremonyEnabled: true,
        nativeSDKSupported: true
      ),
      .native
    )
  }

  func testResolveIProovPresentationMode_WhenRealCeremonyAndNativeUnsupported_ThenReturnUnsupportedRealCeremony() {
    XCTAssertEqual(
      resolveIProovPresentationMode(
        realCeremonyEnabled: true,
        nativeSDKSupported: false
      ),
      .unsupportedRealCeremony
    )
  }

  func testResolveIProovPresentationMode_WhenRealCeremonyDisabled_ThenReturnWebFallback() {
    XCTAssertEqual(
      resolveIProovPresentationMode(
        realCeremonyEnabled: false,
        nativeSDKSupported: true
      ),
      .webFallback
    )
  }
}
