import SwiftUI
import UIKit

enum LibrarySortCriterion: String, CaseIterable, Identifiable {
  case modified
  case name

  var id: String { rawValue }
  var title: String { self == .modified ? "Date Modified" : "Name" }
}

enum LibrarySortDirection: String, CaseIterable, Identifiable {
  case ascending
  case descending

  var id: String { rawValue }
  var title: String { self == .ascending ? "Ascending" : "Descending" }
  var symbol: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

struct LibrarySortDescriptor {
  var criterion: LibrarySortCriterion = .modified
  var direction: LibrarySortDirection = .descending

  func sorted<T>(_ values: [T], name: (T) -> String, modifiedAt: (T) -> Date) -> [T] {
    values.sorted { lhs, rhs in
      switch criterion {
      case .modified:
        return direction == .ascending
          ? modifiedAt(lhs) < modifiedAt(rhs)
          : modifiedAt(lhs) > modifiedAt(rhs)
      case .name:
        let comparison = name(lhs).localizedStandardCompare(name(rhs))
        return direction == .ascending
          ? comparison == .orderedAscending
          : comparison == .orderedDescending
      }
    }
  }
}

struct CollectionListView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showingNewCollection = false
  @State private var newCollectionName = ""
  @State private var collectionToDelete: Collection?
  @State private var collectionToRename: Collection?
  @State private var renameText = ""
  @State private var showingSubscription = false
  @State private var searchText = ""
  @State private var sort = LibrarySortDescriptor()

  private let expandedHorizontalMargin: CGFloat = 24
  private func expandedGridColumns(for width: CGFloat) -> [GridItem] {
    [
      GridItem(
        .adaptive(minimum: min(max(1, width - 48),
          dynamicTypeSize.isAccessibilitySize ? 360 : 260)),
        spacing: 20, alignment: .top)
    ]
  }

  var body: some View {
    NavigationStack {
      Group {
        if !store.isLoaded {
          ProgressView("Loading collections…")
        } else {
          GeometryReader { proxy in
            let usesExpandedLayout = proxy.size.width >= 600 || dynamicTypeSize.isAccessibilitySize
            ScrollView {
              Group {
                if usesExpandedLayout {
                  LazyVGrid(
                    columns: expandedGridColumns(for: proxy.size.width),
                    alignment: .leading,
                    spacing: 20
                  ) {
                    CollectionCreationCard(isExpanded: true) { showingNewCollection = true }

                    if store.collections.isEmpty {
                      CollectionWelcomeCard(isExpanded: true)
                    }

                    ForEach(displayedCollections) { collection in
                      NavigationLink {
                        CollectionDetailView(collectionID: collection.id)
                      } label: {
                        CollectionCard(
                          collection: collection,
                          thumbnail: latestProject(in: collection).flatMap(
                            store.projectThumbnailImage(for:)
                          )
                        )
                      }
                      .buttonStyle(.plain)
                      .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                          renameText = collection.name
                          collectionToRename = collection
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                          collectionToDelete = collection
                        }
                      }
                      .task(id: store.imageCacheReloadGeneration) {
                        guard let project = latestProject(in: collection) else { return }
                        await store.prepareDerivedImages(for: project.photos)
                        guard !Task.isCancelled else { return }
                        await store.prepareProjectThumbnails(for: [project])
                      }
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                  LazyVStack(spacing: 10) {
                    CollectionCreationCard(isExpanded: false) { showingNewCollection = true }

                    if store.collections.isEmpty {
                      CollectionWelcomeCard(isExpanded: false)
                    }

                    ForEach(displayedCollections) { collection in
                      NavigationLink {
                        CollectionDetailView(collectionID: collection.id)
                      } label: {
                        CollectionRow(collection: collection)
                      }
                      .buttonStyle(.plain)
                      .frame(maxWidth: 460)
                      .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                          renameText = collection.name
                          collectionToRename = collection
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                          collectionToDelete = collection
                        }
                      }
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .center)
                }
              }
              .padding(.vertical, 20)
            }
            .contentMargins(
              .horizontal,
              usesExpandedLayout ? expandedHorizontalMargin : 16,
              for: .scrollContent
            )
            .background(Color(uiColor: .systemGroupedBackground))
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("MixaFrame")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search Collections")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          librarySortMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingSubscription = true
          } label: {
            Label(
              subscriptions.hasPremiumAccess ? "Premium Active" : "Upgrade",
              systemImage: subscriptions.hasPremiumAccess ? "crown.fill" : "crown"
            )
            .labelStyle(.iconOnly)
          }
          .tint(subscriptions.hasPremiumAccess ? .green : .orange)
          .accessibilityHint(
            subscriptions.hasPremiumAccess
              ? "Shows subscription details"
              : "Shows the free trial and annual subscription"
          )
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button {
            hideKeyboard()
          } label: {
            Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
          }
        }
      }
      .alert("New Collection", isPresented: $showingNewCollection) {
        TextField("Collection name", text: $newCollectionName)
        Button("Cancel", role: .cancel) { newCollectionName = "" }
        Button("Create") {
          let name = newCollectionName
          newCollectionName = ""
          Task { _ = await store.createCollection(name: name) }
        }
      } message: {
        Text("Collections keep related projects together.")
      }
      .alert("Rename Collection", isPresented: renamePresented) {
        TextField("Collection name", text: $renameText)
        Button("Cancel", role: .cancel) { collectionToRename = nil }
        Button("Save") {
          if let collectionToRename {
            let collectionID = collectionToRename.id
            let name = renameText
            Task { await store.renameCollection(id: collectionID, name: name) }
          }
          collectionToRename = nil
        }
      }
      .confirmationDialog(
        "Delete \(collectionToDelete?.name ?? "collection")?",
        isPresented: deletePresented,
        titleVisibility: .visible
      ) {
        Button("Delete Collection and Its Projects", role: .destructive) {
          if let collectionToDelete {
            Task { await store.deleteCollection(id: collectionToDelete.id) }
          }
          collectionToDelete = nil
        }
        Button("Cancel", role: .cancel) { collectionToDelete = nil }
      } message: {
        Text("Original photos and previously exported images will not be deleted.")
      }
      .alert("MixaFrame", isPresented: storeAlertPresented) {
        Button("OK") { store.alertMessage = nil }
      } message: {
        Text(store.alertMessage ?? "")
      }
      .sheet(isPresented: $showingSubscription) {
        SubscriptionView()
          .environmentObject(subscriptions)
      }
    }
  }

  private var renamePresented: Binding<Bool> {
    Binding(get: { collectionToRename != nil }, set: { if !$0 { collectionToRename = nil } })
  }

  private var displayedCollections: [Collection] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = query.isEmpty
      ? store.collections
      : store.collections.filter { $0.name.localizedCaseInsensitiveContains(query) }
    return sort.sorted(filtered, name: \.name, modifiedAt: \.modifiedAt)
  }

  private var librarySortMenu: some View {
    Menu {
      Picker("Sort By", selection: $sort.criterion) {
        ForEach(LibrarySortCriterion.allCases) { criterion in
          Text(criterion.title).tag(criterion)
        }
      }
      Picker("Order", selection: $sort.direction) {
        ForEach(LibrarySortDirection.allCases) { direction in
          Label(direction.title, systemImage: direction.symbol).tag(direction)
        }
      }
    } label: {
      Label("Sort Collections", systemImage: "arrow.up.arrow.down")
    }
  }

  private var deletePresented: Binding<Bool> {
    Binding(get: { collectionToDelete != nil }, set: { if !$0 { collectionToDelete = nil } })
  }

  private var storeAlertPresented: Binding<Bool> {
    Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })
  }

  private func latestProject(in collection: Collection) -> Project? {
    collection.projects.max { $0.modifiedAt < $1.modifiedAt }
  }

  private func hideKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }
}

private struct CollectionWelcomeCard: View {
  let isExpanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Create your first collage", systemImage: "sparkles.rectangle.stack")
        .font(isExpanded ? .title3.bold() : .headline)
        .foregroundStyle(.indigo)
      Text("1. Create a collection  2. Add 2–12 photos  3. Pick a layout and export")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Smart Layout automatically chooses a strong starting composition and keeps detected subjects in view.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(18)
    .frame(maxWidth: isExpanded ? 380 : 460, alignment: .leading)
    .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18).stroke(.indigo.opacity(0.18))
    }
    .accessibilityElement(children: .combine)
  }
}

private struct CollectionCreationCard: View {
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          creationThumbnail
            .aspectRatio(16 / 9, contentMode: .fit)
          expandedMetadata
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .creationCardSurface(cornerRadius: 22)
      } else {
        HStack(spacing: 12) {
          creationThumbnail
            .frame(width: 104, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 5) {
            Text("New Collection")
              .font(.headline)
              .foregroundStyle(.primary)
            Text("Create a collection")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .foregroundStyle(.indigo)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .creationCardSurface(cornerRadius: 16)
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: isExpanded ? nil : 460)
    .accessibilityLabel("New Collection")
    .accessibilityHint("Creates a collection for a new group of projects")
  }

  private var creationThumbnail: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo.opacity(0.78), .orange.opacity(0.62)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: "rectangle.stack.badge.plus")
        .font(.system(size: isExpanded ? 48 : 25, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(maxWidth: isExpanded ? .infinity : nil)
  }

  private var expandedMetadata: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("New Collection")
        .font(.title3.bold())
        .foregroundStyle(.primary)
      Text("Create a collection")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Add related photo projects")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CollectionCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let collection: Collection
  let thumbnail: UIImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topTrailing) {
        Group {
          if let thumbnail {
            Image(uiImage: thumbnail)
              .resizable()
              .scaledToFill()
          } else {
            LinearGradient(
              colors: [.indigo.opacity(0.78), .orange.opacity(0.62)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
            .overlay {
              Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
            }
          }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()

        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .padding(9)
          .background(.black.opacity(0.36), in: Circle())
          .padding(12)
      }

      VStack(alignment: .leading, spacing: 7) {
        Text(collection.name)
          .font(.title3.bold())
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text("\(collection.projects.count) project\(collection.projects.count == 1 ? "" : "s")")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text("Updated \(collection.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

private struct CollectionRow: View {
  let collection: Collection

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        LinearGradient(
          colors: [.indigo, .orange.opacity(0.76)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Image(systemName: "rectangle.stack.fill")
          .font(.system(size: 25, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 104, height: 68)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 5) {
        Text(collection.name)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text("\(collection.projects.count) project\(collection.projects.count == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Updated \(collection.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 4)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
  }
}

extension View {
  fileprivate func creationCardSurface(cornerRadius: CGFloat) -> some View {
    background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
  }
}
