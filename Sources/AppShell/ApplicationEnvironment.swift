import Diagnostics
import MatrixCore
import MediaKit
import Persistence

struct ApplicationEnvironment {
    let diagnostics: DiagnosticsService
    let database: AppDatabase
    let matrixClient: MatrixClientService
    let supportBundleBuilder: SupportBundleBuilder
    let videoPlaybackEngine: any VideoPlaybackEngine

    @MainActor
    static func bootstrap() throws -> ApplicationEnvironment {
        let diagnostics = DiagnosticsService()
        let database = try AppDatabase(diagnostics: diagnostics)
        let matrixClient = MatrixClientService(database: database, diagnostics: diagnostics)
        let supportBundleBuilder = SupportBundleBuilder(diagnostics: diagnostics)
        let videoPlaybackEngine = VLCKitPlaybackEngine(diagnostics: diagnostics)
        return ApplicationEnvironment(
            diagnostics: diagnostics,
            database: database,
            matrixClient: matrixClient,
            supportBundleBuilder: supportBundleBuilder,
            videoPlaybackEngine: videoPlaybackEngine
        )
    }
}
