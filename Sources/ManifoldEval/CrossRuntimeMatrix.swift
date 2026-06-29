import Foundation
import ManifoldTools

/// Renders a collated record set to the cross-runtime conformance matrix.
///
/// This is the typed replacement for the sweep's hand-assembled `XRUNTIME_MATRIX`
/// step. The matrix body itself is `ManifoldTools.MatrixRenderer` (which already
/// emits a cross-runtime section when ≥2 backends measured the same model) — we
/// add only the collation-diagnostics banner, so a reader sees up front whether
/// the comparison spans a core-commit or tooling boundary that makes it suspect.
public enum CrossRuntimeMatrix {

    public static let defaultTitle = "Cross-Runtime Tool-Calling Conformance Matrix"

    public static func render(_ result: CollationResult, title: String = defaultTitle) -> String {
        var out = ""
        if !result.diagnostics.isEmpty {
            out += "> **Collation diagnostics**\n>\n"
            for diagnostic in result.diagnostics {
                out += "> - **\(diagnostic.severity.rawValue.uppercased())** — \(diagnostic.message)\n"
            }
            out += "\n"
        }
        out += MatrixRenderer.render(result.records, title: title)
        return out
    }
}
