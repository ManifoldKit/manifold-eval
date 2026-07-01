// swift-tools-version: 6.1
import PackageDescription

// manifold-eval — the independent assurance/eval repo for the ManifoldKit family.
//
// It sits at the TOP of the dependency graph and depends only DOWNWARD: it
// consumes ManifoldKit's published `ManifoldTools` surface (`ConformanceRecord`,
// `MatrixRenderer`) and owns nothing the kit or its companions consume — so there
// is no edge inversion / package cycle (see ManifoldKit
// docs/plans/manifold-eval-repo-v2-override.md §2.1).
//
// The MLX / llama.cpp companions are deliberately NOT linked here: they are
// invoked as SEPARATE PROCESSES whose `ConformanceRecord` JSON this repo collates,
// because `llama_backend_init` is once-per-process and MLX needs serialized
// in-process Metal (§2.2 / ManifoldKit #982). One process linking all backends is
// unbuildable; collation over separate-process records is the design.
let package = Package(
    name: "manifold-eval",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ManifoldEval", targets: ["ManifoldEval"]),
        .executable(name: "manifold-eval", targets: ["manifold-eval"]),
    ],
    dependencies: [
        // EXACT pin, not a range: an assurance repo whose premise is comparability
        // against a specific core binary must not float its own core dependency
        // (the coreCommit guard is meaningless if the consumer drifts). core-bump.yml
        // bumps this exact version on each core release (plan §10). v0.63.0 is the
        // first tag carrying the ConformanceRecord / MatrixRenderer surface P1 uses.
        .package(url: "https://github.com/ManifoldKit/ManifoldKit.git", exact: "0.63.0"),
    ],
    targets: [
        .target(
            name: "ManifoldEval",
            dependencies: [
                .product(name: "ManifoldTools", package: "ManifoldKit"),
                // P2.1 prompt-rendering seam: render messages→prompt ONCE via the
                // PUBLIC `ChatTemplate.format` (ManifoldInference) over the GGUF's
                // embedded chat_template, read via `ModelInfo.chatTemplateRaw`
                // (ManifoldModelCatalog). One renderer of record — see
                // Differential/PromptRendering.swift.
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldModelCatalog", package: "ManifoldKit"),
            ]
        ),
        .executableTarget(
            name: "manifold-eval",
            dependencies: [
                "ManifoldEval",
                .product(name: "ManifoldTools", package: "ManifoldKit"),
            ]
        ),
        .testTarget(
            name: "ManifoldEvalTests",
            dependencies: [
                "ManifoldEval",
                // EmbeddingBackend (from ManifoldContract via ManifoldInference) is needed
                // for the MTEB test double (AlwaysFailEmbedder) and the live embedding tests.
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                // @testable import for DiffCommand's argv-parsing tests — no network I/O
                // is exercised (parseArguments is pure), so this stays hermetic.
                "manifold-eval",
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
