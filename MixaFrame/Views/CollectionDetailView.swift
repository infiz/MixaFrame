import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CollectionDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let collectionID: UUID
  @State private var editorRoute: EditorRoute?
  @State private var draftToDelete: RecoverableProjectDraft?
  @State private var projectToDelete: Project?
  @State private var searchText = ""
  @State private var sort = LibrarySortDescriptor()
  @State private var isImportingProject = false
  @State private var projectShareItem: PortableProjectShareItem?
  @State private var transferMessage: String?
  @State private var projectBrowserRevision = 0
  @State private var reviewOpportunity: UUID?

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
    Group {
      if let collection = store.collection(id: collectionID) {
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
                  ProjectCreationCard(isExpanded: true) {
                    editorRoute = EditorRoute(project: nil)
                  }

                  ForEach(store.recoverableDrafts(collectionID: collectionID)) { recovery in
                    Button { openRecoveredDraft(recovery, in: collection) } label: {
                      RecoveredProjectCard(recovery: recovery, isExpanded: true)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                      Button(
                        "Delete Recovered Draft",
                        systemImage: "trash",
                        role: .destructive
                      ) {
                        draftToDelete = recovery
                      }
                    }
                  }

                  ForEach(displayedProjects(in: collection)) { project in
                    Button {
                      editorRoute = EditorRoute(project: project)
                    } label: {
                      ProjectCard(
                        project: project,
                        persistedThumbnail: store.projectThumbnailImage(for: project),
                        imageLoader: store.thumbnailImage(for:)
                      )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                      Button("Export Project File", systemImage: "shippingbox") {
                        exportProjectFile(project)
                      }
                      Button("Delete", systemImage: "trash", role: .destructive) {
                        projectToDelete = project
                      }
                    }
                    .task(id: store.imageCacheReloadGeneration) {
                      await store.prepareDerivedImages(for: project.photos)
                      guard !Task.isCancelled else { return }
                      await store.prepareProjectThumbnails(for: [project])
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
              } else {
                LazyVStack(spacing: 10) {
                  ProjectCreationCard(isExpanded: false) {
                    editorRoute = EditorRoute(project: nil)
                  }

                  ForEach(store.recoverableDrafts(collectionID: collectionID)) { recovery in
                    Button { openRecoveredDraft(recovery, in: collection) } label: {
                      RecoveredProjectCard(recovery: recovery, isExpanded: false)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 460)
                    .contextMenu {
                      Button(
                        "Delete Recovered Draft",
                        systemImage: "trash",
                        role: .destructive
                      ) {
                        draftToDelete = recovery
                      }
                    }
                  }

                  ForEach(displayedProjects(in: collection)) { project in
                    Button {
                      editorRoute = EditorRoute(project: project)
                    } label: {
                      ProjectRow(
                        project: project,
                        persistedThumbnail: store.projectThumbnailImage(for: project),
                        imageLoader: store.thumbnailImage(for:)
                      )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 460)
                    .contextMenu {
                      Button("Export Project File", systemImage: "shippingbox") {
                        exportProjectFile(project)
                      }
                      Button("Delete", systemImage: "trash", role: .destructive) {
                        projectToDelete = project
                      }
                    }
                    .task(id: store.imageCacheReloadGeneration) {
                      await store.prepareDerivedImages(for: project.photos)
                      guard !Task.isCancelled else { return }
                      await store.prepareProjectThumbnails(for: [project])
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
      } else {
        ContentUnavailableView("Collection Not Found", systemImage: "exclamationmark.folder")
      }
    }
    .id(projectBrowserRevision)
    .navigationTitle(store.collection(id: collectionID)?.name ?? "Collection")
    .searchable(text: $searchText, prompt: "Search Projects")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        projectSortMenu
        Button("Import Project", systemImage: "square.and.arrow.down") {
          isImportingProject = true
        }
      }
    }
    .fullScreenCover(item: $editorRoute, onDismiss: refreshProjectBrowser) { route in
      ProjectEditorView(
        collectionID: collectionID,
        project: route.project,
        savedProject: route.savedProject,
        isRecoveredDraft: route.isRecoveredDraft
      )
        .environmentObject(store)
    }
    .modifier(CompletedUsageReviewModifier(
      policy: store.reviewPromptPolicy,
      opportunity: reviewOpportunity,
      isIdle: editorRoute == nil && projectShareItem == nil && !isImportingProject
        && transferMessage == nil && projectToDelete == nil && draftToDelete == nil
        && store.alertMessage == nil && searchText.isEmpty
    ))
    .sheet(item: $projectShareItem, onDismiss: removeSharedProjectFile) { item in
      ShareSheet(items: [item.url])
    }
    .fileImporter(
      isPresented: $isImportingProject,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      importProjectFile(result)
    }
    .alert(
      "Project Transfer",
      isPresented: Binding(
        get: { transferMessage != nil },
        set: { if !$0 { transferMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { transferMessage = nil }
    } message: {
      Text(transferMessage ?? "")
    }
    .confirmationDialog(
      "Delete \(projectToDelete?.name ?? "project")?",
      isPresented: deletePresented,
      titleVisibility: .visible
    ) {
      Button("Delete Project", role: .destructive) {
        if let projectToDelete {
          Task {
            await store.deleteProject(collectionID: collectionID, projectID: projectToDelete.id)
          }
        }
        projectToDelete = nil
      }
      Button("Cancel", role: .cancel) { projectToDelete = nil }
    } message: {
      Text("Original photos and previously exported images will not be deleted.")
    }
    .confirmationDialog(
      "Delete Recovered Draft?",
      isPresented: draftDeletePresented,
      titleVisibility: .visible
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
  }

  private var deletePresented: Binding<Bool> {
    Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })
  }

  private var draftDeletePresented: Binding<Bool> {
    Binding(get: { draftToDelete != nil }, set: { if !$0 { draftToDelete = nil } })
  }

  private func refreshProjectBrowser() {
    projectBrowserRevision &+= 1
    reviewOpportunity = UUID()
  }

  private func displayedProjects(in collection: Collection) -> [Project] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = query.isEmpty
      ? collection.projects
      : collection.projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    return sort.sorted(filtered, name: \.displayName, modifiedAt: \.modifiedAt)
  }

  private var projectSortMenu: some View {
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
      Label("Sort Projects", systemImage: "arrow.up.arrow.down")
    }
  }

  private func openRecoveredDraft(_ recovery: RecoverableProjectDraft, in collection: Collection) {
    var baseline = collection.projects.first { $0.id == recovery.id }
    if baseline == nil {
      var newBaseline = Project.new(collectionID: collectionID)
      newBaseline.id = recovery.id
      baseline = newBaseline
    }
    editorRoute = EditorRoute(
      project: recovery.project,
      savedProject: baseline,
      isRecoveredDraft: true
    )
  }

  private func exportProjectFile(_ project: Project) {
    Task {
      do {
        projectShareItem = PortableProjectShareItem(
          url: try await store.createPortableProjectFile(for: project)
        )
      } catch {
        transferMessage = "The project file could not be created: \(error.localizedDescription)"
      }
    }
  }

  private func importProjectFile(_ result: Result<[URL], Error>) {
    Task {
      do {
        guard let url = try result.get().first else { return }
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        let project = try await store.importPortableProject(from: url, into: collectionID)
        transferMessage = "Imported \(project.displayName)."
      } catch {
        transferMessage = "The project file could not be imported: \(error.localizedDescription)"
      }
    }
  }

  private func removeSharedProjectFile() {
    guard let url = projectShareItem?.url else { return }
    try? FileManager.default.removeItem(at: url)
    projectShareItem = nil
  }

}

private struct EditorRoute: Identifiable {
  let id = UUID()
  let project: Project?
  var savedProject: Project? = nil
  var isRecoveredDraft = false
}

private struct PortableProjectShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

private struct RecoveredProjectCard: View {
  let recovery: RecoverableProjectDraft
  let isExpanded: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: isExpanded ? 34 : 24, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(width: isExpanded ? 58 : 44)
      VStack(alignment: .leading, spacing: 4) {
        Text(recovery.project.displayName).font(.headline)
        Text("Recovered Draft · \(recovery.project.photos.count) photos")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(recovery.savedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer()
      Image(systemName: "chevron.right").foregroundStyle(.tertiary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: isExpanded ? 120 : 88, alignment: .leading)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    .overlay { RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.2)) }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens the recovered project draft")
  }
}

private struct ProjectRow: View {
  let project: Project
  let persistedThumbnail: UIImage?
  let imageLoader: (CollagePhoto) -> UIImage?

  var body: some View {
    let layout = LayoutEngine.selectedTemplate(for: project)
    HStack(spacing: 14) {
      ProjectThumbnail(
        project: project,
        persistedImage: persistedThumbnail,
        imageLoader: imageLoader
      )
      .frame(width: 104, height: 68)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 5) {
        Text(project.displayName)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text("\(project.photos.count) photos · \(layout.title)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(
          "Updated \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
        )
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
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct ProjectCreationCard: View {
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
        .projectCreationCardSurface(cornerRadius: 22)
      } else {
        HStack(spacing: 12) {
          creationThumbnail
            .frame(width: 104, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 6) {
            Text("New Project")
              .font(.headline)
              .foregroundStyle(.primary)
            Label("Create a photo composition", systemImage: "photo.on.rectangle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .foregroundStyle(.indigo)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .projectCreationCardSurface(cornerRadius: 16)
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: isExpanded ? nil : 460)
    .accessibilityLabel("New Project")
    .accessibilityHint("Creates a new photo project")
  }

  private var creationThumbnail: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo.opacity(0.9), .indigo.opacity(0.45)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "photo.on.rectangle.angled")
          .font(.system(size: isExpanded ? 48 : 25, weight: .semibold))
        Image(systemName: "plus.circle.fill")
          .font(.system(size: isExpanded ? 23 : 13, weight: .bold))
          .offset(x: isExpanded ? 8 : 5, y: isExpanded ? 8 : 5)
      }
      .foregroundStyle(.white)
    }
    .frame(maxWidth: isExpanded ? .infinity : nil)
  }

  private var expandedMetadata: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("New Project")
        .font(.title3.bold())
        .foregroundStyle(.primary)
      Label("Add photos", systemImage: "photo.on.rectangle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Create a photo composition")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ProjectCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let project: Project
  let persistedThumbnail: UIImage?
  let imageLoader: (CollagePhoto) -> UIImage?

  var body: some View {
    let layout = LayoutEngine.selectedTemplate(for: project)
    VStack(alignment: .leading, spacing: 0) {
      ProjectThumbnail(
        project: project,
        persistedImage: persistedThumbnail,
        imageLoader: imageLoader
      )
      .frame(maxWidth: .infinity)
      .aspectRatio(16 / 9, contentMode: .fit)

      VStack(alignment: .leading, spacing: 7) {
        Text(project.displayName)
          .font(.title3.bold())
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text("\(project.photos.count) photos · \(layout.title)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text("Updated \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
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

extension View {
  fileprivate func projectCreationCardSurface(cornerRadius: CGFloat) -> some View {
    background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
  }
}
