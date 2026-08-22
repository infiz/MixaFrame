import SwiftUI

struct SubscriptionView: View {
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @Environment(\.dismiss) private var dismiss
  @State private var isProcessing = false
  @State private var errorMessage: String?
  @State private var showsPrivacySummary = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          Image(systemName: subscriptions.hasPremiumAccess ? "crown.fill" : "sparkles")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(.indigo)
            .accessibilityHidden(true)

          VStack(spacing: 8) {
            Text(subscriptions.hasPremiumAccess ? "MixaFrame Premium" : "Export Without Watermarks")
              .font(.largeTitle.bold())
              .multilineTextAlignment(.center)
            Text(
              subscriptions.hasPremiumAccess
                ? "Your annual subscription is active."
                : "Keep every editing feature for free, or subscribe for clean project exports."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          }

          Label(
            "No MixaFrame watermark on saved or shared projects", systemImage: "checkmark.seal.fill"
          )
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

          if subscriptions.hasPremiumAccess {
            Link(destination: Self.manageSubscriptionsURL) {
              Label("Manage Subscription", systemImage: "arrow.up.right.square")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
          } else {
            VStack(spacing: 6) {
              Text(subscriptions.isEligibleForTrial ? "7 days free" : "Annual subscription")
                .font(.title2.bold())
              Text(priceDescription)
                .foregroundStyle(.secondary)
            }

            Button(action: purchase) {
              HStack {
                if isProcessing { ProgressView().tint(.white) }
                Text(purchaseButtonTitle)
                  .frame(maxWidth: .infinity)
              }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || subscriptions.annualProduct == nil)

            if subscriptions.annualProduct == nil, !subscriptions.isLoading {
              Button("Retry App Store") {
                isProcessing = true
                Task {
                  await subscriptions.refresh()
                  isProcessing = false
                }
              }
              .disabled(isProcessing)
            }

            Button("Continue Free") { dismiss() }
              .disabled(isProcessing)
          }

          Button("Restore Purchases", action: restorePurchases)
            .disabled(isProcessing)

          VStack(spacing: 8) {
            Text(renewalDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
            HStack(spacing: 18) {
              Link("Terms of Use", destination: Self.termsURL)
              Button("Privacy") { showsPrivacySummary = true }
            }
            .font(.caption)
          }
        }
        .padding(24)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("Premium")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
            .disabled(isProcessing)
        }
      }
    }
    .task {
      if subscriptions.annualProduct == nil { await subscriptions.refresh() }
    }
    .sheet(isPresented: $showsPrivacySummary) {
      PrivacySummaryView()
    }
    .alert("Subscription Error", isPresented: errorPresented) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private var priceDescription: String {
    guard let price = subscriptions.annualPrice else {
      return subscriptions.isLoading ? "Loading App Store pricing…" : "Pricing unavailable"
    }
    return subscriptions.isEligibleForTrial ? "Then \(price) per year" : "\(price) per year"
  }

  private var purchaseButtonTitle: String {
    if subscriptions.isEligibleForTrial { return "Start 7-Day Free Trial" }
    if let price = subscriptions.annualPrice { return "Subscribe for \(price)/Year" }
    return "Subscription Unavailable"
  }

  private var renewalDescription: String {
    if subscriptions.isEligibleForTrial {
      return
        "Your Apple ID will be charged after the 7-day trial. The subscription renews annually until canceled in App Store settings."
    }
    return
      "Payment is charged to your Apple ID. The subscription renews annually until canceled in App Store settings."
  }

  private var errorPresented: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }

  private func purchase() {
    performStoreAction {
      if try await subscriptions.purchaseAnnualSubscription() { dismiss() }
    }
  }

  private func restorePurchases() {
    performStoreAction {
      try await subscriptions.restorePurchases()
      if subscriptions.hasPremiumAccess {
        dismiss()
      } else {
        errorMessage = "No active MixaFrame subscription was found for this Apple ID."
      }
    }
  }

  private func performStoreAction(_ action: @escaping () async throws -> Void) {
    isProcessing = true
    Task {
      do {
        try await action()
      } catch {
        errorMessage = error.localizedDescription
      }
      isProcessing = false
    }
  }

  private static let manageSubscriptionsURL = URL(
    string: "https://apps.apple.com/account/subscriptions")!
  private static let termsURL = URL(
    string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
  )!
}

private struct PrivacySummaryView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Photos and Projects") {
          Text(
            "MixaFrame processes photos and stores collections on your device. It does not upload your photos to a MixaFrame server."
          )
        }
        Section("Purchases") {
          Text(
            "Apple processes subscription purchases and provides MixaFrame with entitlement status. MixaFrame does not receive your payment details."
          )
        }
      }
      .navigationTitle("Privacy")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
    }
  }
}
