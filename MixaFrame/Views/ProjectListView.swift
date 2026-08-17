import SwiftUI
import UIKit

struct ProjectListView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @State private var showingNewProject = false
  @State private var newProjectName = ""
  @State private var projectToDelete: CollageProject?
  @State private var projectToRename: CollageProject?
  @State private var renameText = ""
  @State private var showingSubscription = false

  var body: some View {
    NavigationStack {
      Group {
        if store.projects.isEmpty {
          ContentUnavailableView {
            Label("No Projects", systemImage: "rectangle.stack.badge.plus")
          } description: {
            Text("Create a project to organize your photo collages.")
          } actions: {
            Button("Create Project") { showingNewProject = true }
              .buttonStyle(.borderedProminent)
          }
        } else {
          List(store.projects) { project in
            NavigationLink {
              ProjectDetailView(projectID: project.id)
            } label: {
              ProjectRow(project: project)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                projectToDelete = project
              } label: {
                Label("Delete", systemImage: "trash")
              }
              Button {
                renameText = project.name
                projectToRename = project
              } label: {
                Label("Rename", systemImage: "pencil")
              }
              .tint(.orange)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("MixaFrame")
      .toolbar {
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
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingNewProject = true
          } label: {
            Label("New Project", systemImage: "plus")
          }
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
      .alert("New Project", isPresented: $showingNewProject) {
        TextField("Project name", text: $newProjectName)
        Button("Cancel", role: .cancel) { newProjectName = "" }
        Button("Create") {
          _ = store.createProject(name: newProjectName)
          newProjectName = ""
        }
      } message: {
        Text("Projects keep related collage tasks together.")
      }
      .alert("Rename Project", isPresented: renamePresented) {
        TextField("Project name", text: $renameText)
        Button("Cancel", role: .cancel) { projectToRename = nil }
        Button("Save") {
          if let projectToRename {
            store.renameProject(id: projectToRename.id, name: renameText)
          }
          projectToRename = nil
        }
      }
      .confirmationDialog(
        "Delete \(projectToDelete?.name ?? "project")?",
        isPresented: deletePresented,
        titleVisibility: .visible
      ) {
        Button("Delete Project and Its Tasks", role: .destructive) {
          if let projectToDelete { store.deleteProject(id: projectToDelete.id) }
          projectToDelete = nil
        }
        Button("Cancel", role: .cancel) { projectToDelete = nil }
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
    Binding(get: { projectToRename != nil }, set: { if !$0 { projectToRename = nil } })
  }

  private var deletePresented: Binding<Bool> {
    Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })
  }

  private var storeAlertPresented: Binding<Bool> {
    Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })
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

private struct ProjectRow: View {
  let project: CollageProject

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "rectangle.stack.fill")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 42, height: 42)
        .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 3) {
        Text(project.name).font(.headline)
        Text("\(project.tasks.count) collage\(project.tasks.count == 1 ? "" : "s")")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}
