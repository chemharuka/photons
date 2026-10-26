import Foundation

/// The revision this binary was **built** from, read back from the bundle.
///
/// `scripts/bundle-app.sh` stamps `PhotonsGitRevision` into `Info.plist` at bundle time (after the
/// compile, straight from `git rev-parse --short=7 HEAD`, with `-dirty` when the tree had uncommitted
/// changes). It exists because the answer to "did the merge I asked for actually reach the app I am
/// looking at?" must be readable in the app itself, not inferred from a commit list.
///
/// Outside a bundle (`swift run photonsctl`, unit tests, a bare executable) there is no `Info.plist`,
/// so the value is `"dev"` — and that is honest: nothing was stamped.
public enum BuildStamp {

    /// Short revision, e.g. `4a7c34b` or `4a7c34b-dirty`; `dev` when not bundled.
    public static var revision: String {
        guard let raw = Bundle.main.infoDictionary?["PhotonsGitRevision"] as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "dev" }
        return raw
    }

    /// `photons-demo 4a7c34b` — what the top-right corner shows.
    public static func label(libraryName: String?) -> String {
        let name = libraryName ?? "未打开库"
        return "\(name) \(revision)"
    }
}
