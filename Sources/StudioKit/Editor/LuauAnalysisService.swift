import Foundation
import Combine

/// Editor-only state, owned by EditorSession. Every request is immutable and carries
/// a unique revision; a closed document or newer request can never accept old output.
final class LuauAnalysisService: ObservableObject {
    @Published private(set) var diagnostics: [String: [LuauDiagnostic]] = [:]
    @Published private(set) var checking: Set<String> = []
    private var snapshots: [String: LuauAnalysisSnapshot] = [:]
    private var revisions: [String: UUID] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private let worker = DispatchQueue(label: "studio.luau.analysis", qos: .userInitiated)
    private let pause: TimeInterval
    private let analyze: (LuauAnalysisSnapshot) -> [LuauDiagnostic]
    init(pause: TimeInterval = 0.3, analyze: @escaping (LuauAnalysisSnapshot) -> [LuauDiagnostic] = LuauAnalyzer.analyze) {
        self.pause = pause
        self.analyze = analyze
    }

    func request(_ snapshot: LuauAnalysisSnapshot, for document: String) {
        precondition(Thread.isMainThread)
        guard snapshots[document] != snapshot else { return }
        pending.removeValue(forKey: document)?.cancel()
        let revision = UUID()
        snapshots[document] = snapshot
        revisions[document] = revision
        diagnostics.removeValue(forKey: document)
        checking.insert(document)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revisions[document] == revision else { return }
            self.pending.removeValue(forKey: document)
            let analyze = self.analyze
            self.worker.async { [weak self] in
                let results = analyze(snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revisions[document] == revision else { return }
                    self.diagnostics[document] = results
                    self.checking.remove(document)
                }
            }
        }
        pending[document] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }
    func forget(_ document: String) {
        precondition(Thread.isMainThread)
        pending.removeValue(forKey: document)?.cancel()
        snapshots.removeValue(forKey: document)
        revisions.removeValue(forKey: document)
        diagnostics.removeValue(forKey: document)
        checking.remove(document)
    }

    deinit { pending.values.forEach { $0.cancel() } }
}
