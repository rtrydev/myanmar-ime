import Foundation

/// Shared resource locator used by both the IMK extension and the container
/// app. The extension looks inside its own bundle; the container app's
/// Diagnostics section needs the same lookup so it can display the lexicon
/// and LM file paths / sizes.
public enum IMEResources {
    /// Look up `name.ext` across the provided bundles in order. Returns the
    /// first URL found, or nil if none of the bundles contain it.
    public static func locate(
        name: String,
        ext: String,
        bundles: [Bundle] = [.main]
    ) -> URL? {
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
