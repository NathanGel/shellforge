# M4b Keyboard shortcuts, and a sidebar you can hide and resize — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- **W9, keyboard:** Shellforge's actions get shortcuts that leave every iTerm2 key alone (the user's choice, option A, 12 October 2026).
- **W11 and the user's request:** the sidebar can be hidden and shown (⌃⌘S, as Finder and Mail do), and dragged to any width between its minimum and a maximum. Width and visibility are remembered.

**Keys** (all free in iTerm2's `MainMenu.xib`, where an uppercase key means ⇧; ⌃⌘F and the ⌃⌘ arrows are iTerm2's):

| Keys | Action | Acts on |
|---|---|---|
| ⌃⌘N | New Task… | the target project |
| ⌃⌘R | New Review… | the target project |
| ⌃⌘P | Add Project… | — |
| ⌃⌘] / ⌃⌘[ | Next Task / Previous Task | the sidebar's task order, wrapping round |
| ⌃⌘⌫ | Remove Task… (asks first, as the row's menu does) | the selected task |
| ⌃⌘A | Focus View: open the projects with a task waiting on you, fold the rest, show the first such task | — |
| ⌃⌘L | List View: open every project | — |
| ⌃⌘S | Hide Sidebar / Show Sidebar | the window |

The **target project** is the selected task's project. With no task selected, it is the window's only project. With several projects and no selection, the action is off.

**Architecture:**
- **ShellforgeUI:**
  - `SidebarCommand` lists the actions above.
  - `SidebarModel.can(_:)` and `perform(_:)` hold the rules, tested.
  - Actions that open a sheet are published as `sheetRequests`, which `ShellforgeSidebar` presents as its "+" does.
  - `SidebarLayoutSettings` keeps the width (clamped) and the hidden flag in an injected `UserDefaults`.
- **App:**
  - A "Tasks" menu after View holds the task keys; View gains Hide/Show Sidebar.
  - The items act on the key window's sidebar, found through a window → model map.
- **iTerm2's root view:**
  - An `iTermDragHandleView` at the sidebar's right edge resizes it, as the left tab bar's handle does.
  - The width comes from `SidebarLayoutSettings`; a hidden sidebar has width 0 and is not drawn.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Objective-C in `iTermRootTerminalView.m` and `iTermApplicationDelegate.m`; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:** PRD W9 and W11; the user's request of 12 October 2026 (hide the sidebar, drag it to a size).

## Global Constraints

- No iTerm2 shortcut changes or is shadowed. A new key is used only if `MainMenu.xib` does not use it. The app is checked at the end by listing the main menu's key equivalents for duplicates.
- Tests use `UserDefaults(suiteName:)` with a unique name, never `.standard`.
- Upstream files change only in Shellforge-marked blocks: `iTermRootTerminalView.m`, `iTermApplicationDelegate.m`.
- macOS 13; design tokens only (`DesignRulesTests`). Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **A window narrower than the sidebar's saved width.** Expected: the terminal keeps at least its own minimum; the sidebar gives way. Test: Task 3 `theWidthIsClampedToTheWindow`.
2. **Two windows.** Expected: a shortcut acts on the key window's sidebar, never another's. Test: Task 2 `commandsGoToTheKeyWindowsSidebar` (the map, with two fake windows).
3. **No project, or several with none selected.** Expected: New Task and New Review are off; their items are disabled. Test: Task 1 `theTargetProjectRule`.
4. **Next Task at the last task.** Expected: it wraps to the first, and does nothing with no tasks. Test: Task 1 `nextAndPreviousWrap`.
5. **Hiding the sidebar while a sheet of it is open.** Expected: the sheet stays and closes normally. This is checked live.

---

### Task 1: The commands and their rules

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarCommands.swift`:
  - `enum SidebarCommand { newTask, newReview, addProject, nextTask, previousTask, removeTask, focusView, listView }`.
  - `extension SidebarModel` adds:
    - `targetProject: UUID?`;
    - `can(_:) -> Bool`;
    - `perform(_:)`. It selects, folds and opens directly, and publishes `.newTask(project)`, `.newReview(project)`, `.addProject` and `.removeTask(task)` on `sheetRequests: PassthroughSubject<SheetRequest, Never>`.
  - `waitingOnYou: [UUID]` lists the tasks whose status is needs input, or done and unseen, in sidebar order.
- Modify: `ShellforgeSidebar.swift`: `.onReceive(model.sheetRequests)` presents New Task, New Review, Add Project and the removal prompt.
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarCommandsTests.swift`:
  - `theTargetProjectRule`
  - `nextAndPreviousWrap`
  - `focusViewOpensWhatWaitsAndShowsTheFirst`
  - `listViewOpensEveryProject`
  - `sheetCommandsAreRequested`
  - `removeNeedsASelectedTask`

### Task 2: The menus

**Files:**
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - A map from each `PseudoTerminal` to its `SidebarModel`: `NSMapTable`, weak to weak.
  - `@objc static func perform(_ command: Int, in window: NSWindow?)` and `can(_:in:)`.
  - `@objc static func toggleSidebar(in:)`.
  - `SidebarCommandMenu.items`: title, key, modifiers and command, so the delegate builds them from one list.
- Modify: `sources/AppKit/iTermApplicationDelegate.m`: a "Tasks" menu after View is built from that list, and View gets "Hide Sidebar ⌃⌘S". `validateMenuItem:` asks `can`, and names the Hide or Show item by the window's state.
- Test: `SidebarCommandsTests.commandsGoToTheKeyWindowsSidebar` is pure: `SidebarWindows`, a map from a window key to a model, picks the key window's model.
- Test: `SidebarCommandsTests.noKeyIsUsedTwice` checks the list's own keys against each other.

### Task 3: Hide and resize

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarLayoutSettings.swift`:
  - `struct SidebarLayoutSettings(defaults:)` holds `width` (default `Size.sidebarWidth`, clamped to `Size.sidebarMinWidth` to `Size.sidebarMaxWidth`) and `hidden` (default false), each with a setter that saves it.
  - `static func width(_ preferred: CGFloat, windowWidth: CGFloat) -> CGFloat` leaves the terminal at least `Size.terminalMinWidth`.
- Modify: `ShellforgeDesign/Metrics.swift`: `sidebarMaxWidth` (720) and `terminalMinWidth` (320), each with its reason. The README says so.
- Modify: `iTermShellforgeSidebar.swift`:
  - `@objc static func widthFor(windowWidth:hidden:)` and `setPreferredWidth(_:)`.
  - Hidden is per window, initialised from the setting when the window opens. Toggling it saves the setting, so new windows open as the last toggle left them.
- Modify: `iTermRootTerminalView.m`:
  - `_shellforgeSidebarHidden`.
  - `shellforgeSidebarWidth` uses `widthFor`; hidden is 0, and the view is hidden.
  - An `iTermDragHandleView` (3 pt) sits at the sidebar's right edge. In `dragHandleView:didMoveBy:`, a branch for it sets the preferred width, lays out, and returns the actual change. `dragHandleViewDidFinishMoving:` tells the delegate the content area resized, as the tab bar's does.
  - `toggleShellforgeSidebar` lays out and calls `rootTerminalViewDidResizeContentArea`.
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarLayoutSettingsTests.swift`:
  - `theWidthIsRememberedAndClamped`
  - `theWidthIsClampedToTheWindow`
  - `hiddenIsRemembered`
  - `aNewSettingsReadsTheDefaults`

### Task 4: Keys documented, and verified

- Create: `Shellforge/docs/keyboard.md`: the keys table above, iTerm2's keys left alone, and the sidebar's drag and ⌃⌘S.
- Build the app; the package and the daemon pass. List the main menu's key equivalents from the built app (through a debug-only `iTermShellforgeSidebar.menuKeyReport()` run in ModernTests), and check that none repeats.
- Live check, for the user:
  1. Drag the sidebar's right edge: it resizes; quit and relaunch, and the width is kept.
  2. ⌃⌘S hides and shows it.
  3. ⌃⌘N / ⌃⌘R open New Task / New Review on the selected task's project.
  4. ⌃⌘] and ⌃⌘[ step through tasks.
  5. ⌃⌘A shows the task waiting on you.
