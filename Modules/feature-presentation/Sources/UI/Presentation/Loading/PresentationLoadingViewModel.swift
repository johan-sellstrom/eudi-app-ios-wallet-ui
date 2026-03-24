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
import feature_common
import logic_core

final class PresentationLoadingViewModel<Router: RouterHost, RequestItem: Sendable>: BaseLoadingViewModel<Router, RequestItem> {

  private let interactor: PresentationInteractor
  private let iproovGate: IProovPresentationGate
  private var publisherTask: Task<Void, Error>?
  private var coordinator: RemoteSessionCoordinator?
  private var waitingForIProovCallback = false
  private var isPreparingIProov = false
  private var isSendingPresentationResponse = false

  init(
    router: Router,
    interactor: PresentationInteractor,
    iproovGate: IProovPresentationGate = IProovPresentationGate(),
    relyingParty: String,
    relyingPartyIsTrusted: Bool,
    originator: AppRoute,
    requestItems: [ListItemSection<RequestItem>]
  ) {

    self.interactor = interactor
    self.iproovGate = iproovGate

    super.init(
      router: router,
      originator: originator,
      requestItems: requestItems,
      relyingParty: relyingParty,
      relyingPartyIsTrusted: relyingPartyIsTrusted,
      cancellationTimeout: 5
    )
  }

  func subscribeToCoordinatorPublisher() async {
    switch await self.interactor.getSessionStatePublisher() {
    case .success(let publisher):
      for try await state in publisher {
        switch state {
        case .error(let error):
          self.onError(with: error)
        case .responseSent(let url):
          await self.interactor.stopPresentation()
          self.onNavigate(type: .push(await getOnSuccessRoute(with: url)))
        default:
          ()
        }
      }
    case .failure(let error):
      self.onError(with: error)
    }
  }

  override func getTitle() -> LocalizableStringKey {
    .requestDataTitle([getRelyingParty()])
  }

  override func getCaption() -> LocalizableStringKey {
    .requestsTheFollowing
  }

  private func getOnSuccessRoute(with url: URL?) async -> AppRoute {

    self.publisherTask?.cancel()

    var navigationType: UIConfig.DeepLinkNavigationType {
      guard let url else {
        return .pop(screen: getOriginator())
      }
      guard !isDynamicIssuance() else {
        Task { await interactor.storeDynamicIssuancePendingUrl(with: url) }
        return .pop(screen: getOriginator())
      }
      return .deepLink(
        link: url,
        popToScreen: .featureDashboardModule(.dashboard)
      )
    }

    return .featurePresentationModule(
      .presentationSuccess(
        config: DocumentSuccessUIConfig(
          successNavigation: navigationType,
          relyingParty: getRelyingParty(),
          relyingPartyIsTrusted: isRelyingPartyIstrusted(),
          isIssuingDocument: false
        ),
        getRequestItems()
      )
    )
  }

  private func isDynamicIssuance() -> Bool {
    guard
      getOriginator() == AppRoute.featureIssuanceModule(.credentialOfferRequest(config: NoConfig()))
        || getOriginator() == AppRoute.featureIssuanceModule(.issuanceAddDocument(config: NoConfig()))
        || getOriginator() == AppRoute.featureIssuanceModule(.issuanceCode(config: NoConfig()))
    else {
      return false
    }
    return true
  }

  override func getOnPopRoute() -> AppRoute? {
    self.publisherTask?.cancel()
    guard let coordinator = self.coordinator else { return nil }
    return .featurePresentationModule(
      .presentationRequest(
        presentationCoordinator: coordinator,
        originator: getOriginator()
      )
    )
  }

  override func doWork() async {

    startPublisherTask()

    await getCoordinator()

    if waitingForIProovCallback {
      await consumePendingIProovCallbackIfNeeded()
      return
    }

    guard !isPreparingIProov else {
      print("[LearningLab] skipping duplicate iProov preparation while one is already running")
      return
    }

    isPreparingIProov = true
    defer { isPreparingIProov = false }

    switch await iproovGate.prepareForPresentation() {
    case .disabled, .passed:
      await sendPresentationResponse()
    case .launch(let url):
      waitingForIProovCallback = true
      await url.open()
    case .failure(let error):
      self.onError(with: error)
    }
  }

  func handleIProovNotification(with payload: [AnyHashable: Any]) {
    guard
      let rawUri = payload["uri"] as? String,
      let url = URL(string: rawUri)
    else {
      return
    }

    Task { @MainActor in
      print("[LearningLab] received iProov callback notification \(url.absoluteString)")
      await resolveIProovCallback(url: url, source: "notification")
    }
  }

  func processPendingIProovCallbackIfNeeded() {
    Task { @MainActor in
      await consumePendingIProovCallbackIfNeeded()
    }
  }

  private func startPublisherTask() {
    if publisherTask == nil || publisherTask?.isCancelled == true {
      publisherTask = Task {
        await self.subscribeToCoordinatorPublisher()
      }
      Task { try? await self.publisherTask?.value }
    }
  }

  private func getCoordinator() async {
    switch await interactor.getCoordinator() {
    case .success(let remoteSessionCoordinator):
      self.coordinator = remoteSessionCoordinator
    case .failure:
      self.coordinator = nil
    }
  }

  @MainActor
  private func sendPresentationResponse() async {
    guard !isSendingPresentationResponse else {
      print("[LearningLab] skipping duplicate presentation response send")
      return
    }

    isSendingPresentationResponse = true
    print("[LearningLab] sending presentation response to verifier")
    let result = await interactor.onSendResponse()

    switch result {
    case .sent:
      print("[LearningLab] presentation response sent")
    case .failure(let error):
      isSendingPresentationResponse = false
      print("[LearningLab] presentation response failed: \(error.localizedDescription)")
      self.onError(with: error)
    }
  }

  @MainActor
  private func consumePendingIProovCallbackIfNeeded() async {
    guard waitingForIProovCallback else {
      return
    }

    guard let url = await IProovCallbackInbox.shared.take() else {
      return
    }

    print("[LearningLab] consuming stored iProov callback \(url.absoluteString)")
    await resolveIProovCallback(url: url, source: "inbox")
  }

  @MainActor
  private func resolveIProovCallback(url: URL, source: String) async {
    await IProovCallbackInbox.shared.clear()

    switch await iproovGate.resolveCallback(url: url) {
    case .ignored:
      print("[LearningLab] ignored iProov callback from \(source)")
      return
    case .passed:
      print("[LearningLab] iProov callback passed from \(source)")
      waitingForIProovCallback = false
      await sendPresentationResponse()
    case .failure(let error):
      print("[LearningLab] iProov callback failed from \(source): \(error.localizedDescription)")
      waitingForIProovCallback = false
      onError(with: error)
    }
  }
}
