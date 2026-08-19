import SwiftUI
import UIKit

struct ProjectDetailView: View {
  @EnvironmentObject private var store: AppStore
  let projectID: UUID
  @State private var editorRoute: EditorRoute?
  @State private var taskToDelete: CollageTask?

  var body: some View {
    Group {
      if let project = store.project(id: projectID) {
        if project.tasks.isEmpty {
          ContentUnavailableView {
            Label("No Collages", systemImage: "photo.on.rectangle.angled")
          } description: {
            Text("Choose photos and create the first collage in this project.")
          } actions: {
            Button("Create Collage") { editorRoute = EditorRoute(task: nil) }
              .buttonStyle(.borderedProminent)
          }
        } else {
          List(project.tasks) { task in
            Button {
              editorRoute = EditorRoute(task: task)
            } label: {
              TaskRow(
                task: task,
                persistedThumbnail: store.collageThumbnailImage(for: task),
                imageLoader: store.thumbnailImage(for:)
              )
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                taskToDelete = task
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
            .task(id: store.imageCacheReloadGeneration) {
              await store.prepareDerivedImages(for: task.photos)
              guard !Task.isCancelled else { return }
              await store.prepareCollageThumbnails(for: [task])
            }
          }
        }
      } else {
        ContentUnavailableView("Project Not Found", systemImage: "exclamationmark.folder")
      }
    }
    .navigationTitle(store.project(id: projectID)?.name ?? "Project")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          editorRoute = EditorRoute(task: nil)
        } label: {
          Label("New Collage", systemImage: "plus")
        }
      }
    }
    .fullScreenCover(item: $editorRoute) { route in
      CollageEditorView(projectID: projectID, task: route.task)
        .environmentObject(store)
    }
    .confirmationDialog(
      "Delete \(taskToDelete?.name ?? "collage")?",
      isPresented: deletePresented,
      titleVisibility: .visible
    ) {
      Button("Delete Collage", role: .destructive) {
        if let taskToDelete {
          Task { await store.deleteTask(projectID: projectID, taskID: taskToDelete.id) }
        }
        taskToDelete = nil
      }
      Button("Cancel", role: .cancel) { taskToDelete = nil }
    } message: {
      Text("Original photos and previously exported images will not be deleted.")
    }
  }

  private var deletePresented: Binding<Bool> {
    Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } })
  }
}

private struct EditorRoute: Identifiable {
  let id = UUID()
  let task: CollageTask?
}

private struct TaskRow: View {
  let task: CollageTask
  let persistedThumbnail: UIImage?
  let imageLoader: (CollagePhoto) -> UIImage?

  var body: some View {
    let layout = LayoutEngine.selectedTemplate(for: task)
    HStack(spacing: 14) {
      CollageTaskThumbnail(
        task: task,
        persistedImage: persistedThumbnail,
        imageLoader: imageLoader
      )
      .frame(width: 72, height: 58)
      VStack(alignment: .leading, spacing: 3) {
        Text(task.name).font(.headline)
        Text("\(task.photos.count) photos · \(layout.title)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(
          "Last saved \(task.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
      Spacer()
      Image(systemName: "chevron.right").foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 4)
  }
}
