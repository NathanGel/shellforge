# Changes to iTerm2's own files

Every change Shellforge makes outside `Shellforge/`, so an upstream merge knows where to look. Keep
this list short; new behaviour belongs in the Shellforge package.

| File | Change | Why |
| --- | --- | --- |
| `plists/dev-iTerm2.plist` | Bundle id `io.github.nathangel.shellforge`, name Shellforge, no `SUFeedURL*` keys, automatic update checks off | Installs beside stock iTerm2; never updates from iterm2.com |
| `iTerm2.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER` (4 configurations); the Shellforge package linked into `iTermSwiftPackages` like `WebExtensionsFramework`; `iTermShellforgeSidebar.swift` in `iTerm2SharedARC` | Identity; the sidebar's code |
| `sources/AppKit/main.m` | Without `-suite`, the suite is `Shellforge` | Own preferences, Application Support folder and sockets |
| `sources/TerminalView/iTermLayoutCalculator.{h,m}` | `leftPanelWidth` in, `leftPanelFrame` out; `calculateLayoutWithInputs:` lays out the rest as in a narrower window, then shifts it right | One place makes room for the sidebar in every tab-bar position |
| `sources/TerminalView/iTermRootTerminalView.m` | Creates the sidebar, feeds its width to the calculator, sets its frame in `layoutSubviews` | The sidebar in every terminal window |
| `sources/TerminalView/iTermShellforgeSidebar.swift` (new) | `@objc` bridge to `ShellforgeUI` | Objective-C cannot import the Swift package |
| `sources/TerminalView/iTermRootTerminalView.m` (`tabBarShouldBeVisibleWithAdditionalTabs:`) | No tab bar in a window with the sidebar | The sidebar lists the tabs; the tab bar would show other tasks' |
| `iTerm2.xcodeproj/project.pbxproj` | `ShellforgeCore` linked into `iTermSwiftPackages` | The host builds `TabSnapshot`s and the model |
| `sources/TerminalView/iTermRootTerminalView.{h,m}` | `hasShellforgeSidebar`; no tab bar even while flashing; `#import "PseudoTerminal.h"` before the Swift header | Full screen and the sidebar's window controller |
| `sources/TerminalView/PseudoTerminal.m` (`tabBarShouldBeVisible`, `tabBarShouldBeVisibleEvenWhenOnLoan`, `tabBarShouldBeAccessory`; `windowDecorationSize`) | NO for a window with the sidebar; the sidebar's width counted as a decoration | Native full screen and macOS 26 put the tab bar in the titlebar without asking the root view; fitting the window to its tabs dropped the sidebar's width and shrank the window on every new or closed tab |
| `ModernTests/ShellforgeSidebarLayoutTest.swift` (new) | Calculator tests for the sidebar column | Synchronized test folder: no project entry needed |
| `iTerm2.xcodeproj/project.pbxproj` | Folder reference `Shellforge/daemon/shellforged`, copied by a "Copy shellforged" phase to `Contents/Resources/daemon/` | The app ships its helper; alone in its folder, which is the daemon's PYTHONPATH, away from iTerm2's own scripts at the top of Resources |
| `sources/AppKit/iTermApplicationDelegate.m` (`applicationDidFinishLaunching:`) | `[iTermShellforgeSidebar startHelper]` | Starts shellforged and the one-second report tick; both stop at `iTermApplicationWillTerminate` |
| `sources/TerminalView/iTermShellforgeSidebar.swift` | The app's `DaemonLink`; every session reported; the sidebar fed its statuses; a tab change sends at once | Status dots from the agents' hooks |
| `ModernTests/ShellforgeReportsTest.swift` (new) | iTerm2's names for the session variables Shellforge reads | ModernTests cannot link ShellforgeCore, so the reading itself is tested in the package |

## M0: verified on 9 October 2026

Built with Xcode 27.0 (`make paranoid-deps` without the `sfsymbolenum` step, whose output is
committed and which needs the SF Symbols app; then `make Development`).

1. The app builds with the package linked; `ShellforgeUI` is in `iTermSwiftPackages.framework`.
2. `ShellforgeSidebarLayoutTest` (4) and iTerm2's `iTermLayoutCalculatorTest` (31) pass; the
   package's 40 tests pass with swiftly.
3. The built app is `io.github.nathangel.shellforge`, named Shellforge, without an update feed. It
   runs beside stock iTerm2 and writes `~/Library/Application Support/Shellforge` and the
   `Shellforge` preferences suite.
4. A terminal window shows the sidebar on the left and the session to its right.

Known gap: `constrainToolbeltWidth` limits the toolbelt against the whole window width, not the
width left after the sidebar, so a very narrow window with the toolbelt open can squeeze the
session area.

## M1a: verified on 9 October 2026

In the running Development build, driven through the Accessibility API, against a scratch repository:

| Check | Result |
| --- | --- |
| Add a repository with `+` | Passed: listed and saved in `workspace.json` |
| Add a folder outside git | Passed: the sidebar shows git's "fatal: not a git repository" |
| New task | Passed: `.worktrees/try-shellforge` on branch `try-shellforge`, `.worktrees/` in `info/exclude`; its tab opens there, tagged with the task's id; no tab bar with two tabs |
| Click another task | Passed: the window shows that task's tab |
| Cmd-Shift-] | Passed: the sidebar's selection follows the tab shown |
| Close a task's only tab, click the task | Passed: the task stays listed; a click opens a new tab in its worktree |
| Native full screen | Passed: no tab bar, two tabs open |
| Two windows | Passed: both show the same projects and tasks |
| Window width when tabs open and close | Failed first (each refit dropped the sidebar's 240 pt until the window was 197 pt wide); fixed in `windowDecorationSize`, then 810 pt through two open/close rounds |
| Quit and relaunch | Not shown: macOS's "close windows when quitting" setting meant no windows were restored. Session variables are saved with each session in iTerm2's arrangement code (`PTYSession.m`), so tagged tabs should come back under their tasks when restoration is on. |

Seen in passing: a SwiftUI task row's accessibility press does not select it (a mouse click does), and the project header's ⊕ is only reachable as a named accessibility action.
