fn main() {
    // wasm32-unknown-unknown links a 1 MiB stack by default. RaTeX 0.1.13
    // needed about 4 MiB for its deepest accepted input (0.1.14 caps
    // nesting far lower), and a stack overflow traps and leaves the
    // instance unusable, so keep the headroom. Native targets render on a
    // large-stack worker thread instead.
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        println!("cargo:rustc-link-arg-cdylib=-zstack-size={}", 8 << 20);
    }
}
