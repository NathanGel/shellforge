import Testing
@testable import ShellforgeCore

@Suite struct FileTreeTests {
    @Test func treeSortsFoldersFirstNaturally() {
        let tree = FileTree.build(["b.txt", "a/z.txt", "folder10/y", "folder2/y", "C.md"])
        #expect(tree.map(\.name) == ["a", "folder2", "folder10", "b.txt", "C.md"])
        #expect(tree.map(\.isFolder) == [true, true, true, false, false])
        #expect(tree[0].children == [FileNode(name: "z.txt", path: "a/z.txt", isFolder: false, children: nil)])
        #expect(tree[3].children == nil)
    }

    @Test func intermediateFoldersAreMadeFromPaths() {
        let tree = FileTree.build(["src/lib/util.ts", "src/app.ts"])
        #expect(tree == [FileNode(name: "src", path: "src", isFolder: true, children: [
            FileNode(name: "lib", path: "src/lib", isFolder: true, children: [
                FileNode(name: "util.ts", path: "src/lib/util.ts", isFolder: false, children: nil),
            ]),
            FileNode(name: "app.ts", path: "src/app.ts", isFolder: false, children: nil),
        ])])
    }

    @Test func aTrailingSlashIsAnEmptyFolder() {
        // git lists an untracked nested repository as `vendor/lib/`.
        #expect(FileTree.build(["vendor/lib/"]) == [FileNode(name: "vendor", path: "vendor", isFolder: true, children: [
            FileNode(name: "lib", path: "vendor/lib", isFolder: true, children: [], nested: .repository),
        ])])
    }

    @Test func aSubmoduleIsMarked() {
        #expect(FileTree.build(["lib/sub/", "README.md"], submodules: ["lib/sub"]) == [
            FileNode(name: "lib", path: "lib", isFolder: true, children: [
                FileNode(name: "sub", path: "lib/sub", isFolder: true, children: [], nested: .submodule),
            ]),
            FileNode(name: "README.md", path: "README.md", isFolder: false, children: nil),
        ])
    }

    @Test func aLargeListingBuildsQuickly() {
        // 100 folders of 50 subfolders of 10 files: 50 000 files.
        var paths: [String] = []
        for a in 0..<100 { for b in 0..<50 { for c in 0..<10 { paths.append("d\(a)/s\(b)/f\(c).txt") } } }
        let tree = FileTree.build(paths)
        #expect(tree.count == 100)
        #expect(tree.allSatisfy { $0.children?.count == 50 })
        func files(_ nodes: [FileNode]) -> Int { nodes.reduce(0) { $0 + ($1.isFolder ? files($1.children ?? []) : 1) } }
        #expect(files(tree) == 50_000)
    }
}
