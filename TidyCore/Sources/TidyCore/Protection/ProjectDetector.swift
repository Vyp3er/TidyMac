import Foundation

/// Detects project roots. A project folder is an indivisible unit: nothing inside is ever
/// touched, and by default the folder itself does not move either.
public struct ProjectDetector: Sendable {
    public static let markerFiles: Set<String> = [
        "package.json", "Cargo.toml", "CMakeLists.txt", "CMakePresets.json", "Makefile", "makefile", "GNUmakefile",
        "pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile", "poetry.lock", "environment.yml",
        "pyvenv.cfg", "Package.swift", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "gradlew", "Gemfile", "Rakefile", "composer.json", "pubspec.yaml", "mix.exs",
        "stack.yaml", "deno.json", "tsconfig.json", "meson.build", "configure.ac", "WORKSPACE", "MODULE.bazel",
        "BUILD.bazel", "build.sbt", "project.clj", "deps.edn", "flake.nix", "default.nix", "shell.nix",
        "Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yaml", "Vagrantfile", "Podfile",
        "Cartfile", "Project.swift", "Tuist.swift", "project.yml", ".project", "renv.lock", "conanfile.txt",
        "vcpkg.json", "platformio.ini", "Justfile", "justfile", "Taskfile.yml", "build.xml", "Snakefile",
        "latexmkrc", ".latexmkrc", ".gitignore", ".gitmodules", ".editorconfig", ".clang-format", "angular.json",
        "nuxt.config.js", "next.config.js", "vite.config.ts", "vite.config.js", "webpack.config.js",
    ]

    public static let markerDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".bzr", "_darcs", ".fossil", ".vscode", ".idea", ".fleet", ".zed", "node_modules",
        "venv", ".venv", "__pycache__", ".ipynb_checkpoints", ".terraform", ".devcontainer", ".github", ".gitlab",
        ".gradle", ".mvn", ".cargo", ".swiftpm", ".build", "DerivedData", ".next", ".nuxt", ".dart_tool",
        ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".bundle", ".circleci",
    ]

    /// Extensions of files or folders that mark a project (e.g. MyApp.xcodeproj).
    public static let markerExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "playground", "swiftpm", "sln", "csproj", "fsproj", "vbproj", "vcxproj",
        "uproject", "kicad_pro", "rproj", "code-workspace", "sublime-project", "cabal", "gemspec", "nimble",
        "jucer", "pro", "qbs", "lpr", "dproj", "iml", "ipr", "unitypackage", "godot", "pbxproj",
    ]

    public var extraMarkers: Set<String>

    public init(extraMarkers: [String] = []) {
        self.extraMarkers = Set(extraMarkers.filter { !$0.isEmpty })
    }

    /// Returns the marker that identifies `folderName` with the given entries as a project, or nil.
    public func marker(folderName: String, entries: [String]) -> String? {
        var texCount = 0
        var hasTexSupport = false
        var hasAssets = false
        var hasProjectSettings = false
        for entry in entries {
            if Self.markerFiles.contains(entry) || Self.markerDirectories.contains(entry) || extraMarkers.contains(entry) {
                return entry
            }
            let lower = entry.lowercased()
            let ext = FileNameTools.split(lower).ext
            if !ext.isEmpty, Self.markerExtensions.contains(ext) { return entry }
            switch ext {
            case "tex": texCount += 1
            case "bib", "cls", "sty", "bst", "bbl", "synctex": hasTexSupport = true
            default: break
            }
            if entry == "Assets" { hasAssets = true }
            if entry == "ProjectSettings" { hasProjectSettings = true }
            // Arduino sketch: Foo/Foo.ino
            if ext == "ino", FileNameTools.split(entry).base == folderName { return entry }
            // Python virtualenv layout
            if entry == "bin" && entries.contains("pyvenv.cfg") { return "pyvenv.cfg" }
        }
        if texCount >= 2 { return "mehrere .tex-Dateien" }
        if texCount >= 1 && hasTexSupport { return "LaTeX-Projekt" }
        if hasAssets && hasProjectSettings { return "Unity-Projekt" }
        return nil
    }
}
