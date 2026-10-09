import AppKit
import ShellforgeCore
import SwiftUI

/// The sidebar on the left of a Shellforge window: projects → tasks → tabs.
@MainActor
public enum ShellforgeSidebar {
    /// Its width in points. The window's layout gives the session area what is left.
    public static let width: CGFloat = 240

    /// The view the window places at its left edge: as wide as the sidebar, and only its height
    /// follows the window's. `chooseFolder` asks the user for a project folder (an open panel).
    public static func makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?) -> NSView {
        let host = NSHostingView(rootView: SidebarView(model: model, chooseFolder: chooseFolder))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.autoresizingMask = [.height]
        return host
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let chooseFolder: @MainActor () -> String?
    @State private var newTaskProject: UUID?
    @State private var newTaskTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.tree.projects.isEmpty {
                Text("No projects yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            List {
                ForEach(model.tree.projects) { node in
                    Section {
                        ForEach(node.tasks) { task in taskRow(task) }
                        if newTaskProject == node.id { newTaskField(node.project) }
                    } header: {
                        projectHeader(node.project)
                    }
                }
                if !model.tree.otherTabs.isEmpty {
                    Section("Other tabs") {
                        ForEach(model.tree.otherTabs) { tab in tabRow(tab) }
                    }
                }
            }
            .listStyle(.sidebar)
            if let working = model.working {
                Text(working)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
            }
        }
        .frame(width: ShellforgeSidebar.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("Shellforge").font(.headline)
            Spacer()
            Button {
                if let folder = chooseFolder() { Task { await model.addProject(folder: folder) } }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a project folder")
        }
        .padding(16)
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack {
            Text(project.name)
            Spacer()
            Button {
                newTaskProject = project.id
                newTaskTitle = ""
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("New task in \(project.name)")
        }
    }

    private func newTaskField(_ project: Project) -> some View {
        TextField("Task title", text: $newTaskTitle)
            .onSubmit {
                let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
                newTaskProject = nil
                if !title.isEmpty { Task { await model.newTask(title: title, in: project.id) } }
            }
            .onExitCommand { newTaskProject = nil }
    }

    private func taskRow(_ node: TaskNode) -> some View {
        DisclosureGroup(isExpanded: .constant(model.selectedTaskId == node.id)) {
            ForEach(node.tabs) { tab in tabRow(tab) }
        } label: {
            HStack {
                Text(node.task.title)
                    .fontWeight(model.selectedTaskId == node.id ? .semibold : .regular)
                Spacer()
                Text(node.task.branch).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(task: node.id) }
        }
    }

    private func tabRow(_ tab: TabSnapshot) -> some View {
        Text(tab.title)
            .font(.callout)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab: tab.id) }
    }
}
