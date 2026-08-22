import SwiftUI
import UIKit

struct CollectionDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let collectionID: UUID
  @State private var editorRoute: EditorRoute?
  @State private var projectToDelete: Project?

  private let expandedHorizontalMargin: CGFloat = 24
  private let expandedGridColumns = [
    GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 20, alignment: .top)
  ]

  var body: some View {
    Group {
      if let collection = store.collection(id: collectionID) {
        GeometryReader { _ in
          ScrollView {
            Group {
              if usesExpandedLayout {
                LazyVGrid(
                  columns: expandedGridColumns,
                  alignment: .leading,
                  spacing: 20
                ) {
                  ProjectCreationCard(isExpanded: true) {
                    editorRoute = EditorRoute(project: nil)
                  }

                  ForEach(collection.projects) { project in
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

                  ForEach(collection.projects) { project in
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
    .navigationTitle(store.collection(id: collectionID)?.name ?? "Collection")
    .fullScreenCover(item: $editorRoute) { route in
      ProjectEditorView(collectionID: collectionID, project: route.project)
        .environmentObject(store)
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
  }

  private var deletePresented: Binding<Bool> {
    Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })
  }

  private var usesExpandedLayout: Bool {
    horizontalSizeClass == .regular
  }

}

private struct EditorRoute: Identifiable {
  let id = UUID()
  let project: Project?
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
        Text(project.name)
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ProjectCard: View {
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
        Text(project.name)
          .font(.title3.bold())
          .lineLimit(1)
        Text("\(project.photos.count) photos · \(layout.title)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text("Updated \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
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
