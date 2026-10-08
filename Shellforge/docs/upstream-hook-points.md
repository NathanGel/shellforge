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
| `ModernTests/ShellforgeSidebarLayoutTest.swift` (new) | Calculator tests for the sidebar column | Synchronized test folder: no project entry needed |

## M0: still to verify once Xcode is installed

Written without Xcode. Checked so far: the Shellforge package builds and its tests pass with
swiftly; the layout calculator compiles with clang and passes the sidebar checks in every tab-bar
position. Not yet compiled: the root view, the bridge, the project-file entries, `main.m`.

1. `make setup`, `make paranoid-deps`, `make`: the app builds with the package linked.
2. `ModernTests` pass, including `ShellforgeSidebarLayoutTest`.
3. The built app is named Shellforge, runs beside stock iTerm2, and writes to
   `~/Library/Application Support/Shellforge` and the `Shellforge` preferences suite.
4. Every terminal window shows the sidebar on the left; tabs, splits, the toolbelt and full screen
   still lay out correctly.

Known gap: `constrainToolbeltWidth` limits the toolbelt against the whole window width, not the
width left after the sidebar, so a very narrow window with the toolbelt open can squeeze the
session area.
