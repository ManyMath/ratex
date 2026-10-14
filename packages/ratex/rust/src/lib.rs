//! Portable C ABI around the RaTeX math typesetting engine.
//!
//! One crate, two targets, one ABI:
//! - native (cdylib/staticlib) called from Dart over `dart:ffi`;
//! - wasm32-unknown-unknown called from Dart over JS interop
//!   (`WebAssembly.instantiate`), with no wasm-bindgen glue.
//!
//! To stay portable across both, the ABI avoids C strings and structs at the
//! boundary entirely:
//! - strings cross as `(*const u8, usize)` UTF-8 spans (no NUL terminator);
//! - every fallible call returns an opaque `RatexBuffer` handle that carries
//!   both the payload bytes and a status code, freed with
//!   [`ratex_buffer_free`];
//! - callers stage input bytes with [`ratex_alloc`]/[`ratex_free`] (required
//!   on wasm, where the host cannot address linear memory any other way; on
//!   native, callers may use any allocation they like instead).
//!
//! Two render entry points share one options payload (UTF-8 JSON, camelCase,
//! all fields optional, see [`RenderOptions`]):
//! - [`ratex_render_display_list`] -> DisplayList JSON, protocol `version: 1`,
//!   byte-compatible with upstream RaTeX's `ratex-ffi`/`ratex-wasm` output;
//! - [`ratex_render_svg`] -> an SVG document; with `embedGlyphs: true`
//!   (the default here) glyph outlines are inlined from the compiled-in KaTeX
//!   fonts, so math renders with no fonts installed or served. Characters
//!   the KaTeX fonts lack (CJK, emoji in `\text{}`) are outlined from a
//!   system font found at render time on native targets (overridable with
//!   the `RATEX_UNICODE_FONT` environment variable) and become `<text>`
//!   elements that rely on the viewer's fonts on wasm32.
//!
//! On error the buffer's status is non-zero and the payload is a small JSON
//! object `{"message": string, "start": number|null, "end": number|null}`
//! with byte offsets into the input, for editor diagnostics.

use ratex_layout::{layout, to_display_list, LayoutOptions};
use ratex_parser::Parser;
use ratex_types::color::Color;
use ratex_types::display_item::{DisplayItem, DisplayList};
use ratex_types::math_style::MathStyle;
use ratex_types::path_command::PathCommand;

/// Buffer status: success.
pub const RATEX_STATUS_OK: i32 = 0;
/// Buffer status: LaTeX parse error (payload has `message`/`start`/`end`).
pub const RATEX_STATUS_PARSE_ERROR: i32 = 1;
/// Buffer status: invalid arguments (bad UTF-8, bad options JSON, bad color).
pub const RATEX_STATUS_INVALID_INPUT: i32 = 2;
/// Buffer status: internal error (serialization failure, panic).
pub const RATEX_STATUS_INTERNAL_ERROR: i32 = 3;

/// Opaque result buffer handed across the ABI as a raw pointer.
///
/// Rust allocates it, the caller reads it through the `ratex_buffer_*`
/// accessors and must release it with exactly one [`ratex_buffer_free`].
pub struct RatexBuffer {
    data: Vec<u8>,
    status: i32,
}

/// Render options, deserialized from the optional UTF-8 JSON payload.
///
/// Unknown fields are ignored so older libraries accept newer callers.
#[derive(Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RenderOptions {
    /// `true` renders in display style (`$$...$$`), `false` in text/inline
    /// style (`$...$`).
    pub display_mode: bool,
    /// Foreground color: a named color, `#rgb`, `#rgba`, `#rrggbb`,
    /// `#rrggbbaa`, or `[MODEL]value` (see RaTeX's `Color::parse`).
    pub color: Option<String>,
    /// SVG only: user units per em.
    pub font_size: f64,
    /// SVG only: padding on all sides, in user units.
    pub padding: f64,
    /// SVG only: stroke width for unfilled paths, in user units.
    pub stroke_width: f64,
    /// SVG only: `true` inlines glyph outlines from the embedded KaTeX fonts
    /// (self-contained output for everything the KaTeX fonts cover, see the
    /// crate docs); `false` emits `<text>` elements that need the KaTeX
    /// webfonts at display time.
    pub embed_glyphs: bool,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            display_mode: true,
            color: None,
            font_size: 40.0,
            padding: 10.0,
            stroke_width: 1.5,
            embed_glyphs: true,
        }
    }
}

static VERSION: &str = env!("CARGO_PKG_VERSION");

/// Pointer to the crate version as UTF-8 bytes (not NUL-terminated); the
/// length comes from [`ratex_version_len`]. Doubles as a stable symbol for
/// `-force_load` checks on Apple platforms.
#[no_mangle]
pub extern "C" fn ratex_version_ptr() -> *const u8 {
    VERSION.as_ptr()
}

/// Length of the [`ratex_version_ptr`] bytes.
#[no_mangle]
pub extern "C" fn ratex_version_len() -> usize {
    VERSION.len()
}

/// Allocates `len` bytes and returns the pointer (null when `len == 0` or on
/// allocation failure, callers must check). Callers stage input strings
/// here, then release with [`ratex_free`] using the same length.
#[no_mangle]
pub extern "C" fn ratex_alloc(len: usize) -> *mut u8 {
    // The raw allocator rather than a Vec: failure must surface as the
    // documented null return, not abort the host process (or trap the wasm
    // instance) through handle_alloc_error, and ratex_free must deallocate
    // with exactly this layout.
    match staging_layout(len) {
        Some(layout) => unsafe { std::alloc::alloc(layout) },
        None => core::ptr::null_mut(),
    }
}

/// Layout of a `ratex_alloc(len)` block; `None` for zero or oversized
/// lengths.
fn staging_layout(len: usize) -> Option<std::alloc::Layout> {
    if len == 0 {
        return None;
    }
    std::alloc::Layout::array::<u8>(len).ok()
}

/// Releases memory obtained from [`ratex_alloc`]. `len` must be the length
/// passed to `ratex_alloc`; a null `ptr` is a no-op.
///
/// # Safety
/// `ptr` must come from `ratex_alloc(len)` and not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn ratex_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    if let Some(layout) = staging_layout(len) {
        std::alloc::dealloc(ptr, layout);
    }
}

/// Parses `input` (UTF-8 LaTeX math, `input_len` bytes) and lays it out,
/// returning a buffer whose payload is DisplayList JSON (`version: 1`).
/// `opts`/`opts_len` may be null/0 for defaults, else UTF-8 JSON matching
/// [`RenderOptions`]. Never returns null; check [`ratex_buffer_status`].
///
/// # Safety
/// `input` must point to `input_len` readable bytes (and `opts` to
/// `opts_len`) for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn ratex_render_display_list(
    input: *const u8,
    input_len: usize,
    opts: *const u8,
    opts_len: usize,
) -> *mut RatexBuffer {
    render_entry(input, input_len, opts, opts_len, render_display_list_impl)
}

/// Like [`ratex_render_display_list`], but the payload is an SVG document.
///
/// # Safety
/// Same contract as [`ratex_render_display_list`].
#[no_mangle]
pub unsafe extern "C" fn ratex_render_svg(
    input: *const u8,
    input_len: usize,
    opts: *const u8,
    opts_len: usize,
) -> *mut RatexBuffer {
    render_entry(input, input_len, opts, opts_len, render_svg_impl)
}

/// Status code of a result buffer (`RATEX_STATUS_*`); `INTERNAL_ERROR` for a
/// null handle.
///
/// # Safety
/// `buf` must be null or a live handle from a render call.
#[no_mangle]
pub unsafe extern "C" fn ratex_buffer_status(buf: *const RatexBuffer) -> i32 {
    match buf.as_ref() {
        Some(b) => b.status,
        None => RATEX_STATUS_INTERNAL_ERROR,
    }
}

/// Borrowed pointer to the buffer's payload bytes, valid until
/// [`ratex_buffer_free`]. Null for a null handle.
///
/// # Safety
/// `buf` must be null or a live handle from a render call.
#[no_mangle]
pub unsafe extern "C" fn ratex_buffer_data(buf: *const RatexBuffer) -> *const u8 {
    match buf.as_ref() {
        Some(b) => b.data.as_ptr(),
        None => core::ptr::null(),
    }
}

/// Length in bytes of the buffer's payload. 0 for a null handle.
///
/// # Safety
/// `buf` must be null or a live handle from a render call.
#[no_mangle]
pub unsafe extern "C" fn ratex_buffer_len(buf: *const RatexBuffer) -> usize {
    match buf.as_ref() {
        Some(b) => b.data.len(),
        None => 0,
    }
}

/// Frees a result buffer. Null-safe.
///
/// # Safety
/// `buf` must be null or a live handle from a render call; it must not be
/// used (or freed again) afterwards.
#[no_mangle]
pub unsafe extern "C" fn ratex_buffer_free(buf: *mut RatexBuffer) {
    if !buf.is_null() {
        drop(Box::from_raw(buf));
    }
}

type RenderFn = fn(&str, &RenderOptions) -> Result<Vec<u8>, RatexBuffer>;

unsafe fn render_entry(
    input: *const u8,
    input_len: usize,
    opts: *const u8,
    opts_len: usize,
    render: RenderFn,
) -> *mut RatexBuffer {
    let buffer = catch_panic(|| {
        let latex = match read_utf8(input, input_len, "input") {
            Ok(s) => s,
            Err(b) => return b,
        };
        let options = match read_options(opts, opts_len) {
            Ok(o) => o,
            Err(b) => return b,
        };
        match run_render(render, latex, &options) {
            Ok(data) => RatexBuffer {
                data,
                status: RATEX_STATUS_OK,
            },
            Err(b) => b,
        }
    });
    Box::into_raw(Box::new(buffer))
}

/// Stack size of the native render worker threads.
///
/// Parsing, macro expansion, and layout are all recursive. RaTeX 0.1.14
/// caps input nesting at 32 levels (0.1.13 allowed 512, which needed about
/// 4 MiB of stack in release builds and 16 MiB in debug builds), but host
/// threads can be small (Flutter's UI thread, Dart isolate threads, 1 MiB
/// on some platforms) and a stack overflow aborts the whole process
/// instead of unwinding, so renders keep generous headroom of their own.
/// The size is a virtual reservation that costs nothing until touched; it
/// is smaller on 32-bit targets, where address space is scarce and frames
/// are smaller.
#[cfg(not(target_family = "wasm"))]
const RENDER_STACK_SIZE: usize = if cfg!(target_pointer_width = "64") {
    64 << 20
} else {
    16 << 20
};

/// Runs `render` on a large-stack worker thread (see [`RENDER_STACK_SIZE`])
/// so deeply nested input cannot overflow the caller's stack, falling back
/// to the calling thread if no worker can be started. Engine panics are
/// re-raised here for [`catch_panic`]. On wasm32 there are no threads; the
/// module's own stack size is raised at link time instead (see `build.rs`).
fn run_render(
    render: RenderFn,
    latex: &str,
    options: &RenderOptions,
) -> Result<Vec<u8>, RatexBuffer> {
    #[cfg(not(target_family = "wasm"))]
    if let Some(outcome) = worker::run(render, latex, options) {
        return outcome.unwrap_or_else(|panic| std::panic::resume_unwind(panic));
    }
    render(latex, options)
}

#[cfg(not(target_family = "wasm"))]
mod worker {
    //! One long-lived render thread per calling thread: spawning a thread
    //! per call would roughly triple the cost of a small formula.

    use super::{RatexBuffer, RenderFn, RenderOptions, RENDER_STACK_SIZE};
    use std::sync::mpsc::{channel, Receiver, Sender};
    use std::thread::Result as Outcome;

    type Rendered = Result<Vec<u8>, RatexBuffer>;
    type Job = (RenderFn, String, RenderOptions);

    struct Worker {
        jobs: Sender<Job>,
        results: Receiver<Outcome<Rendered>>,
    }

    thread_local! {
        // Dropped when the calling thread exits, which closes the job
        // channel and ends the worker.
        static WORKER: Option<Worker> = spawn();
    }

    fn spawn() -> Option<Worker> {
        let (jobs, job_rx) = channel::<Job>();
        let (result_tx, results) = channel();
        std::thread::Builder::new()
            .name("ratex-render".into())
            .stack_size(RENDER_STACK_SIZE)
            .spawn(move || {
                for (render, latex, options) in job_rx {
                    let outcome = std::panic::catch_unwind(|| render(&latex, &options));
                    if result_tx.send(outcome).is_err() {
                        break;
                    }
                }
            })
            .ok()?;
        Some(Worker { jobs, results })
    }

    /// `None` when no worker is available (it could not be spawned, or the
    /// calling thread is being torn down).
    pub(super) fn run(
        render: RenderFn,
        latex: &str,
        options: &RenderOptions,
    ) -> Option<Outcome<Rendered>> {
        WORKER
            .try_with(|worker| {
                let worker = worker.as_ref()?;
                worker
                    .jobs
                    .send((render, latex.to_owned(), options.clone()))
                    .ok()?;
                worker.results.recv().ok()
            })
            .ok()
            .flatten()
    }
}

/// On native targets a panic in the engine must not unwind across the ABI;
/// turn it into an `INTERNAL_ERROR` buffer. (On wasm32 panics abort/trap
/// before this matters, and `catch_unwind` is a pass-through there.)
fn catch_panic(f: impl FnOnce() -> RatexBuffer + std::panic::UnwindSafe) -> RatexBuffer {
    std::panic::catch_unwind(f).unwrap_or_else(|_| {
        error_buffer(
            RATEX_STATUS_INTERNAL_ERROR,
            "internal panic during render",
            None,
        )
    })
}

unsafe fn read_utf8<'a>(ptr: *const u8, len: usize, what: &str) -> Result<&'a str, RatexBuffer> {
    if len == 0 {
        return Ok("");
    }
    if ptr.is_null() {
        return Err(error_buffer(
            RATEX_STATUS_INVALID_INPUT,
            &format!("{what} pointer is null but length is {len}"),
            None,
        ));
    }
    core::str::from_utf8(core::slice::from_raw_parts(ptr, len)).map_err(|e| {
        error_buffer(
            RATEX_STATUS_INVALID_INPUT,
            &format!("{what} is not valid UTF-8: {e}"),
            None,
        )
    })
}

unsafe fn read_options(ptr: *const u8, len: usize) -> Result<RenderOptions, RatexBuffer> {
    let json = read_utf8(ptr, len, "options")?;
    if json.trim().is_empty() {
        return Ok(RenderOptions::default());
    }
    serde_json::from_str(json).map_err(|e| {
        error_buffer(
            RATEX_STATUS_INVALID_INPUT,
            &format!("options JSON is invalid: {e}"),
            None,
        )
    })
}

fn layout_display_list(latex: &str, options: &RenderOptions) -> Result<DisplayList, RatexBuffer> {
    let source = strip_outer_math_delimiters(latex);
    let offset = source.as_ptr() as usize - latex.as_ptr() as usize;
    let nodes = Parser::new(source).parse().map_err(|e| {
        error_buffer(
            RATEX_STATUS_PARSE_ERROR,
            &e.message,
            e.loc
                .as_ref()
                .and_then(|l| input_span(source, offset, l.start, l.end)),
        )
    })?;
    let style = if options.display_mode {
        MathStyle::Display
    } else {
        MathStyle::Text
    };
    let mut layout_options = LayoutOptions::default().with_style(style);
    if let Some(spec) = &options.color {
        let color = parse_finite_color(spec).ok_or_else(|| {
            error_buffer(
                RATEX_STATUS_INVALID_INPUT,
                &format!(
                    "invalid color: '{spec}'. Expected a named color, #rgb, #rgba, \
                     #rrggbb, #rrggbbaa, or [MODEL]value"
                ),
                None,
            )
        })?;
        layout_options = layout_options.with_color(color);
    }
    let layout_box = layout(&nodes, &layout_options);
    let mut display_list = to_display_list(&layout_box);
    sanitize_display_list(&mut display_list);
    Ok(display_list)
}

/// Same trimming as `ratex_parser::parse` (surrounding whitespace, then one
/// pair of `$$...$$` or `$...$`), done here so parse-error spans, which are
/// relative to the stripped text, can be mapped back onto the input.
fn strip_outer_math_delimiters(input: &str) -> &str {
    let s = input.trim();
    if s.len() >= 4 && s.starts_with("$$") && s.ends_with("$$") {
        return s[2..s.len() - 2].trim();
    }
    if s.len() >= 2 && s.starts_with('$') && s.ends_with('$') {
        return s[1..s.len() - 1].trim();
    }
    s
}

/// Maps a parser span over `source` (which starts `offset` bytes into the
/// input) to input byte offsets. Spans that do not fit `source` are dropped:
/// errors raised inside a macro expansion point into the macro's
/// definition, not the input.
fn input_span(source: &str, offset: usize, start: usize, end: usize) -> Option<(usize, usize)> {
    (start <= end
        && end <= source.len()
        && source.is_char_boundary(start)
        && source.is_char_boundary(end))
    .then_some((offset + start, offset + end))
}

/// `Color::parse` accepts any parseable float, including `nan`/`inf`
/// (e.g. `[gray]nan`, `[rgb]1e400,0,0`); reject those here so the payload
/// keeps the protocol's all-finite-numbers guarantee.
fn parse_finite_color(spec: &str) -> Option<Color> {
    let color = Color::parse(spec)?;
    [color.r, color.g, color.b, color.a]
        .iter()
        .all(|c| c.is_finite())
        .then_some(color)
}

fn render_display_list_impl(latex: &str, options: &RenderOptions) -> Result<Vec<u8>, RatexBuffer> {
    let display_list = layout_display_list(latex, options)?;
    #[derive(serde::Serialize)]
    struct VersionedDisplayList<'a> {
        version: u32,
        #[serde(flatten)]
        display_list: &'a DisplayList,
    }
    serde_json::to_vec(&VersionedDisplayList {
        version: 1,
        display_list: &display_list,
    })
    .map_err(|e| {
        error_buffer(
            RATEX_STATUS_INTERNAL_ERROR,
            &format!("failed to serialize display list: {e}"),
            None,
        )
    })
}

fn render_svg_impl(latex: &str, options: &RenderOptions) -> Result<Vec<u8>, RatexBuffer> {
    let display_list = layout_display_list(latex, options)?;
    let svg_options = ratex_svg::SvgOptions {
        font_size: options.font_size,
        padding: options.padding,
        stroke_width: options.stroke_width,
        embed_glyphs: options.embed_glyphs,
        ..Default::default()
    };
    Ok(ratex_svg::render_to_svg(&display_list, &svg_options).into_bytes())
}

fn error_buffer(status: i32, message: &str, span: Option<(usize, usize)>) -> RatexBuffer {
    #[derive(serde::Serialize)]
    struct ErrorPayload<'a> {
        message: &'a str,
        start: Option<usize>,
        end: Option<usize>,
    }
    let payload = ErrorPayload {
        message,
        start: span.map(|s| s.0),
        end: span.map(|s| s.1),
    };
    let data = serde_json::to_vec(&payload).unwrap_or_else(|_| {
        br#"{"message":"unrepresentable error","start":null,"end":null}"#.to_vec()
    });
    RatexBuffer { data, status }
}

/// serde_json's default f64 serializer emits `null` for NaN/Infinity, which
/// would break the protocol's numbers-are-always-finite rule; clamp
/// non-finite values in place first (the geometry walk mirrors upstream
/// `ratex-wasm`; colors are clamped too, since layout can propagate
/// non-finite components smuggled in through `\color` arguments).
fn sanitize_display_list(dl: &mut DisplayList) {
    sanitize_f64(&mut dl.width);
    sanitize_f64(&mut dl.height);
    sanitize_f64(&mut dl.depth);
    for item in &mut dl.items {
        match item {
            DisplayItem::GlyphPath {
                x, y, scale, color, ..
            } => {
                sanitize_f64(x);
                sanitize_f64(y);
                sanitize_f64(scale);
                sanitize_color(color);
            }
            DisplayItem::Line {
                x,
                y,
                width,
                thickness,
                color,
                ..
            } => {
                sanitize_f64(x);
                sanitize_f64(y);
                sanitize_f64(width);
                sanitize_f64(thickness);
                sanitize_color(color);
            }
            DisplayItem::Rect {
                x,
                y,
                width,
                height,
                color,
            } => {
                sanitize_f64(x);
                sanitize_f64(y);
                sanitize_f64(width);
                sanitize_f64(height);
                sanitize_color(color);
            }
            DisplayItem::Path {
                x,
                y,
                commands,
                color,
                ..
            } => {
                sanitize_f64(x);
                sanitize_f64(y);
                sanitize_color(color);
                for cmd in commands {
                    sanitize_path_command(cmd);
                }
            }
        }
    }
}

fn sanitize_color(color: &mut Color) {
    for channel in [&mut color.r, &mut color.g, &mut color.b] {
        if !channel.is_finite() {
            *channel = 0.0;
        }
    }
    if !color.a.is_finite() {
        color.a = 1.0;
    }
}

fn sanitize_path_command(cmd: &mut PathCommand) {
    match cmd {
        PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => {
            sanitize_f64(x);
            sanitize_f64(y);
        }
        PathCommand::CubicTo {
            x1,
            y1,
            x2,
            y2,
            x,
            y,
        } => {
            sanitize_f64(x1);
            sanitize_f64(y1);
            sanitize_f64(x2);
            sanitize_f64(y2);
            sanitize_f64(x);
            sanitize_f64(y);
        }
        PathCommand::QuadTo { x1, y1, x, y } => {
            sanitize_f64(x1);
            sanitize_f64(y1);
            sanitize_f64(x);
            sanitize_f64(y);
        }
        PathCommand::Close => {}
    }
}

#[inline]
fn sanitize_f64(v: &mut f64) {
    if !v.is_finite() {
        *v = 0.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drives the exported ABI exactly as a foreign caller would.
    unsafe fn render(
        f: unsafe extern "C" fn(*const u8, usize, *const u8, usize) -> *mut RatexBuffer,
        latex: &str,
        opts: &str,
    ) -> (i32, String) {
        let input = ratex_alloc(latex.len());
        core::ptr::copy_nonoverlapping(latex.as_ptr(), input, latex.len());
        let opts_ptr = if opts.is_empty() {
            core::ptr::null_mut()
        } else {
            let p = ratex_alloc(opts.len());
            core::ptr::copy_nonoverlapping(opts.as_ptr(), p, opts.len());
            p
        };
        let buf = f(input, latex.len(), opts_ptr, opts.len());
        ratex_free(input, latex.len());
        ratex_free(opts_ptr, opts.len());
        let status = ratex_buffer_status(buf);
        let data = core::slice::from_raw_parts(ratex_buffer_data(buf), ratex_buffer_len(buf));
        let payload = String::from_utf8(data.to_vec()).unwrap();
        ratex_buffer_free(buf);
        (status, payload)
    }

    #[test]
    fn version_is_exported() {
        let bytes =
            unsafe { core::slice::from_raw_parts(ratex_version_ptr(), ratex_version_len()) };
        assert_eq!(
            core::str::from_utf8(bytes).unwrap(),
            env!("CARGO_PKG_VERSION")
        );
    }

    #[test]
    fn display_list_roundtrip_via_c_abi() {
        let (status, json) =
            unsafe { render(ratex_render_display_list, r"\frac{a}{b} + \sqrt{x^2}", "") };
        assert_eq!(status, RATEX_STATUS_OK);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["version"], 1);
        assert!(value["width"].as_f64().unwrap() > 0.0);
        assert!(!value["items"].as_array().unwrap().is_empty());
    }

    #[test]
    fn inline_style_lays_out_smaller_than_display() {
        let (_, display) = unsafe {
            render(
                ratex_render_display_list,
                r"\sum_{i=0}^{n} i",
                r#"{"displayMode":true}"#,
            )
        };
        let (_, inline) = unsafe {
            render(
                ratex_render_display_list,
                r"\sum_{i=0}^{n} i",
                r#"{"displayMode":false}"#,
            )
        };
        let dh: serde_json::Value = serde_json::from_str(&display).unwrap();
        let ih: serde_json::Value = serde_json::from_str(&inline).unwrap();
        assert!(
            dh["height"].as_f64().unwrap() + dh["depth"].as_f64().unwrap()
                > ih["height"].as_f64().unwrap() + ih["depth"].as_f64().unwrap()
        );
    }

    #[test]
    fn svg_is_self_contained() {
        let (status, svg) =
            unsafe { render(ratex_render_svg, r"E = mc^2", r#"{"embedGlyphs":true}"#) };
        assert_eq!(status, RATEX_STATUS_OK);
        assert!(svg.starts_with("<svg") || svg.starts_with("<?xml"));
        // Outlined glyphs mean no <text> nodes depending on external fonts.
        assert!(!svg.contains("<text"));
    }

    #[test]
    fn parse_error_reports_span() {
        let (status, payload) = unsafe { render(ratex_render_display_list, r"\frac{a}{", "") };
        assert_eq!(status, RATEX_STATUS_PARSE_ERROR);
        let err: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert!(!err["message"].as_str().unwrap().is_empty());
    }

    fn parse_error_span(latex: &str) -> (Option<u64>, Option<u64>) {
        let (status, payload) = unsafe { render(ratex_render_display_list, latex, "") };
        assert_eq!(status, RATEX_STATUS_PARSE_ERROR, "{latex}: {payload}");
        let err: serde_json::Value = serde_json::from_str(&payload).unwrap();
        (err["start"].as_u64(), err["end"].as_u64())
    }

    #[test]
    fn parse_error_spans_are_offsets_into_the_input() {
        let plain = r"\frac{a}{";
        assert_eq!(parse_error_span(plain), (Some(9), Some(9)));
        // Stripped whitespace and math delimiters must not shift the span.
        assert_eq!(
            parse_error_span(&format!("  {plain}")),
            (Some(11), Some(11))
        );
        assert_eq!(
            parse_error_span(&format!("$ {plain}$")),
            (Some(11), Some(11))
        );
        // Errors inside a macro expansion report positions in the macro's
        // definition, past the end of this input; they must be dropped.
        assert_eq!(parse_error_span(r"\Braket^"), (None, None));
    }

    #[test]
    fn invalid_options_and_color_are_rejected() {
        let (status, _) = unsafe { render(ratex_render_display_list, "x", "{not json") };
        assert_eq!(status, RATEX_STATUS_INVALID_INPUT);
        let (status, payload) = unsafe {
            render(
                ratex_render_display_list,
                "x",
                r##"{"color":"#notacolor"}"##,
            )
        };
        assert_eq!(status, RATEX_STATUS_INVALID_INPUT);
        assert!(payload.contains("invalid color"));
    }

    #[test]
    fn invalid_utf8_input_is_rejected() {
        let bad = [0xff_u8, 0xfe];
        unsafe {
            let buf = ratex_render_display_list(bad.as_ptr(), bad.len(), core::ptr::null(), 0);
            assert_eq!(ratex_buffer_status(buf), RATEX_STATUS_INVALID_INPUT);
            ratex_buffer_free(buf);
        }
    }

    #[test]
    fn null_handles_are_safe() {
        unsafe {
            assert_eq!(
                ratex_buffer_status(core::ptr::null()),
                RATEX_STATUS_INTERNAL_ERROR
            );
            assert_eq!(ratex_buffer_len(core::ptr::null()), 0);
            assert!(ratex_buffer_data(core::ptr::null()).is_null());
            ratex_buffer_free(core::ptr::null_mut());
            ratex_free(core::ptr::null_mut(), 0);
        }
    }

    #[test]
    fn non_finite_colors_are_rejected() {
        // Color::parse itself accepts these; the ABI must not (the payload
        // would otherwise carry protocol-violating nulls with status OK).
        for spec in [r#"{"color":"[gray]nan"}"#, r#"{"color":"[rgb]1e400,0,0"}"#] {
            let (status, payload) = unsafe { render(ratex_render_display_list, "x", spec) };
            assert_eq!(status, RATEX_STATUS_INVALID_INPUT, "{spec}: {payload}");
        }
    }

    #[test]
    fn payload_json_never_contains_null_numbers() {
        let (status, json) = unsafe {
            render(
                ratex_render_display_list,
                r"\frac{a}{b} + \sqrt{x}",
                r##"{"color":"#123456"}"##,
            )
        };
        assert_eq!(status, RATEX_STATUS_OK);
        assert!(!json.contains("null"), "non-finite value leaked: {json}");
    }

    #[test]
    fn alloc_of_absurd_size_returns_null() {
        // Must be the documented null return, not an abort/trap.
        assert!(ratex_alloc(usize::MAX / 2).is_null());
        assert!(ratex_alloc(0).is_null());
    }

    #[test]
    fn deep_nesting_does_not_overflow_a_small_host_stack() {
        // 32 levels is the most the parser accepts; deeper input must be a
        // parse error, never a crash, even from a host thread this small.
        let nested = |depth: usize| {
            [
                format!("{}x{}", "{".repeat(depth), "}".repeat(depth)),
                format!("{}x{}", r"\sqrt{".repeat(depth), "}".repeat(depth)),
            ]
        };
        let cases = [(32, RATEX_STATUS_OK), (511, RATEX_STATUS_PARSE_ERROR)]
            .map(|(depth, expected)| (nested(depth), expected));
        let host = std::thread::Builder::new()
            .stack_size(256 << 10)
            .spawn(move || {
                cases.map(|(inputs, expected)| {
                    let statuses = inputs.map(|latex| unsafe {
                        (
                            render(ratex_render_display_list, &latex, "").0,
                            render(ratex_render_svg, &latex, "").0,
                        )
                    });
                    (statuses, expected)
                })
            })
            .unwrap();
        for (statuses, expected) in host.join().unwrap() {
            for status in statuses {
                assert_eq!(status, (expected, expected));
            }
        }
    }

    #[test]
    fn engine_panics_become_internal_errors() {
        fn boom(_: &str, _: &RenderOptions) -> Result<Vec<u8>, RatexBuffer> {
            panic!("simulated engine bug")
        }
        unsafe {
            let buf = render_entry(b"x".as_ptr(), 1, core::ptr::null(), 0, boom);
            assert_eq!(ratex_buffer_status(buf), RATEX_STATUS_INTERNAL_ERROR);
            ratex_buffer_free(buf);
        }
        // The render worker survives the panic.
        let (status, _) = unsafe { render(ratex_render_display_list, "x", "") };
        assert_eq!(status, RATEX_STATUS_OK);
    }

    #[test]
    fn color_option_tints_glyphs() {
        let (status, json) =
            unsafe { render(ratex_render_display_list, "x", r##"{"color":"#ff0000"}"##) };
        assert_eq!(status, RATEX_STATUS_OK);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let color = &value["items"][0]["color"];
        assert!((color["r"].as_f64().unwrap() - 1.0).abs() < 1e-6);
        assert!(color["g"].as_f64().unwrap().abs() < 1e-6);
    }
}
