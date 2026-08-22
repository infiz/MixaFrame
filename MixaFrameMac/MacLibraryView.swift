import SwiftUI

private enum MacLibraryRoute: Hashable {
  case collection(UUID)
  case project(collectionID: UUID, projectID: UUID)
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
  @State private var path: [MacLibraryRoute] = []
  @State private var nameRequest: MacNameRequest?
  @State private var collectionToDelete: Collection?
  @State private var projectToDelete: Project?
  @State private var collectionSort = MacLibrarySortDescriptor()
  @State private var projectSort = MacLibrarySortDescriptor()

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
          case .collection(let collectionID):
            if let collection = store.collection(id: collectionID) {
              projectBrowser(collection)
            } else {
              ContentUnavailableView("Collection Unavailable", systemImage: "rectangle.stack")
            }
          case .project(let collectionID, let projectID):
            if let project = store.collection(id: collectionID)?.projects.first(where: {
              $0.id == projectID
            }) {
              MacProjectEditorView(collectionID: collectionID, project: project)
                .id(projectID)
            } else {
              ContentUnavailableView("Project Unavailable", systemImage: "photo.on.rectangle")
            }
          }
        }
    }
    .disabled(!store.isLoaded)
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
          ForEach(
            collectionSort.sorted(
              store.collections,
              name: \Collection.name,
              modifiedAt: \Collection.modifiedAt
            )
          ) { collection in
            NavigationLink(value: MacLibraryRoute.collection(collection.id)) {
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
            project.name = "Untitled Project"
            Task {
              if await store.saveProject(project) != nil {
                path.append(.project(collectionID: collection.id, projectID: project.id))
              }
            }
          }
          ForEach(
            projectSort.sorted(
              collection.projects,
              name: \Project.name,
              modifiedAt: \Project.modifiedAt
            )
          ) { project in
            NavigationLink(
              value: MacLibraryRoute.project(collectionID: collection.id, projectID: project.id)
            ) {
              VStack(alignment: .leading, spacing: 0) {
                MacCollageCanvas(project: project, imageLoader: store.image(for:))
                  .frame(maxWidth: .infinity)
                  .aspectRatio(16 / 9, contentMode: .fit)
                  .background(.black.opacity(0.86))

                VStack(alignment: .leading, spacing: 7) {
                  Text(project.name).font(.title3.bold()).lineLimit(1)
                  Text(
                    "\(project.photos.count) photos · \(LayoutEngine.selectedTemplate(for: project).title)"
                  )
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  Text(
                    "Updated \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
                  )
                  .font(.caption)
                  .foregroundStyle(.tertiary)
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
  }

  private func applyName(_ name: String, request: MacNameRequest) {
    switch request.kind {
    case .newCollection:
      Task { _ = await store.createCollection(name: name) }
    case .renameCollection(let id):
      Task { await store.renameCollection(id: id, name: name) }
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
