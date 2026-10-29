# Private validation and owner-operated publication

New work is pushed to private git.manymath.com. The Gitea workflow validates
Rust (native and cross-target checks), WASM/JavaScript, Dart/Flutter, and Linux,
Android and web example builds using provisioned tools. It uploads nothing to
GitHub or registries. Native macOS/iOS/Windows runtime validation still requires
those platforms; cross-target cargo checks do not establish runtime support.

The public precompile template is manual-only, restricted to ManyMath/ratex on
github.com, and validates that the supplied signing key matches the committed
verification key before creating a release. Its signing preflight regressions
use test-only material. No production signing secret is needed for private CI.

The owner must later mirror the reviewed immutable revision, inspect and test
GitHub CI, confirm signing-key custody and target coverage, and deliberately run
public publication. The template is prepared, not verified on GitHub. No private
Gitea URL is a public download endpoint. The bundled ratex_ffi crate is internal
and cannot be uploaded to crates.io.
