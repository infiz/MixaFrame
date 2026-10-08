import Foundation
import StoreKit
import SwiftUI

/// Counts completed editing visits, rather than taps, launches, or repeated saves.
@MainActor
final class ReviewPromptPolicy {
  static let requiredUsages = 3
  static let cooldown: TimeInterval = 120 * 24 * 60 * 60

  private enum Key {
    static let usages = "reviewPrompt.completedUsages"
    static let requestedAt = "reviewPrompt.lastRequestedAt"
    static let requestedVersion = "reviewPrompt.lastRequestedVersion"
    static let usagesAtRequest = "reviewPrompt.usagesAtLastRequest"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var completedUsages: Int { defaults.integer(forKey: Key.usages) }

  func recordCompletedUsage() {
    defaults.set(completedUsages + 1, forKey: Key.usages)
  }

  /// StoreKit may decline to show UI, so throttle requests, not assumed ratings.
  func consumeRequestOpportunity(version: String, now: Date = Date()) -> Bool {
    guard !version.isEmpty,
      completedUsages - defaults.integer(forKey: Key.usagesAtRequest) >= Self.requiredUsages,
      defaults.string(forKey: Key.requestedVersion) != version
    else { return false }
    if let lastRequest = defaults.object(forKey: Key.requestedAt) as? Date,
      now.timeIntervalSince(lastRequest) < Self.cooldown {
      return false
    }
    defaults.set(now, forKey: Key.requestedAt)
    defaults.set(version, forKey: Key.requestedVersion)
    defaults.set(completedUsages, forKey: Key.usagesAtRequest)
    return true
  }
}

/// Present only after the editor has closed and the browser has settled.
struct CompletedUsageReviewModifier: ViewModifier {
  @Environment(\.requestReview) private var requestReview
  @Environment(\.scenePhase) private var scenePhase
  let policy: ReviewPromptPolicy
  let opportunity: UUID?
  let isIdle: Bool

  private struct TaskID: Equatable {
    let opportunity: UUID?
    let isIdle: Bool
    let isActive: Bool
  }

  func body(content: Content) -> some View {
    content.task(id: TaskID(
      opportunity: opportunity, isIdle: isIdle, isActive: scenePhase == .active
    )) {
      guard opportunity != nil, isIdle, scenePhase == .active else { return }
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return // Navigation, another presentation, or backgrounding cancels this attempt.
      }
      guard !Task.isCancelled,
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        policy.consumeRequestOpportunity(version: version)
      else { return }
      requestReview()
    }
  }
}
