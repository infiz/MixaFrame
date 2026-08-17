import Combine
import Foundation
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
  static let annualProductID = "com.infiz.MixaFrame.premium.annual"

  @Published private(set) var annualProduct: Product?
  @Published private(set) var hasPremiumAccess = false
  @Published private(set) var hasLoadedEntitlements = false
  @Published private(set) var isEligibleForTrial = false
  @Published private(set) var isLoading = true

  private var transactionUpdatesTask: Task<Void, Never>?

  init() {
    transactionUpdatesTask = Task { [weak self] in
      for await result in Transaction.updates {
        guard let self else { return }
        if case .verified(let transaction) = result {
          await transaction.finish()
          await refreshEntitlements()
        }
      }
    }

    Task { await refresh() }
  }

  deinit {
    transactionUpdatesTask?.cancel()
  }

  var annualPrice: String? {
    annualProduct?.displayPrice
  }

  func refresh() async {
    isLoading = true
    defer { isLoading = false }

    await refreshEntitlements()

    do {
      annualProduct = try await Product.products(for: [Self.annualProductID]).first
      if let subscription = annualProduct?.subscription {
        isEligibleForTrial = await subscription.isEligibleForIntroOffer
      } else {
        isEligibleForTrial = false
      }
    } catch {
      annualProduct = nil
      isEligibleForTrial = false
    }

  }

  @discardableResult
  func purchaseAnnualSubscription() async throws -> Bool {
    guard let annualProduct else { throw SubscriptionError.productUnavailable }

    switch try await annualProduct.purchase() {
    case .success(let verification):
      let transaction = try verified(verification)
      await transaction.finish()
      await refreshEntitlements()
      return hasPremiumAccess
    case .pending, .userCancelled:
      return false
    @unknown default:
      return false
    }
  }

  func restorePurchases() async throws {
    try await StoreKit.AppStore.sync()
    await refresh()
  }

  func refreshEntitlements() async {
    var isEntitled = false

    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result,
        transaction.productID == Self.annualProductID,
        transaction.revocationDate == nil,
        transaction.isUpgraded == false,
        transaction.expirationDate.map({ $0 > Date() }) ?? true
      else { continue }

      isEntitled = true
      break
    }

    hasPremiumAccess = isEntitled
    hasLoadedEntitlements = true
  }

  private func verified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .verified(let value): value
    case .unverified: throw SubscriptionError.failedVerification
    }
  }
}

enum SubscriptionError: LocalizedError {
  case productUnavailable
  case failedVerification

  var errorDescription: String? {
    switch self {
    case .productUnavailable:
      "The annual subscription is temporarily unavailable. Please try again later."
    case .failedVerification:
      "The App Store could not verify this purchase. No premium access was granted."
    }
  }
}
