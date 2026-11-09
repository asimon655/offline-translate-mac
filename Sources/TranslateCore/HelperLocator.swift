import Foundation

/// Finds the Python that runs `offline_translate.helper`.
///
/// Order: `OFFLINE_TRANSLATE_PYTHON` env var, the Python bundled in the app (`Contents/Resources/helper`), then the
/// `OTDevPython` Info.plist key that `scripts/build-app.sh --dev` writes (a development venv).
public enum HelperLocator {
    public static let bundledPythonPath = "helper/bin/python3"

    public static func python(environment: [String: String] = ProcessInfo.processInfo.environment,
                              resources: URL? = Bundle.main.resourceURL,
                              info: [String: Any]? = Bundle.main.infoDictionary,
                              fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let env = environment["OFFLINE_TRANSLATE_PYTHON"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let resources { candidates.append(resources.appendingPathComponent(bundledPythonPath)) }
        if let dev = info?["OTDevPython"] as? String, !dev.isEmpty {
            candidates.append(URL(fileURLWithPath: (dev as NSString).expandingTildeInPath))
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Default folder for language packs: ~/Library/Application Support/OfflineTranslate/models
    public static var defaultModelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineTranslate/models", isDirectory: true)
    }

    public static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineTranslate", isDirectory: true)
    }

    public static func launch(python: URL, modelsDir: URL, idleUnloadSeconds: Int = 600,
                              cacheDir: URL = HelperLocator.cacheDir) -> HelperLaunch {
        // -s: ignore the user's site-packages. Bytecode goes to Caches, never into the (signed) app bundle.
        HelperLaunch(executable: python, arguments: [
            "-s", "-X", "pycache_prefix=\(cacheDir.appendingPathComponent("pycache").path)",
            "-m", "offline_translate.helper",
            "--models", modelsDir.path,
            "--idle-unload", String(idleUnloadSeconds),
        ], environment: ["PYTHONIOENCODING": "utf-8", "LANG": "en_US.UTF-8",
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()])
    }
}
