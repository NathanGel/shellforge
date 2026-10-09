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
| `ModernTests/ShellforgeSidebarLayoutTest.swift` (new) | Calculator tests for the sidebar column | Synchronized test folder: no project entry needed |

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
