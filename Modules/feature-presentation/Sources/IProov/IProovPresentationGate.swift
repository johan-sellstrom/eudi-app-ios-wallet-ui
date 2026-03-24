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
import Foundation
import iProov

enum IProovPreparationResult: Sendable {
  case disabled
  case passed
  case launch(URL)
  case failure(IProovPresentationGateError)
}

enum IProovCallbackResult: Sendable {
  case ignored
  case passed
  case failure(IProovPresentationGateError)
}

struct IProovPresentationConfiguration: Equatable, Sendable {
  let enabled: Bool
  let issuerBaseURL: URL?
  let callbackURL: URL?
}

enum IProovPresentationMode: Equatable, Sendable {
  case native
  case webFallback
  case unsupportedRealCeremony
}

struct IProovPresentationGateError: LocalizedError, Equatable, Sendable {
  let message: String

  var errorDescription: String? {
    message
  }
}

actor IProovPresentationGate {

  private var pendingSession: String?
  private let urlSession: URLSession
  private let bundle: Bundle
  private let sdkLauncher: any IProovSDKLaunching

  init(
    urlSession: URLSession = .shared,
    bundle: Bundle = .main,
    sdkLauncher: any IProovSDKLaunching = IProovSDKLauncher()
  ) {
    self.urlSession = urlSession
    self.bundle = bundle
    self.sdkLauncher = sdkLauncher
  }

  func prepareForPresentation() async -> IProovPreparationResult {
    let configuration = resolveIProovConfiguration(infoDictionary: bundle.infoDictionary)
    guard configuration.enabled else {
      return .disabled
    }

    guard
      let issuerBaseURL = configuration.issuerBaseURL,
      let callbackURL = configuration.callbackURL
    else {
      return .failure(.init(message: "iProov is enabled, but the wallet callback or issuer URL is not configured."))
    }

    do {
      let serviceConfiguration: IProovServiceConfigurationResponse = try await requestJSON(
        url: issuerBaseURL.appending(path: "/iproov/config"),
        method: "GET"
      )

      switch resolveIProovPresentationMode(
        realCeremonyEnabled: serviceConfiguration.realCeremonyEnabled,
        nativeSDKSupported: nativeIProovSupportedInCurrentRuntime()
      ) {
      case .native:
        return try await prepareNativePresentation(issuerBaseURL: issuerBaseURL)
      case .webFallback:
        return try await prepareWebFallback(
          issuerBaseURL: issuerBaseURL,
          callbackURL: callbackURL
        )
      case .unsupportedRealCeremony:
        throw IProovPresentationGateError(
          message: "Real iProov on iOS requires a physical device. Run the wallet on an iPhone, or switch the issuer back to demo mode for the web fallback."
        )
      }
    } catch let error as IProovPresentationGateError {
      pendingSession = nil
      return .failure(error)
    } catch {
      pendingSession = nil
      return .failure(.init(message: error.localizedDescription))
    }
  }

  private func prepareNativePresentation(issuerBaseURL: URL) async throws -> IProovPreparationResult {
    let response: NativeClaimResponse = try await requestJSON(
      url: issuerBaseURL.appending(path: "/iproov/claim"),
      method: "GET"
    )

    guard response.mode == "real" else {
      throw IProovPresentationGateError(message: "The issuer did not return a real iProov claim for the native SDK.")
    }
    guard let streamingURL = URL(string: response.streamingURL ?? "") else {
      throw IProovPresentationGateError(message: "The issuer did not return a valid iProov streaming URL.")
    }

    pendingSession = response.session
    print(
      "[LearningLab] native iProov claim session=\(response.session) mode=\(response.mode) streamingHost=\(streamingURL.host() ?? streamingURL.absoluteString)"
    )

    switch await sdkLauncher.launch(streamingURL: streamingURL, token: response.token) {
    case .passed:
      return try await validatePendingSession(issuerBaseURL: issuerBaseURL)
    case .failure(let message):
      pendingSession = nil
      throw IProovPresentationGateError(message: message)
    case .canceled:
      pendingSession = nil
      throw IProovPresentationGateError(message: "The iProov check was canceled before the presentation was shared.")
    }
  }

  private func prepareWebFallback(
    issuerBaseURL: URL,
    callbackURL: URL
  ) async throws -> IProovPreparationResult {
    let requestURL = issuerBaseURL.appending(path: "/iproov/mobile/claim")
    let payload = try JSONEncoder().encode(
      MobileClaimRequest(
        callbackURL: callbackURL.absoluteString
      )
    )

    let response: MobileClaimResponse = try await requestJSON(
      url: requestURL,
      method: "POST",
      body: payload
    )

    pendingSession = response.session
    guard let launchURL = URL(string: response.launchURL) else {
      throw IProovPresentationGateError(message: "The issuer returned an invalid iProov launch URL.")
    }
    return .launch(launchURL)
  }

  private func validatePendingSession(issuerBaseURL: URL) async throws -> IProovPreparationResult {
    guard let session = pendingSession else {
      throw IProovPresentationGateError(message: defaultIProovFailureMessage)
    }
    print("[LearningLab] validating iProov session \(session)")

    let response: SessionStatusResponse = try await requestJSON(
      url: issuerBaseURL.appending(path: "/iproov/validate"),
      method: "POST",
      body: try JSONEncoder().encode(SessionValidationRequest(session: session))
    )
    pendingSession = nil

    if response.passed {
      print("[LearningLab] iProov validation passed for session \(session)")
      return .passed
    }

    print("[LearningLab] iProov validation failed for session \(session): \(response.reason ?? defaultIProovFailureMessage)")
    throw IProovPresentationGateError(message: response.reason ?? defaultIProovFailureMessage)
  }

  func resolveCallback(url: URL) async -> IProovCallbackResult {
    switch parseIProovCallback(url: url, expectedSession: pendingSession) {
    case .ignored:
      return .ignored
    case .failure(let error):
      pendingSession = nil
      return .failure(error)
    case .passed(let session):
      let configuration = resolveIProovConfiguration(infoDictionary: bundle.infoDictionary)
      guard let issuerBaseURL = configuration.issuerBaseURL else {
        pendingSession = nil
        return .failure(.init(message: "The LearningLab issuer URL is not configured in the wallet."))
      }

      do {
        let statusURL = issuerBaseURL.appending(path: "/iproov/session/\(session)")
        let response: SessionStatusResponse = try await requestJSON(
          url: statusURL,
          method: "GET"
        )
        pendingSession = nil
        if response.passed {
          return .passed
        }
        return .failure(.init(message: response.reason ?? defaultIProovFailureMessage))
      } catch let error as IProovPresentationGateError {
        pendingSession = nil
        return .failure(error)
      } catch {
        pendingSession = nil
        return .failure(.init(message: error.localizedDescription))
      }
    }
  }

  private func requestJSON<Response: Decodable>(
    url: URL,
    method: String,
    body: Data? = nil
  ) async throws -> Response {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "content-type")
    }

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw IProovPresentationGateError(message: defaultIProovFailureMessage)
    }

    if !(200 ... 299).contains(httpResponse.statusCode) {
      let errorResponse = try? JSONDecoder().decode(IProovErrorResponse.self, from: data)
      throw IProovPresentationGateError(
        message: errorResponse?.message
          ?? errorResponse?.reason
          ?? errorResponse?.error
          ?? "iProov request failed with status \(httpResponse.statusCode)."
      )
    }

    return try JSONDecoder().decode(Response.self, from: data)
  }
}

enum ParsedIProovCallback: Equatable, Sendable {
  case ignored
  case passed(String)
  case failure(IProovPresentationGateError)
}

func resolveIProovPresentationMode(
  realCeremonyEnabled: Bool,
  nativeSDKSupported: Bool
) -> IProovPresentationMode {
  if realCeremonyEnabled {
    return nativeSDKSupported ? .native : .unsupportedRealCeremony
  }
  return .webFallback
}

func resolveIProovConfiguration(infoDictionary: [String: Any]?) -> IProovPresentationConfiguration {
  let enabled = (infoDictionary?["IProov Enabled"] as? Bool) ?? false
  let baseURL = (infoDictionary?["IProov Issuer Base URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  return IProovPresentationConfiguration(
    enabled: enabled,
    issuerBaseURL: baseURL.flatMap(URL.init(string:)),
    callbackURL: URL(string: "eudi-wallet://iproov")
  )
}

func nativeIProovSupportedInCurrentRuntime() -> Bool {
#if targetEnvironment(simulator)
  false
#else
  true
#endif
}

func parseIProovCallback(
  url: URL,
  expectedSession: String?
) -> ParsedIProovCallback {
  guard
    let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
    components.scheme == "eudi-wallet",
    components.host == "iproov"
  else {
    return .ignored
  }

  let session = components.queryItems?.first(where: { $0.name == "session" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !session.isEmpty else {
    return .failure(.init(message: "The iProov callback is missing the session id."))
  }

  if let expectedSession, expectedSession != session {
    return .failure(.init(message: "The iProov callback did not match the active session."))
  }

  let passed = components.queryItems?.first(where: { $0.name == "passed" })?.value == "true"
  if !passed {
    let reason = components.queryItems?.first(where: { $0.name == "reason" })?.value
    return .failure(.init(message: reason?.isEmpty == false ? reason! : defaultIProovFailureMessage))
  }

  return .passed(session)
}

private struct MobileClaimRequest: Encodable {
  let callbackURL: String

  enum CodingKeys: String, CodingKey {
    case callbackURL = "callback_url"
  }
}

private struct MobileClaimResponse: Decodable {
  let session: String
  let launchURL: String

  enum CodingKeys: String, CodingKey {
    case session
    case launchURL = "launchUrl"
  }
}

private struct NativeClaimResponse: Decodable {
  let session: String
  let mode: String
  let token: String
  let streamingURL: String?

  enum CodingKeys: String, CodingKey {
    case session
    case mode
    case token
    case streamingURL
  }
}

private struct IProovServiceConfigurationResponse: Decodable {
  let realCeremonyEnabled: Bool
}

private struct SessionValidationRequest: Encodable {
  let session: String
}

private struct SessionStatusResponse: Decodable {
  let ok: Bool?
  let passed: Bool
  let reason: String?
}

private struct IProovErrorResponse: Decodable {
  let error: String?
  let message: String?
  let reason: String?
}

private let defaultIProovFailureMessage = "Complete the iProov ceremony before sharing the presentation."

enum IProovSDKLaunchResult: Equatable, Sendable {
  case passed
  case failure(String)
  case canceled
}

protocol IProovSDKLaunching: Sendable {
  @MainActor func launch(streamingURL: URL, token: String) async -> IProovSDKLaunchResult
}

struct IProovSDKLauncher: IProovSDKLaunching {

  @MainActor
  func launch(streamingURL: URL, token: String) async -> IProovSDKLaunchResult {
    await withCheckedContinuation { continuation in
      var didFinish = false

      func finish(with result: IProovSDKLaunchResult) {
        guard !didFinish else { return }
        didFinish = true
        continuation.resume(returning: result)
      }

      let session = IProov.launch(streamingURL: streamingURL, token: token) { status in
        print("[LearningLab] native iProov status: \(String(describing: status))")
        switch status {
        case .connecting, .connected, .processing:
          return
        case .success:
          print("[LearningLab] native iProov succeeded")
          finish(with: .passed)
        case .failure(let result):
          let message = result.reasons
            .map(\.localizedDescription)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          print("[LearningLab] native iProov failure: \(String(describing: result))")
          print("[LearningLab] native iProov failure message: \(message.isEmpty ? defaultIProovFailureMessage : message)")
          finish(with: .failure(message.isEmpty ? defaultIProovFailureMessage : message))
        case .canceled:
          print("[LearningLab] native iProov canceled")
          finish(with: .canceled)
        case .error(let error):
          let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
          print("[LearningLab] native iProov error: \(String(describing: error))")
          finish(with: .failure(message.isEmpty ? defaultIProovFailureMessage : message))
        @unknown default:
          print("[LearningLab] native iProov hit unknown status")
          finish(with: .failure(defaultIProovFailureMessage))
        }
      }

      _ = session
    }
  }
}
