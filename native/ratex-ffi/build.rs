fn main() {
    // wasm32-unknown-unknown links a 1 MiB stack by default, which input
    // nested close to the parser's 512-level limit overflows (about 4 MiB
    // is needed); the resulting trap also leaves the instance unusable.
    // Native targets render on a large-stack worker thread instead.
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        println!("cargo:rustc-link-arg-cdylib=-zstack-size={}", 8 << 20);
    }
}
