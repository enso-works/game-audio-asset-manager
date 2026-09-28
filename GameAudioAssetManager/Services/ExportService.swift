import Foundation
import Observation

/// Runs project exports, both from the export sheet and automatically after saving a sound.
@MainActor
@Observable
final class ExportService {
    private(set) var isRunning = false
    private(set) var progress = (done: 0, total: 0)
    private(set) var lastReport: ProjectExportReport?
    private(set) var lastExportDate: Date?
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var pendingAuto = false

    /// Exports the whole project, or one folder of it, with the project's export options.
    @discardableResult
    func export(scope: URL? = nil, onlyChanged: Bool? = nil) async -> ProjectExportReport? {
        guard let library, !isRunning else { return nil }
        var options = library.config.exportOptions
        if let onlyChanged { options.onlyChanged = onlyChanged }
        isRunning = true
        defer { isRunning = false }
        let destination = library.exportFolder
        let plan = ProjectExporter.plan(library: library, scope: scope, destination: destination)
        let report = await ProjectExporter.run(
            plan,
            to: destination,
            projectName: library.currentProject,
            options: options,
            wholeProject: scope == nil
        ) { [weak self] done, total in
            self?.progress = (done, total)
        }
        library.recordExport(report.succeeded)
        lastReport = report
        lastExportDate = Date()
        return report
    }

    /// Called after a sound is saved; exports changed sounds when the project has auto-export on.
    func autoExportIfEnabled() {
        guard let library, library.config.exportOptions.autoExport else { return }
        if isRunning {
            pendingAuto = true
            return
        }
        Task {
            await export(onlyChanged: true)
            while pendingAuto {
                pendingAuto = false
                await export(onlyChanged: true)
            }
        }
    }
}
