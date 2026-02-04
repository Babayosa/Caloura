# Context Chain

Running log of completed tasks. Read this to understand what changed before your current task.

---

## Task 00: Release confidence loop + SwiftPM validation
**Status:** Complete  
**Branch:** task-00-release-confidence-loop  
**Changes:**
- Added SwiftPM support (`Package.swift`, `.gitignore` updates) to enable `swift build` / `swift test`
- Added SwiftLint configuration (`.swiftlint.yml`) to scope linting to repo sources
- Added codex docs (`codex/SCOPE.md`, `codex/CODEMAP.md`, `codex/tasks/task-00.md`)
- Updated `tasks/todo.md` with Task 00 checklist + evidence
- Consolidated existing release-confidence changes (CI guard + scripts + permission/perf updates)

**Decisions Made:**
- Use a SwiftPM library target excluding `Caloura/App/CalouraApp.swift` to avoid duplicate `@main`
- Disable several SwiftLint rules to avoid failing on legacy code until cleanup work

---

<!-- Add new task entries above this line -->
