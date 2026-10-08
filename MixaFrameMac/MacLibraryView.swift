import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MacLibraryRoute: Hashable {
  case collection(id: UUID, revision: Int)
  case newProject(Project)
  case project(collectionID: UUID, projectID: UUID)
  case recovered(RecoverableProjectDraft, savedProject: Project?)
}

private enum MacLibrarySortCriterion: String, CaseIterable, Identifiable {
  case updated
  case name

  var id: Self { self }
  var title: String { self == .updated ? "Date Updated" : "Name" }
}

private enum MacLibrarySortDirection: String, CaseIterable, Identifiable {
  case descending
  case ascending

  var id: Self { self }
  var title: String { self == .descending ? "Descending" : "Ascending" }
  var symbol: String { self == .descending ? "arrow.down" : "arrow.up" }
}

private struct MacLibrarySortDescriptor {
  var criterion: MacLibrarySortCriterion = .updated
  var direction: MacLibrarySortDirection = .descending

  func sorted<T>(_ values: [T], name: (T) -> String, modifiedAt: (T) -> Date) -> [T] {
    values.sorted { lhs, rhs in
      let comparison: ComparisonResult
      switch criterion {
      case .updated:
        let lhsDate = modifiedAt(lhs)
        let rhsDate = modifiedAt(rhs)
        comparison =
          lhsDate == rhsDate
          ? .orderedSame : lhsDate < rhsDate ? .orderedAscending : .orderedDescending
      case .name:
        comparison = name(lhs).localizedStandardCompare(name(rhs))
      }
      return direction == .ascending
        ? comparison == .orderedAscending
        : comparison == .orderedDescending
    }
  }
}

private struct MacNameRequest: Identifiable {
  enum Kind {
    case newCollection
    case renameCollection(UUID)
  }

  let id = UUID()
  let title: String
  let actionTitle: String
  let initialName: String
  let kind: Kind
}

struct MacLibraryView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @State private var path: [MacLibraryRoute] = []
  @State private var nameRequest: MacNameRequest?
  @State private var collectionToDelete: Collection?
  @State private var projectToDelete: Project?
  @State private var draftToDelete: RecoverableProjectDraft?
  @State private var projectBrowserRefreshRevision = 0
  @State private var collectionSort = MacLibrarySortDescriptor()
  @State private var projectSort = MacLibrarySortDescriptor()
  @State private var showingSubscription = false
  @State private var collectionSearchText = ""
  @State private var projectSearchText = ""
  @State private var reviewOpportunity: UUID?

  private let gridSpacing: CGFloat = 22
  private let gridPadding: CGFloat = 28
  private let gridColumns = [
    GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 22, alignment: .top)
  ]

  var body: some View {
    NavigationStack(path: $path) {
      collectionBrowser
        .navigationDestination(for: MacLibraryRoute.self) { route in
          switch route {
          case .collection(let collectionID, _):
            MacLiveCollection(collectionID: collectionID) { collection in
              projectBrowser(collection)
            }
          case .newProject(let project):
            MacProjectEditorView(
              collectionID: project.collectionID,
              project: project,
              isExistingProject: false,
              onEditorClosed: refreshProjectBrowser
            )
              .id(project.id)
          case .project(let collectionID, let projectID):
            if let project = store.collection(id: collectionID)?.projects.first(where: {
              $0.id == projectID
            }) {
              MacProjectEditorView(
                collectionID: collectionID,
                project: project,
                isExistingProject: true,
                onEditorClosed: refreshProjectBrowser
              )
                .id(projectID)
            } else {
              ContentUnavailableView("Project Unavailable", systemImage: "photo.on.rectangle")
            }
          case .recovered(let recovery, let savedProject):
            MacProjectEditorView(
              collectionID: recovery.project.collectionID,
              project: recovery.project,
              isExistingProject: false,
              savedProject: savedProject,
              isRecoveredDraft: true,
              onEditorClosed: refreshProjectBrowser
            )
            .id(recovery.id)
          }
        }
    }
    .disabled(!store.isLoaded)
    .modifier(CompletedUsageReviewModifier(
      policy: store.reviewPromptPolicy,
      opportunity: reviewOpportunity,
      isIdle: isBrowsingLibrary && nameRequest == nil && !showingSubscription
        && collectionToDelete == nil && projectToDelete == nil && draftToDelete == nil
        && store.alertMessage == nil && collectionSearchText.isEmpty && projectSearchText.isEmpty
    ))
    .overlay {
      if !store.isLoaded {
        ProgressView("Opening library…")
          .padding(18)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .sheet(item: $nameRequest) { request in
      MacNamePrompt(
        title: request.title,
        actionTitle: request.actionTitle,
        initialName: request.initialName
      ) { name in
        applyName(name, request: request)
      }
    }
    .sheet(isPresented: $showingSubscription) {
      SubscriptionView()
        .environmentObject(subscriptions)
    }
    .alert(
      "Delete \(collectionToDelete?.name ?? "collection")?",
      isPresented: Binding(
        get: { collectionToDelete != nil },
        set: { if !$0 { collectionToDelete = nil } }
      )
    ) {
      Button("Delete Collection and Its Projects", role: .destructive) {
        guard let collectionToDelete else { return }
        Task { await store.deleteCollection(id: collectionToDelete.id) }
        self.collectionToDelete = nil
      }
      Button("Cancel", role: .cancel) { collectionToDelete = nil }
    } message: {
      Text("Previously exported images will not be deleted.")
    }
    .alert(
      "Delete Recovered Draft?",
      isPresented: Binding(
        get: { draftToDelete != nil },
        set: { if !$0 { draftToDelete = nil } }
      )
    ) {
      Button("Delete Draft", role: .destructive) {
        guard let draftToDelete else { return }
        Task {
          await store.discardDraft(
            projectID: draftToDelete.id,
            removesUncommittedAssets: true
          )
          refreshProjectBrowser()
        }
        self.draftToDelete = nil
      }
      Button("Cancel", role: .cancel) { draftToDelete = nil }
    } message: {
      Text(
        "This removes the recovery copy and any imported photos that are not used by a saved project."
      )
    }
    .alert(
      "Delete \(projectToDelete?.name ?? "project")?",
      isPresented: Binding(
        get: { projectToDelete != nil },
        set: { if !$0 { projectToDelete = nil } }
      )
    ) {
      Button("Delete Project", role: .destructive) {
        guard let projectToDelete else { return }
        Task {
          await store.deleteProject(
            collectionID: projectToDelete.collectionID, projectID: projectToDelete.id)
        }
        self.projectToDelete = nil
      }
      Button("Cancel", role: .cancel) { projectToDelete = nil }
    }
    .alert(
      "MixaFrame",
      isPresented: Binding(
        get: { store.alertMessage != nil },
        set: { if !$0 { store.alertMessage = nil } }
      )
    ) {
      Button("OK") { store.alertMessage = nil }
    } message: {
      Text(store.alertMessage ?? "The operation could not be completed.")
    }
  }

  private var collectionBrowser: some View {
    VStack(spacing: 0) {
      MacBrowserHeader(
        title: "Collections",
        subtitle: "Organize related photo projects into flexible workspaces.",
        sort: $collectionSort,
        itemName: "Collections"
      )
      ScrollView {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridSpacing) {
          MacCreationCard(
            title: "New Collection",
            subtitle: "Create a collection",
            detail: "Add related photo projects",
            symbol: "rectangle.stack.badge.plus"
          ) {
            nameRequest = MacNameRequest(
              title: "New Collection",
              actionTitle: "Create",
              initialName: "",
              kind: .newCollection
            )
          }
          if store.collections.isEmpty {
            MacWelcomeCard(
              title: "Start Your First Collection",
              detail: "Collections keep related collages together. Create one, add a project, then import photos from Photos or Files."
            )
          }
          ForEach(
            collectionSort.sorted(
              displayedCollections,
              name: \Collection.name,
              modifiedAt: \Collection.modifiedAt
            )
          ) { collection in
            NavigationLink(
              value: MacLibraryRoute.collection(
                id: collection.id,
                revision: projectBrowserRefreshRevision
              )
            ) {
              MacLibraryCard(
                title: collection.name,
                subtitle:
                  "\(collection.projects.count) project\(collection.projects.count == 1 ? "" : "s")",
                detail:
                  "Updated \(collection.modifiedAt.formatted(date: .abbreviated, time: .shortened))",
                previewProject: collection.projects.max { $0.modifiedAt < $1.modifiedAt },
                imageLoader: store.image(for:)
              )
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Rename") {
                nameRequest = MacNameRequest(
                  title: "Rename Collection",
                  actionTitle: "Save",
                  initialName: collection.name,
                  kind: .renameCollection(collection.id)
                )
              }
              Divider()
              Button("Delete", role: .destructive) { collectionToDelete = collection }
            }
          }
        }
        .padding(gridPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("MixaFrame")
    .searchable(text: $collectionSearchText, prompt: "Search Collections")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
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
    }
  }

  private func projectBrowser(_ collection: Collection) -> some View {
    VStack(spacing: 0) {
      MacBrowserHeader(
        title: collection.name,
        subtitle: "Choose a project or start with a fresh canvas.",
        sort: $projectSort,
        itemName: "Projects"
      )
      ScrollView {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridSpacing) {
          MacCreationCard(
            title: "New Project",
            subtitle: "Add photos · 0 selected",
            detail: "Create a photo composition",
            symbol: "photo.on.rectangle.angled",
            showsPlusBadge: true
          ) {
            var project = Project.new(collectionID: collection.id)
            MixaFrameExportPreferences.apply(to: &project)
            path.append(.newProject(project))
          }
          if collection.projects.isEmpty
            && store.recoverableDrafts(collectionID: collection.id).isEmpty
          {
            MacWelcomeCard(
              title: "Build a Photo Composition",
              detail: "Open New Project, choose photos, and MixaFrame will recommend layouts you can refine."
            )
          }
          ForEach(store.recoverableDrafts(collectionID: collection.id)) { recovery in
            ZStack(alignment: .topTrailing) {
              Button {
                path.append(
                  .recovered(
                    recovery,
                    savedProject: collection.projects.first { $0.id == recovery.project.id }
                  )
                )
              } label: {
                MacRecoveredProjectCard(recovery: recovery)
              }
              .buttonStyle(.plain)

              Menu {
                Button("Delete Recovered Draft", systemImage: "trash", role: .destructive) {
                  draftToDelete = recovery
                }
              } label: {
                Image(systemName: "ellipsis")
                  .font(.headline)
                  .padding(8)
                  .background(.regularMaterial, in: Circle())
              }
              .menuStyle(.borderlessButton)
              .fixedSize()
              .padding(12)
              .help("Draft Actions")
              .accessibilityLabel("Draft Actions")
            }
            .contextMenu {
              Button("Discard Recovered Draft", role: .destructive) {
                draftToDelete = recovery
              }
            }
          }
          ForEach(
            projectSort.sorted(
              displayedProjects(in: collection),
              name: \Project.displayName,
              modifiedAt: \Project.modifiedAt
            )
          ) { project in
            NavigationLink(
              value: MacLibraryRoute.project(collectionID: collection.id, projectID: project.id)
            ) {
              VStack(alignment: .leading, spacing: 0) {
                MacProjectCardPreview(project: project)

                VStack(alignment: .leading, spacing: 7) {
                  Text(project.displayName).font(.title3.bold()).lineLimit(1)
                  Text(
                    "\(project.photos.count) photos · \(LayoutEngine.selectedTemplate(for: project).title)"
                  )
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  Text(
                    "Updated \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
                  )
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .background(
                .background,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
              )
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(Color.primary.opacity(0.08), lineWidth: 1)
              }
              .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Export Project File…") { exportPortableProject(project) }
              Divider()
              Button("Delete", role: .destructive) { projectToDelete = project }
            }
          }
        }
        .padding(gridPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle(collection.name)
    .searchable(text: $projectSearchText, prompt: "Search Projects")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { importPortableProject(into: collection.id) } label: {
          Label("Import Project", systemImage: "square.and.arrow.down")
        }
        .help("Import a MixaFrame project file")
      }
    }
  }

  private func applyName(_ name: String, request: MacNameRequest) {
    switch request.kind {
    case .newCollection:
      Task { _ = await store.createCollection(name: name) }
    case .renameCollection(let id):
      Task { await store.renameCollection(id: id, name: name) }
    }
  }

  private func refreshProjectBrowser() {
    projectBrowserRefreshRevision &+= 1
    reviewOpportunity = UUID()
    let revision = projectBrowserRefreshRevision
    guard let collectionID = path.compactMap({ route -> UUID? in
      if case .collection(let id, _) = route { return id }
      return nil
    }).last else { return }
    path.removeAll()
    Task { @MainActor in
      await Task.yield()
      path.append(.collection(id: collectionID, revision: revision))
    }
  }

  private var displayedCollections: [Collection] {
    let query = collectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return store.collections }
    return store.collections.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private var isBrowsingLibrary: Bool {
    guard let route = path.last else { return true }
    if case .collection = route { return true }
    return false
  }

  private func displayedProjects(in collection: Collection) -> [Project] {
    let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return collection.projects }
    return collection.projects.filter {
      $0.displayName.localizedCaseInsensitiveContains(query)
    }
  }

  private func exportPortableProject(_ project: Project) {
    Task {
      do {
        let packageURL = try await store.createPortableProjectFile(for: project)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let panel = NSSavePanel()
        panel.title = "Export MixaFrame Project"
        panel.nameFieldStringValue = "\(project.displayName).mixaframe"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        try await Task.detached(priority: .userInitiated) {
          let fileManager = FileManager.default
          if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
          }
          try fileManager.copyItem(at: packageURL, to: destination)
        }.value
        store.alertMessage = "The project file was exported successfully."
      } catch {
        store.alertMessage = "The project could not be exported: \(error.localizedDescription)"
      }
    }
  }

  private func importPortableProject(into collectionID: UUID) {
    let panel = NSOpenPanel()
    panel.title = "Import MixaFrame Project"
    panel.prompt = "Import"
    panel.allowedContentTypes = [.data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
    guard sourceURL.pathExtension.lowercased() == "mixaframe" else {
      store.alertMessage = "Choose a file ending in .mixaframe."
      return
    }

    Task {
      do {
        let imported = try await store.importPortableProject(
          from: sourceURL,
          into: collectionID
        )
        store.alertMessage = "\(imported.displayName) was imported successfully."
      } catch {
        store.alertMessage = "The project could not be imported: \(error.localizedDescription)"
      }
    }
  }

}

private struct MacBrowserHeader: View {
  let title: String
  let subtitle: String
  @Binding var sort: MacLibrarySortDescriptor
  let itemName: String

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 30, weight: .bold))
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 24)
      Menu {
        Picker("Sort By", selection: $sort.criterion) {
          ForEach(MacLibrarySortCriterion.allCases) { criterion in
            Text(criterion.title).tag(criterion)
          }
        }
        Picker("Order", selection: $sort.direction) {
          ForEach(MacLibrarySortDirection.allCases) { direction in
            Label(direction.title, systemImage: direction.symbol).tag(direction)
          }
        }
      } label: {
        Label("Sort \(itemName)", systemImage: "arrow.up.arrow.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityHint("Sorts \(itemName.lowercased()) by time or name")
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }
}

private struct MacCreationCard: View {
  let title: String
  let subtitle: String
  let detail: String
  let symbol: String
  var showsPlusBadge = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        artwork
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity)
        metadata
          .padding(16)
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Creates a new \(title == "New Collection" ? "collection" : "project")")
  }

  private var artwork: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo.opacity(0.78), .orange.opacity(0.62)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: symbol)
          .font(.system(size: 54, weight: .semibold))
        if showsPlusBadge {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 25, weight: .bold))
            .offset(x: 9, y: 9)
        }
      }
      .foregroundStyle(.white.opacity(0.94))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var metadata: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.title3.bold())
        .lineLimit(1)
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MacLibraryCard: View {
  let title: String
  let subtitle: String
  let detail: String
  let previewProject: Project?
  let imageLoader: (CollagePhoto) -> NSImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topTrailing) {
        Group {
          if let previewProject, !previewProject.photos.isEmpty {
            MacCollageCanvas(project: previewProject, imageLoader: imageLoader)
              .background(.black.opacity(0.86))
          } else {
            LinearGradient(
              colors: [.indigo.opacity(0.78), .orange.opacity(0.62)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
            .overlay {
              Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 48, weight: .semibold))
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
        Text(title).font(.title3.bold()).lineLimit(1)
        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
  }
}

private struct MacWelcomeCard: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: "sparkles.rectangle.stack")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.indigo)
      Text(title).font(.title3.bold())
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
    .background(.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(.indigo.opacity(0.18), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct MacRecoveredProjectCard: View {
  let recovery: RecoverableProjectDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MacProjectCardPreview(project: recovery.project, isRecovery: true)

      VStack(alignment: .leading, spacing: 7) {
        Text(recovery.project.displayName).font(.title3.bold()).lineLimit(1)
        Text("Recovered Draft · \(recovery.project.photos.count) photos")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(recovery.savedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(.orange.opacity(0.35), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens the recovered project draft")
  }
}

private struct MacProjectCardPreview: View {
  @EnvironmentObject private var store: AppStore
  let project: Project
  var isRecovery = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        LinearGradient(
          colors: [
            isRecovery ? .orange.opacity(0.82) : .indigo.opacity(0.74),
            .indigo.opacity(0.68),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        if let preparedBackdrop {
          Color.black.opacity(0.86)
          Image(nsImage: preparedBackdrop)
            .resizable()
            .scaledToFill()
            .blur(radius: 18)
            .opacity(0.42)

          MacCollageCanvas(project: project, imageLoader: store.thumbnailImage(for:))
            .padding(12)
        } else {
          Image(systemName: isRecovery ? "clock.arrow.circlepath" : "photo.on.rectangle.angled")
            .font(.system(size: 46, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .task(id: preparationID) {
      await store.preloadPersistedThumbnails(for: project.photos)
    }
  }

  private var preparedBackdrop: NSImage? {
    project.photos.lazy.compactMap(store.thumbnailImage(for:)).first
  }

  private var preparationID: String {
    "\(project.id.uuidString)-\(project.modifiedAt.timeIntervalSinceReferenceDate)-\(project.photos.count)"
  }
}

private struct MacLiveCollection<Content: View>: View {
  @EnvironmentObject private var store: AppStore
  let collectionID: UUID
  @ViewBuilder let content: (Collection) -> Content

  var body: some View {
    Group {
      if let collection = store.collection(id: collectionID) {
        content(collection)
      } else {
        ContentUnavailableView("Collection Unavailable", systemImage: "rectangle.stack")
      }
    }
  }
}

private struct MacNamePrompt: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let actionTitle: String
  let onSubmit: (String) -> Void
  @State private var name: String

  init(
    title: String, actionTitle: String, initialName: String, onSubmit: @escaping (String) -> Void
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.onSubmit = onSubmit
    _name = State(initialValue: initialName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.title2.weight(.semibold))
      TextField("Collection name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(submit)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(actionTitle, action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(
      minWidth: 500,
      idealWidth: 580,
      maxWidth: 700,
      minHeight: 220,
      idealHeight: 250
    )
  }

  private func submit() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSubmit(trimmed)
    dismiss()
  }
}
