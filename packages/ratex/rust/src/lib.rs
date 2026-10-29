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
//!   system font found at render time with the default `system-fonts`
//!   feature on native targets (overridable with the `RATEX_UNICODE_FONT`
//!   environment variable), and otherwise become `<text>` elements that rely
//!   on the viewer's fonts. Web builds leave the feature off (see
//!   `tool/build_wasm.sh`), which keeps the module free of imports.
//!
//! Sub-expression boxes: `\ratexBox{id}{body}` renders `body` exactly as if
//! it were not wrapped and reports where it landed; `\ratexHighlight{color}
//! {id}{body}` does the same and paints a `color` rect behind the box. Ids
//! match `[A-Za-z0-9_.:-]+` and need not be unique. Boxes are reported
//! outermost first, in source order:
//! - DisplayList JSON gains a top-level `"boxes"` array (omitted when the
//!   formula has no boxes, so other payloads are unchanged), each entry
//!   `{"id", "x", "y", "width", "height", "start"?, "end"?}` in the same em
//!   coordinates as the items (y down, origin at the top-left of the
//!   formula's box). `start`/`end` are the byte range of the body in the
//!   input, inside its braces, when the body was typed there.
//! - SVG gets one `<rect data-ratex-box="id" x y width height
//!   [data-ratex-start data-ratex-end] fill="none" pointer-events="all"/>`
//!   per box at the end of the document, in user units, so inner boxes are
//!   on top for hit testing.
//!
//! On error the buffer's status is non-zero and the payload is a small JSON
//! object `{"message": string, "start": number|null, "end": number|null}`
//! with byte offsets into the input, for editor diagnostics.

mod boxes;
// With `system-fonts`, ratex-svg writes the SVG; tests compare the two.
#[cfg_attr(feature = "system-fonts", allow(dead_code))]
mod svg;

use boxes::SubtermBox;
use ratex_layout::{layout, to_display_list, validate_layout, LayoutOptions};
use ratex_lexer::token::Token;
use ratex_parser::macro_expander::{MacroDefinition, MacroExpander};
use ratex_parser::ParseResult;
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

/// A laid-out formula and the `\ratexBox`es in it.
struct Rendered {
    display_list: DisplayList,
    boxes: Vec<SubtermBox>,
}

fn layout_display_list(latex: &str, options: &RenderOptions) -> Result<Rendered, RatexBuffer> {
    let raw_source = strip_outer_math_delimiters(latex);
    let raw_offset = raw_source.as_ptr() as usize - latex.as_ptr() as usize;
    let normalized = normalize_compat_environments(raw_source);
    let (source, span_offset): (&str, Option<usize>) = match &normalized {
        std::borrow::Cow::Borrowed(s) => (s, Some(raw_offset)),
        std::borrow::Cow::Owned(s) => (s.as_str(), None),
    };
    let mut parser = Parser::new(source);
    register_compat_macros(&mut parser, source);
    boxes::begin(source)
        .map_err(|message| error_buffer(RATEX_STATUS_PARSE_ERROR, message, None))?;
    let mut nodes = parser.parse().map_err(|e| {
        error_buffer(
            RATEX_STATUS_PARSE_ERROR,
            &e.message,
            span_offset.and_then(|offset| {
                e.loc
                    .as_ref()
                    .and_then(|l| input_span(source, offset, l.start, l.end))
            }),
        )
    })?;
    let marks = boxes::mark(&mut nodes);
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
    // Caps the display list before it is built: small input can describe
    // millions of items (dashed array rules repeat along a \rule's height),
    // and running out of memory aborts the process. Reported like the
    // parser's own resource-limit errors.
    validate_layout(&layout_box)
        .map_err(|message| error_buffer(RATEX_STATUS_PARSE_ERROR, &message, None))?;
    let mut display_list = to_display_list(&layout_box);
    sanitize_display_list(&mut display_list);
    let boxes = match marks {
        Some(marks) => marks.extract(&mut display_list, source, |start, end| {
            span_offset.and_then(|offset| input_span(source, offset, start, end))
        }),
        None => Vec::new(),
    };
    Ok(Rendered {
        display_list,
        boxes,
    })
}

/// Built-in compatibility macros for Project Gutenberg / Distributed
/// Proofreaders `.tex` corpora and classical trig/calculus notation. The
/// table is `compat_macros.json` at the package root, shared with ManyMath's
/// Dart normalizer and math-games' Python extractor; edit it there. The
/// sub-expression box macros (`\ratexBox`, `\ratexHighlight`) are function
/// macros registered alongside them (see the `boxes` module).
///
/// Registered in the parser's `MacroExpander` only when referenced in
/// `source` and not explicitly defined via `\newcommand`/`\def`, so standard
/// LaTeX inputs pay zero overhead and preserve exact byte-offset spans.
const COMPAT_MACROS_JSON: &str = include_str!("../../compat_macros.json");

struct CompatMacro {
    /// Control sequence including the backslash, e.g. `\ds`.
    name: String,
    /// Text-macro body, padded so its arity is inferred correctly.
    body: String,
    /// Whether a `[..]` group may precede the arguments.
    optional: bool,
}

/// Name of the text macro behind an `optional` compat macro, e.g.
/// `\ratexOptFirst` for `\First`.
fn optional_target(name: &str) -> String {
    format!("\\ratexOpt{}", name.trim_start_matches('\\'))
}

/// `\ratexOptSkip\ratexOptX`: drops a `[..]` group (after any spaces) that
/// follows the target `\ratexOptX`, then hands the target back so it reads its
/// arguments. An `optional` compat macro `\X` is a text macro with that body.
fn skip_optional_group(me: &mut MacroExpander) -> ParseResult<Vec<Token>> {
    let target = me.pop_token();
    me.consume_spaces();
    if me.future().text == "[" {
        me.pop_token();
        me.consume_arg(Some(&["]"]))?;
    }
    Ok(vec![target])
}

#[derive(serde::Deserialize)]
struct CompatTable {
    macros: Vec<CompatEntry>,
}

#[derive(serde::Deserialize)]
struct CompatEntry {
    name: String,
    arity: usize,
    expansion: String,
    #[serde(default = "default_true")]
    ratex: bool,
    /// A `[..]` group may precede the arguments and is dropped.
    #[serde(default)]
    optional: bool,
}

fn default_true() -> bool {
    true
}

/// The longest `#1`, `#2`, ... run in order of appearance, which is how a
/// text macro's arity is inferred.
fn inferred_arity(body: &str) -> usize {
    let mut arity = 0;
    let mut rest = body;
    while let Some(idx) = rest.find('#') {
        rest = &rest[idx + 1..];
        if rest.as_bytes().first() == Some(&(b'1' + arity as u8)) {
            arity += 1;
        }
    }
    arity
}

/// Text macro arity is inferred from that run, so a body that drops an
/// argument, or mentions them out of order, still has to mention every one in
/// order. Such a body is wrapped as `\@secondoftwo{#1#2..}{body}`, which
/// swallows the mentions and yields the body.
fn text_macro_body(expansion: &str, arity: usize) -> String {
    if arity == 0 || inferred_arity(expansion) == arity {
        return expansion.to_owned();
    }
    let mentions: String = (1..=arity).map(|i| format!("#{i}")).collect();
    format!("\\@secondoftwo{{{mentions}}}{{{expansion}}}")
}

fn compat_macros() -> &'static [CompatMacro] {
    static TABLE: std::sync::OnceLock<Vec<CompatMacro>> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        let table: CompatTable =
            serde_json::from_str(COMPAT_MACROS_JSON).expect("compat_macros.json is valid");
        table
            .macros
            .into_iter()
            .filter(|m| m.ratex)
            .map(|m| CompatMacro {
                name: format!("\\{}", m.name),
                body: text_macro_body(&m.expansion, m.arity),
                optional: m.optional,
            })
            .collect()
    })
}

fn register_compat_macros(parser: &mut Parser, source: &str) {
    if !source.contains('\\') {
        return;
    }
    for entry in compat_macros() {
        if contains_control_word(source, &entry.name) && !defines_command(source, &entry.name) {
            if entry.optional {
                let target = optional_target(&entry.name);
                parser.gullet.set_text_macro(&target, &entry.body);
                parser
                    .gullet
                    .set_text_macro(&entry.name, &format!("\\ratexOptSkip{target}"));
                parser.gullet.set_macro(
                    "\\ratexOptSkip".to_owned(),
                    MacroDefinition::Function(skip_optional_group),
                );
            } else {
                parser.gullet.set_text_macro(&entry.name, &entry.body);
            }
        }
    }
    for &(name, handler) in boxes::BOX_MACROS {
        if contains_control_word(source, name) && !defines_command(source, name) {
            parser
                .gullet
                .set_macro(name.to_owned(), MacroDefinition::Function(handler));
        }
    }
}

/// Checks whether `source` contains the LaTeX control word `name` (e.g. `\ds`)
/// followed by a non-alphabetic boundary, so `\ds` does not match `\displaystyle`.
fn contains_control_word(source: &str, name: &str) -> bool {
    let mut rest = source;
    while let Some(idx) = rest.find(name) {
        let after = &rest[idx + name.len()..];
        let next_is_alpha = after
            .as_bytes()
            .first()
            .is_some_and(|b| b.is_ascii_alphabetic());
        if !next_is_alpha {
            return true;
        }
        rest = after;
    }
    false
}

/// Returns `true` if `source` explicitly defines `name` via `\newcommand`,
/// `\renewcommand`, `\providecommand`, or `\def` so compat defaults never
/// collide with user definitions.
fn defines_command(source: &str, name: &str) -> bool {
    for prefix in [
        "\\newcommand",
        "\\renewcommand",
        "\\providecommand",
        "\\def",
        "\\gdef",
        "\\edef",
        "\\xdef",
    ] {
        let mut rest = source;
        while let Some(idx) = rest.find(prefix) {
            let after_prefix = rest[idx + prefix.len()..].trim_start();
            let after_brace = after_prefix
                .strip_prefix('{')
                .map(str::trim_start)
                .unwrap_or(after_prefix);
            if let Some(tail) = after_brace.strip_prefix(name) {
                if !tail
                    .as_bytes()
                    .first()
                    .is_some_and(|b| b.is_ascii_alphabetic())
                {
                    return true;
                }
            }
            rest = &rest[idx + prefix.len()..];
        }
    }
    false
}

/// Normalizes Distributed Proofreaders display environments (`DPalign*`,
/// `DPgather*`) into standard KaTeX/RaTeX `aligned`/`gathered` environments,
/// borrowing `source` unchanged whenever those environments are absent.
fn normalize_compat_environments(source: &str) -> std::borrow::Cow<'_, str> {
    if !source.contains("DPalign") && !source.contains("DPgather") {
        return std::borrow::Cow::Borrowed(source);
    }
    let normalized = source
        .replace("DPalign*", "aligned")
        .replace("DPalign", "aligned")
        .replace("DPgather*", "gathered")
        .replace("DPgather", "gathered");
    std::borrow::Cow::Owned(normalized)
}

/// Same trimming as `ratex_parser::parse` (surrounding whitespace, then one
/// pair of `$$...$$`, `$...$`, `\[...\]`, or `\(...\)`), done here so
/// parse-error spans, which are relative to the stripped text, can be mapped
/// back onto the input.
fn strip_outer_math_delimiters(input: &str) -> &str {
    let s = input.trim();
    if s.len() >= 4
        && ((s.starts_with("$$") && s.ends_with("$$"))
            || (s.starts_with(r"\[") && s.ends_with(r"\]"))
            || (s.starts_with(r"\(") && s.ends_with(r"\)")))
    {
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
    let rendered = layout_display_list(latex, options)?;
    #[derive(serde::Serialize)]
    struct VersionedDisplayList<'a> {
        version: u32,
        #[serde(flatten)]
        display_list: &'a DisplayList,
        #[serde(skip_serializing_if = "<[_]>::is_empty")]
        boxes: &'a [SubtermBox],
    }
    serde_json::to_vec(&VersionedDisplayList {
        version: 1,
        display_list: &rendered.display_list,
        boxes: &rendered.boxes,
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
    let rendered = layout_display_list(latex, options)?;
    #[cfg(feature = "system-fonts")]
    let svg = ratex_svg::render_to_svg(
        &rendered.display_list,
        &ratex_svg::SvgOptions {
            font_size: options.font_size,
            padding: options.padding,
            stroke_width: options.stroke_width,
            embed_glyphs: options.embed_glyphs,
            ..Default::default()
        },
    );
    #[cfg(not(feature = "system-fonts"))]
    let svg = svg::render_to_svg(
        &rendered.display_list,
        &svg::SvgOptions {
            font_size: options.font_size,
            padding: options.padding,
            stroke_width: options.stroke_width,
            embed_glyphs: options.embed_glyphs,
        },
    );
    Ok(
        boxes::add_svg_hit_areas(svg, &rendered.boxes, options.font_size, options.padding)
            .into_bytes(),
    )
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
    fn oversized_layouts_are_rejected() {
        // One dashed rule per ~0.3em of a million-em-tall array: millions of
        // display items from 55 bytes of input (taller ones exhaust memory).
        let latex = r"\begin{array}{c:c}a&\rule{1em}{1000000em}\end{array}";
        for f in [ratex_render_display_list, ratex_render_svg] {
            let (status, payload) = unsafe { render(f, latex, "") };
            assert_eq!(status, RATEX_STATUS_PARSE_ERROR, "{payload}");
            assert!(payload.contains("resource limit"), "{payload}");
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

    #[test]
    fn compat_macros_render_project_gutenberg_and_classical_math() {
        let samples = [
            r"\ds \efrac{1}{2} + \Frac{3}{4}",
            r"\dint_0^{\pi} \Sin x \, dx = 2",
            r"\arcsec x + \arccsc y + \arccot z + \sech u + \csch v",
            r"\arsinh x + \arcosh y + \artanh z",
            r"\sqrtp{x^2 + 1} + \DELTA x + \EPSILON",
            r"\DPtypo{bad}{\frac{dy}{dx}} = \DPchg{old}{2x} + \DPmod{a}{b} + \First{C} + \Inum{1}",
            r"\begin{DPalign*} y &= x^2 \\ \frac{dy}{dx} &= 2x \end{DPalign*}",
            r"\[ \Sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6} \]",
            r"\( \Lim_{x \to 0} \frac{\Sin x}{x} = 1 \)",
            r"\newcommand{\ds}{x^2} \ds + 1",
        ];
        for sample in samples {
            let (status, payload) = unsafe { render(ratex_render_display_list, sample, "") };
            assert_eq!(status, RATEX_STATUS_OK, "{sample}: {payload}");
        }
    }

    /// The characters a formula paints, in display-list order.
    fn glyphs(latex: &str) -> String {
        let (status, json) = unsafe { render(ratex_render_display_list, latex, "") };
        assert_eq!(status, RATEX_STATUS_OK, "{latex}: {json}");
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|item| item["char_code"].as_u64())
            .map(|code| char::from_u32(code as u32).unwrap())
            .collect()
    }

    #[test]
    fn compat_macros_drop_the_arguments_their_pg_definitions_drop() {
        assert_eq!(glyphs(r"\DPtypo{a}{b}"), "b");
        assert_eq!(glyphs(r"\DPchg{old}{new}"), "new");
        assert_eq!(glyphs(r"\DPmod{x}{y} + 1"), "y+1");
        assert_eq!(glyphs(r"x\DPnote{a transcriber's note}"), "x");
        assert_eq!(glyphs(r"\efrac{1}{2}"), glyphs(r"\frac{1}{2}"));
        assert_eq!(glyphs(r"\DELTA"), glyphs(r"\epsilon"));
        assert_eq!(glyphs(r"\EPSILON"), glyphs(r"\delta"));
        assert_eq!(glyphs(r"\Log z"), "Logz");
        assert_eq!(glyphs(r"\Sin x"), "Sinx");
        // A formula's own definition wins over the compat default.
        assert_eq!(glyphs(r"\newcommand{\DPtypo}[2]{#1} \DPtypo{a}{b}"), "a");
    }

    #[test]
    fn optional_compat_macros_drop_the_bracket_group() {
        assert_eq!(glyphs(r"x\DPnote[a]{b}y"), "xy");
        assert_eq!(glyphs(r"\First[x]{Abc}"), "Abc");
        assert_eq!(glyphs(r"\First [x]{Abc}"), "Abc");
        assert_eq!(glyphs(r"\First[{]}x]{Abc}"), "Abc");
        assert_eq!(glyphs(r"\First{Abc}"), "Abc");
        assert_eq!(glyphs(r"\Add{[a]}"), "[a]");
    }

    #[test]
    fn compat_fixtures_paint_the_expected_glyphs() {
        let fixtures: serde_json::Value =
            serde_json::from_str(include_str!("../../compat_fixtures.json")).unwrap();
        let mut checked = 0;
        for fixture in fixtures["fixtures"].as_array().unwrap() {
            if let Some(expected) = fixture["glyphs"].as_str() {
                let input = fixture["input"].as_str().unwrap();
                assert_eq!(glyphs(input), expected, "{}: {input}", fixture["id"]);
                checked += 1;
            }
        }
        assert!(checked > 10);
    }

    #[test]
    fn compat_macros_table_is_consistent() {
        let table: CompatTable = serde_json::from_str(COMPAT_MACROS_JSON).unwrap();
        for m in &table.macros {
            let body = text_macro_body(&m.expansion, m.arity);
            assert_eq!(inferred_arity(&body), m.arity, "{}", m.name);
        }
        assert_eq!(
            compat_macros().len(),
            table.macros.iter().filter(|m| m.ratex).count()
        );
    }

    fn display_list(latex: &str) -> serde_json::Value {
        let (status, json) = unsafe { render(ratex_render_display_list, latex, "") };
        assert_eq!(status, RATEX_STATUS_OK, "{latex}: {json}");
        serde_json::from_str(&json).unwrap()
    }

    /// `(id, [x, y, width, height])` of every box, in reported order.
    fn boxes(value: &serde_json::Value) -> Vec<(String, [f64; 4])> {
        let Some(boxes) = value.get("boxes") else {
            return Vec::new();
        };
        boxes
            .as_array()
            .unwrap()
            .iter()
            .map(|b| {
                let n = |key: &str| b[key].as_f64().unwrap();
                (
                    b["id"].as_str().unwrap().to_owned(),
                    [n("x"), n("y"), n("width"), n("height")],
                )
            })
            .collect()
    }

    fn contains(outer: [f64; 4], inner: [f64; 4]) -> bool {
        const EPS: f64 = 1e-9;
        inner[0] >= outer[0] - EPS
            && inner[1] >= outer[1] - EPS
            && inner[0] + inner[2] <= outer[0] + outer[2] + EPS
            && inner[1] + inner[3] <= outer[1] + outer[3] + EPS
    }

    #[test]
    fn boxes_leave_the_layout_unchanged() {
        let cases = [
            (r"a+\ratexBox{b}{b}+c", "a+b+c"),
            (r"a\ratexBox{op}{+}b", "a+b"),
            (r"a\ratexBox{t}{-x}", "a-x"),
            (r"2\ratexBox{l}{(x}+1)", "2(x+1)"),
            (r"\ratexBox{d}{\frac{dy}{dx}} = 2x", r"\frac{dy}{dx} = 2x"),
            (r"\frac{\ratexBox{n}{a+b}}{c}", r"\frac{a+b}{c}"),
            (r"\sqrt{\ratexBox{r}{x^2}+1}", r"\sqrt{x^2+1}"),
            (r"\sqrt[\ratexBox{i}{3}]{x}", r"\sqrt[3]{x}"),
            (
                r"x^{\ratexBox{e}{2n}} - y_{\ratexBox{s}{i+1}}",
                r"x^{2n} - y_{i+1}",
            ),
            (r"\ratexBox{sum}{\sum_{i=0}^n i^2}", r"\sum_{i=0}^n i^2"),
            (r"\left(\ratexBox{in}{x+y}\right)^2", r"\left(x+y\right)^2"),
            (
                r"\ratexBox{f}{\sin} x + \ratexBox{g}{\cos x}",
                r"\sin x + \cos x",
            ),
            (
                r"\ratexBox{o}{a + \ratexBox{i}{\frac{1}{x}} - \ratexBox{j}{b}}",
                r"a + \frac{1}{x} - b",
            ),
            (
                r"\begin{aligned}\ratexBox{l}{x} &= \ratexBox{r}{y+1} \\ z &= 0\end{aligned}",
                r"\begin{aligned}x &= y+1 \\ z &= 0\end{aligned}",
            ),
            (r"\text{if \ratexBox{w}{x > 0}}", r"\text{if x > 0}"),
        ];
        for (boxed, plain) in cases {
            let boxed_value = display_list(boxed);
            let plain_value = display_list(plain);
            assert_eq!(boxed_value["items"], plain_value["items"], "{boxed}");
            for key in ["width", "height", "depth"] {
                let (b, p) = (boxed_value[key].as_f64(), plain_value[key].as_f64());
                assert!((b.unwrap() - p.unwrap()).abs() < 1e-9, "{boxed}: {key}");
            }
            assert!(!boxes(&boxed_value).is_empty(), "{boxed}: no boxes");
            assert!(plain_value.get("boxes").is_none(), "{plain}");
        }
    }

    #[test]
    fn boxes_report_ids_and_nest() {
        let value = display_list(
            r"\ratexBox{lhs}{\frac{\ratexBox{num}{d y}}{\ratexBox{den}{dx}}} = \ratexBox{rhs}{2\ratexBox{x}{x}^{\ratexBox{exp}{2}}}",
        );
        let found = boxes(&value);
        let ids: Vec<&str> = found.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["lhs", "num", "den", "rhs", "x", "exp"]);
        let get = |id: &str| found.iter().find(|(b, _)| b == id).unwrap().1;
        for (outer, inner) in [("lhs", "num"), ("lhs", "den"), ("rhs", "x"), ("rhs", "exp")] {
            assert!(
                contains(get(outer), get(inner)),
                "{outer} must contain {inner}"
            );
        }
        // The numerator sits above the denominator, the exponent above x.
        assert!(get("num")[1] + get("num")[3] <= get("den")[1]);
        assert!(get("exp")[1] < get("x")[1]);
        // Everything lies inside the formula's box.
        let total = [
            0.0,
            0.0,
            value["width"].as_f64().unwrap(),
            value["height"].as_f64().unwrap() + value["depth"].as_f64().unwrap(),
        ];
        for (id, rect) in &found {
            assert!(rect[2] > 0.0 && rect[3] > 0.0, "{id}: {rect:?}");
            assert!(contains(total, *rect), "{id}: {rect:?} outside {total:?}");
        }
        // A box split over several atoms spans all of them.
        let (_, sum) = &boxes(&display_list(r"\ratexBox{s}{a+b+c}"))[0];
        assert!((sum[2] - display_list("a+b+c")["width"].as_f64().unwrap()).abs() < 1e-9);
    }

    #[test]
    fn input_cannot_forge_box_markers() {
        // A transparent colorbox in the marker format is not box `a`.
        let value = display_list(r"\ratexBox{a}{x}+\colorbox{#7a000000}{yyyyyy}");
        let found = boxes(&value);
        assert_eq!(found.len(), 1);
        let plain = display_list(
            r"\ratexBox{a}{x}+\colorbox{#7a000000}{yyyyyy}"
                .replace(r"\ratexBox{a}{x}", "x")
                .as_str(),
        );
        assert!(found[0].1[2] < plain["width"].as_f64().unwrap() / 2.0);
        // Neither is a hand-written wrapper, in any colour we could pick.
        for tag in 0..=255u32 {
            let latex = format!(r"\ratexBox{{a}}{{x}}+\colorbox{{#{tag:02x}000000}}{{yyyyyy}}");
            let found = boxes(&display_list(&latex));
            assert_eq!(found.len(), 1, "{latex}");
            assert!(found[0].1[2] < 1.0, "{latex}: {found:?}");
        }
        let value = display_list(r"x+\htmlStyle{ratex-box:0}{yyyy}+\ratexBox{a}{z}");
        let found = boxes(&value);
        assert_eq!(found.len(), 1);
        let z = boxes(&display_list(r"x+yyyy+\ratexBox{a}{z}"));
        assert_eq!(found[0].1, z[0].1);
        // Guessing the nonce's shape does not help either.
        let value = display_list(r"\ratexBox{a}{z}\htmlStyle{ratex-box-0000000000000000:0}{yyyy}");
        assert_eq!(boxes(&value).len(), 1);
    }

    #[test]
    fn box_spans_never_point_inside_macro_definitions() {
        let latex = r"\def\b{\ratexBox{h}{yy}}\b+\b";
        let value = display_list(latex);
        assert_eq!(boxes(&value).len(), 2);
        for b in value["boxes"].as_array().unwrap() {
            assert!(b.get("start").is_none(), "{b}");
        }
        let latex = r"\newcommand{\b}[1]{\ratexBox{h}{#1}}\ratexBox{k}{z}\b{qq}";
        let value = display_list(latex);
        let spans: Vec<_> = value["boxes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| (b["id"].as_str().unwrap(), b["start"].as_u64()))
            .collect();
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].1, latex.find("z").map(|i| i as u64));
        // The braces around `#1` came from the definition, so no span.
        assert_eq!(spans[1].1, None);
    }

    #[test]
    fn box_bodies_report_their_input_span() {
        let latex = r"$x = \ratexBox{frac}{\frac{1}{2}} + \ratexBox{y}y$";
        let (_, json) = unsafe { render(ratex_render_display_list, latex, "") };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let span = |i: usize| {
            let b = &value["boxes"][i];
            &latex[b["start"].as_u64().unwrap() as usize..b["end"].as_u64().unwrap() as usize]
        };
        assert_eq!(span(0), r"\frac{1}{2}");
        assert_eq!(span(1), "y");
        // A body put together by a macro has no single span in the input.
        let value = display_list(r"\newcommand{\wrap}[1]{\ratexBox{h}{#1}} \wrap{y}");
        assert_eq!(value["boxes"][0]["id"], "h");
        assert!(value["boxes"][0].get("start").is_none(), "{value}");
    }

    #[test]
    fn invalid_box_arguments_are_parse_errors() {
        for latex in [
            r"\ratexBox{has space}{x}",
            r"\ratexBox{}{x}",
            r"\ratexBox{a<b}{x}",
            r"\ratexHighlight{notacolor}{id}{x}",
            r"\ratexBox{id}",
        ] {
            let (status, payload) = unsafe { render(ratex_render_display_list, latex, "") };
            assert_eq!(status, RATEX_STATUS_PARSE_ERROR, "{latex}: {payload}");
        }
        // A formula's own definition wins over the built-in one.
        let value = display_list(r"\newcommand{\ratexBox}[2]{#2} \ratexBox{a}{b}");
        assert!(value.get("boxes").is_none());
    }

    #[test]
    fn highlight_paints_one_rect_behind_its_box() {
        let latex = r"\ratexHighlight{#fee2e2}{t}{a+b} = c";
        let value = display_list(latex);
        let (_, rect) = &boxes(&value)[0];
        let items = value["items"].as_array().unwrap();
        let rects: Vec<_> = items.iter().filter(|i| i["type"] == "Rect").collect();
        assert_eq!(rects.len(), 1, "{value}");
        let fill = rects[0];
        for (key, expected) in ["x", "y", "width", "height"].iter().zip(rect) {
            assert!((fill[key].as_f64().unwrap() - expected).abs() < 1e-9);
        }
        assert!((fill["color"]["r"].as_f64().unwrap() - 254.0 / 255.0).abs() < 1e-6);
        // Painted first, under the glyphs.
        assert_eq!(items[0]["type"], "Rect");
        // Glyphs are where they would be without the highlight.
        let plain = display_list("a+b = c");
        assert_eq!(items[1..], plain["items"].as_array().unwrap()[..]);
    }

    #[test]
    fn svg_marks_boxes_for_hit_testing() {
        let latex = r"\ratexBox{lhs}{\frac{dy}{dx}} = \ratexBox{rhs}{2\ratexBox{x}{x}}";
        let opts = r#"{"fontSize":20,"padding":5}"#;
        let (status, svg) = unsafe { render(ratex_render_svg, latex, opts) };
        assert_eq!(status, RATEX_STATUS_OK, "{svg}");
        let (_, plain) = unsafe { render(ratex_render_svg, r"\frac{dy}{dx} = 2x", opts) };
        // The drawing is untouched; the hit areas follow it.
        let drawing = &svg[..svg.find("<rect data-ratex-box").unwrap()];
        assert_eq!(drawing, &plain[..plain.len() - "</svg>".len()]);
        assert!(svg.ends_with("</svg>"));
        let lhs = boxes(&display_list(latex))[0].1;
        let num = |x: f64| svg::Num(x).to_string();
        let start = latex.find(r"\frac").unwrap();
        assert!(svg.contains(&format!(
            r#"<rect data-ratex-box="lhs" x="{}" y="{}" width="{}" height="{}" data-ratex-start="{start}" data-ratex-end="{}" fill="none" pointer-events="all"/>"#,
            num(lhs[0] * 20.0 + 5.0),
            num(lhs[1] * 20.0 + 5.0),
            num(lhs[2] * 20.0),
            num(lhs[3] * 20.0),
            start + r"\frac{dy}{dx}".len(),
        )), "{svg}");
        for id in ["rhs", "x"] {
            assert!(svg.contains(&format!(r#"data-ratex-box="{id}""#)));
        }
    }

    /// Formulas exercising every display item kind and KaTeX font.
    const SVG_CORPUS: &[&str] = &[
        r"\frac{-b \pm \sqrt{b^2-4ac}}{2a}",
        r"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6} \quad \int_0^1 \oint \prod",
        r"\mathbb{R} \mathcal{F} \mathfrak{g} \mathscr{L} \mathsf{x} \mathtt{y} \mathrm{d}",
        r"\boldsymbol{\alpha} \mathbf{v} \textit{it} \textbf{bf} \textsf{\textbf{sb}} \mathsf{\textit{si}}",
        r"\left( \frac{a}{b} \right] \Bigg\{ \big| \left\langle x \middle| y \right\rangle",
        r"\overbrace{a+b}^{n} \underbrace{c}_{m} \xrightarrow[below]{f} \overleftrightarrow{AB}",
        r"\begin{array}{c:c|c} a & b & c \\ \hdashline d & e & f \\ \hline g & h & i \end{array}",
        r"\color{#ff000080}{x} \colorbox{yellow}{y} \fcolorbox{red}{#0000ff}{z} \textcolor{teal}{w}",
        r"\sqrt[3]{x} \widehat{abc} \vec{v} \tilde{n} \overline{z} \underline{q}",
        r"\cancel{x} \bcancel{y} \xcancel{z} \boxed{w} \sout{s} \phase{\theta}",
        r"\ce{2H2 + O2 <=> 2H2O} \ce{A ->[\Delta] B}",
        r"\text{a < b \& c > d}",
    ];

    #[cfg(feature = "system-fonts")]
    #[test]
    fn svg_writer_matches_ratex_svg() {
        for latex in SVG_CORPUS {
            let Ok(rendered) = layout_display_list(latex, &RenderOptions::default()) else {
                panic!("{latex} failed to render");
            };
            for (embed_glyphs, font_size, padding, stroke_width) in [
                (true, 40.0, 10.0, 1.5),
                (true, 17.5, 0.0, 0.8),
                (false, 22.0, 6.0, 1.4),
            ] {
                let ours = svg::render_to_svg(
                    &rendered.display_list,
                    &svg::SvgOptions {
                        font_size,
                        padding,
                        stroke_width,
                        embed_glyphs,
                    },
                );
                let theirs = ratex_svg::render_to_svg(
                    &rendered.display_list,
                    &ratex_svg::SvgOptions {
                        font_size,
                        padding,
                        stroke_width,
                        embed_glyphs,
                        ..Default::default()
                    },
                );
                assert_eq!(ours, theirs, "{latex} (embed_glyphs: {embed_glyphs})");
            }
        }
    }

    #[test]
    fn svg_outlines_every_katex_glyph() {
        for latex in SVG_CORPUS {
            let (status, svg) = unsafe { render(ratex_render_svg, latex, "") };
            assert_eq!(status, RATEX_STATUS_OK, "{latex}: {svg}");
            assert!(!svg.contains("<text"), "{latex}: {svg}");
        }
    }
}
