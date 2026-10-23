//! SVG writer for builds without the `system-fonts` feature.
//!
//! `ratex-svg` can only outline glyphs (its `standalone` feature) together
//! with system font discovery, which on wasm32 links `web-sys` and leaves the
//! module with `__wbindgen_*` imports and exports. This writer produces the
//! same document as `ratex_svg::render_to_svg` with `embed-fonts`, outlining
//! glyphs from the compiled-in KaTeX fonts only: a character those fonts
//! lack becomes a `<text>` element, as it always did on wasm32.

use std::collections::HashMap;
use std::fmt::Write;
use std::sync::{Mutex, OnceLock};

use ab_glyph::{Font, FontArc, FontRef, FontVec, OutlineCurve};
use ratex_font::FontId;
use ratex_types::color::Color;
use ratex_types::display_item::{DisplayItem, DisplayList};
use ratex_types::path_command::PathCommand;

/// The subset of `ratex_svg::SvgOptions` this writer honors.
pub(crate) struct SvgOptions {
    pub font_size: f64,
    pub padding: f64,
    pub stroke_width: f64,
    pub embed_glyphs: bool,
}

pub(crate) fn render_to_svg(list: &DisplayList, opts: &SvgOptions) -> String {
    let em = opts.font_size;
    let pad = opts.padding;
    let width = list.width * em + 2.0 * pad;
    let height = (list.height + list.depth) * em + 2.0 * pad;
    let mut out = String::from(r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 "#);
    let _ = write!(
        out,
        r#"{} {}" width="{}pt" height="{}pt">"#,
        Num(width),
        Num(height),
        Num(width),
        Num(height)
    );
    for item in &list.items {
        match item {
            DisplayItem::GlyphPath {
                x,
                y,
                scale,
                font,
                char_code,
                color,
            } => {
                let outlined = opts.embed_glyphs
                    && glyph_path(
                        &mut out,
                        (x * em + pad) as f32,
                        (y * em + pad) as f32,
                        (scale * em) as f32,
                        font,
                        *char_code,
                        color,
                    );
                if !outlined {
                    glyph_text(
                        &mut out,
                        x * em + pad,
                        y * em + pad,
                        scale * em,
                        font,
                        *char_code,
                        color,
                    );
                }
            }
            DisplayItem::Line {
                x,
                y,
                width,
                thickness,
                color,
                dashed,
            } => {
                let (x0, yc) = (x * em + pad, y * em + pad);
                let t = (thickness * em).max(1e-6);
                let w = width * em;
                if *dashed {
                    let _ = write!(
                        out,
                        r#"<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{}" stroke-width="{}" stroke-dasharray="{} {}"/>"#,
                        Num(x0),
                        Num(yc),
                        Num(x0 + w),
                        Num(yc),
                        Rgba(color),
                        Num(t),
                        Num(t * 3.0),
                        Num(t * 3.0)
                    );
                } else {
                    rect(&mut out, x0, yc - t / 2.0, w, t, color);
                }
            }
            DisplayItem::Rect {
                x,
                y,
                width,
                height,
                color,
            } => rect(
                &mut out,
                x * em + pad,
                y * em + pad,
                width * em,
                height * em,
                color,
            ),
            DisplayItem::Path {
                x,
                y,
                commands,
                fill,
                color,
            } => {
                let (ox, oy) = (x * em + pad, y * em + pad);
                if *fill {
                    // One <path> per subpath, as ratex-svg does.
                    let mut start = 0;
                    for i in 1..=commands.len() {
                        if i == commands.len() || matches!(commands[i], PathCommand::MoveTo { .. })
                        {
                            if start < i {
                                out.push_str(r#"<path d=""#);
                                path_data(&mut out, ox, oy, em, &commands[start..i]);
                                let _ = write!(
                                    out,
                                    r#"" fill="{}" fill-rule="nonzero" stroke="none"/>"#,
                                    Rgba(color)
                                );
                            }
                            start = i;
                        }
                    }
                } else if !commands.is_empty() {
                    out.push_str(r#"<path d=""#);
                    path_data(&mut out, ox, oy, em, commands);
                    let _ = write!(
                        out,
                        r#"" fill="none" stroke="{}" stroke-width="{}" stroke-linecap="round" stroke-linejoin="round"/>"#,
                        Rgba(color),
                        Num(opts.stroke_width)
                    );
                }
            }
        }
    }
    out.push_str("</svg>");
    out
}

fn rect(out: &mut String, x: f64, y: f64, width: f64, height: f64, color: &Color) {
    let _ = write!(
        out,
        r#"<rect x="{}" y="{}" width="{}" height="{}" fill="{}"/>"#,
        Num(x),
        Num(y),
        Num(width),
        Num(height),
        Rgba(color)
    );
}

fn path_data(out: &mut String, ox: f64, oy: f64, em: f64, commands: &[PathCommand]) {
    let start = out.len();
    let point = |out: &mut String, x: f64, y: f64| {
        let _ = write!(out, "{} {}", Num(ox + x * em), Num(oy + y * em));
    };
    for cmd in commands {
        match *cmd {
            PathCommand::MoveTo { x, y } => {
                out.push('M');
                point(out, x, y);
            }
            PathCommand::LineTo { x, y } => {
                out.push('L');
                point(out, x, y);
            }
            PathCommand::CubicTo {
                x1,
                y1,
                x2,
                y2,
                x,
                y,
            } => {
                out.push('C');
                point(out, x1, y1);
                out.push(' ');
                point(out, x2, y2);
                out.push(' ');
                point(out, x, y);
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                out.push('Q');
                point(out, x1, y1);
                out.push(' ');
                point(out, x, y);
            }
            PathCommand::Close => out.push('Z'),
        }
        out.push(' ');
    }
    trim_end_from(out, start);
}

/// Appends the glyph as an outlined `<path>`; `false` (and nothing written)
/// when the KaTeX fonts have no outline for it.
fn glyph_path(
    out: &mut String,
    px: f32,
    py: f32,
    em: f32,
    font: &str,
    char_code: u32,
    color: &Color,
) -> bool {
    let font_id = FontId::parse(font).unwrap_or(FontId::MainRegular);
    let ch = ratex_font::katex_ttf_glyph_char(font_id, char_code);
    // Fonts without a KaTeX file (CJK, emoji) look in Main-Regular, and so
    // does a glyph its own font lacks, like ratex-svg's fallback chain.
    let main = katex_font(FontId::MainRegular);
    let fonts = [katex_font(font_id).or_else(|| main.clone()), main];
    let start = out.len();
    out.push_str(r#"<path d=""#);
    for font in fonts.iter().flatten() {
        let glyph = font.glyph_id(ch);
        if glyph.0 != 0 && outline_data(out, px, py, em, font, glyph) {
            let _ = write!(
                out,
                r#"" fill="{}" fill-rule="nonzero" stroke="none"/>"#,
                Rgba(color)
            );
            return true;
        }
    }
    out.truncate(start);
    false
}

/// Path data for a glyph outline, in exactly ratex-svg's form.
fn outline_data(
    out: &mut String,
    px: f32,
    py: f32,
    em: f32,
    font: &FontArc,
    glyph: ab_glyph::GlyphId,
) -> bool {
    let Some(outline) = font.outline(glyph) else {
        return false;
    };
    let scale = em / font.units_per_em().unwrap_or(1000.0);
    let map = |p: ab_glyph::Point| (px + p.x * scale, py - p.y * scale);
    let start = out.len();
    let point = |out: &mut String, (x, y): (f32, f32)| {
        let _ = write!(out, "{} {} ", Num(x as f64), Num(y as f64));
    };
    let mut last_end: Option<(f32, f32)> = None;
    for curve in &outline.curves {
        let (from, to) = match *curve {
            OutlineCurve::Line(p0, p1) => (map(p0), map(p1)),
            OutlineCurve::Quad(p0, _, p2) => (map(p0), map(p2)),
            OutlineCurve::Cubic(p0, _, _, p3) => (map(p0), map(p3)),
        };
        let jump =
            last_end.is_none_or(|(x, y)| (x - from.0).abs() > 0.01 || (y - from.1).abs() > 0.01);
        if jump {
            if last_end.is_some() {
                out.push_str("Z ");
            }
            out.push('M');
            point(out, from);
        }
        match *curve {
            OutlineCurve::Line(_, p1) => {
                out.push('L');
                point(out, map(p1));
            }
            OutlineCurve::Quad(_, p1, p2) => {
                out.push('Q');
                point(out, map(p1));
                point(out, map(p2));
            }
            OutlineCurve::Cubic(_, p1, p2, p3) => {
                out.push('C');
                point(out, map(p1));
                point(out, map(p2));
                point(out, map(p3));
            }
        }
        last_end = Some(to);
    }
    if last_end.is_some() {
        out.push('Z');
    }
    trim_end_from(out, start);
    out.len() > start
}

/// Text fallback, needing the KaTeX webfonts (or a system font) to display.
fn glyph_text(
    out: &mut String,
    x: f64,
    y: f64,
    size: f64,
    font: &str,
    char_code: u32,
    color: &Color,
) {
    let (family, weight, style) = katex_face(font);
    let _ = write!(
        out,
        r#"<text x="{}" y="{}" font-family="{family}" font-size="{}" font-weight="{weight}" font-style="{style}" fill="{}" dominant-baseline="alphabetic">"#,
        Num(x),
        Num(y),
        Num(size),
        Rgba(color)
    );
    match char::from_u32(char_code).unwrap_or('\u{fffd}') {
        '&' => out.push_str("&amp;"),
        '<' => out.push_str("&lt;"),
        '>' => out.push_str("&gt;"),
        '"' => out.push_str("&quot;"),
        ch => out.push(ch),
    }
    out.push_str("</text>");
}

/// KaTeX CSS face for a display-list font name, as ratex-svg maps it.
fn katex_face(font: &str) -> (&'static str, &'static str, &'static str) {
    match font {
        "Main-Regular" => ("KaTeX_Main", "normal", "normal"),
        "Main-Bold" => ("KaTeX_Main", "bold", "normal"),
        "Main-Italic" => ("KaTeX_Main", "normal", "italic"),
        "Main-BoldItalic" => ("KaTeX_Main", "bold", "italic"),
        "Math-Italic" => ("KaTeX_Math", "normal", "italic"),
        "Math-BoldItalic" => ("KaTeX_Math", "bold", "italic"),
        "AMS-Regular" => ("KaTeX_AMS", "normal", "normal"),
        "Caligraphic-Regular" => ("KaTeX_Caligraphic", "normal", "normal"),
        "Fraktur-Regular" => ("KaTeX_Fraktur", "normal", "normal"),
        "Fraktur-Bold" => ("KaTeX_Fraktur", "bold", "normal"),
        "SansSerif-Regular" => ("KaTeX_SansSerif", "normal", "normal"),
        "SansSerif-Bold" => ("KaTeX_SansSerif", "bold", "normal"),
        "SansSerif-Italic" => ("KaTeX_SansSerif", "normal", "italic"),
        "Script-Regular" => ("KaTeX_Script", "normal", "normal"),
        "Typewriter-Regular" => ("KaTeX_Typewriter", "normal", "normal"),
        "Size1-Regular" => ("KaTeX_Size1", "normal", "normal"),
        "Size2-Regular" => ("KaTeX_Size2", "normal", "normal"),
        "Size3-Regular" => ("KaTeX_Size3", "normal", "normal"),
        "Size4-Regular" => ("KaTeX_Size4", "normal", "normal"),
        "CJK-Regular" | "CJK-Fallback" => ("sans-serif", "normal", "normal"),
        "Emoji-Fallback" => (
            r#"Apple Color Emoji, "Segoe UI Emoji", "Noto Color Emoji", sans-serif"#,
            "normal",
            "normal",
        ),
        _ => ("KaTeX_Main", "normal", "normal"),
    }
}

/// The parsed KaTeX font for `id`, if it has one; parsed once per process.
fn katex_font(id: FontId) -> Option<FontArc> {
    static FONTS: OnceLock<Mutex<HashMap<FontId, Option<FontArc>>>> = OnceLock::new();
    let mut fonts = FONTS.get_or_init(Default::default).lock().ok()?;
    fonts
        .entry(id)
        .or_insert_with(|| {
            let bytes = ratex_katex_fonts::ttf_bytes(&format!("KaTeX_{}.ttf", id.as_str()))?;
            match bytes {
                std::borrow::Cow::Borrowed(b) => FontRef::try_from_slice(b).ok().map(FontArc::new),
                std::borrow::Cow::Owned(b) => FontVec::try_from_vec(b).ok().map(FontArc::new),
            }
        })
        .clone()
}

fn trim_end_from(out: &mut String, start: usize) {
    let kept = out[start..].trim_end().len();
    out.truncate(start + kept);
}

/// A number as ratex-svg writes it: six decimals, trailing zeros trimmed.
pub(crate) struct Num(pub f64);

impl std::fmt::Display for Num {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = format!("{:.6}", self.0);
        let s = s.trim_end_matches('0').trim_end_matches('.');
        f.write_str(if s.is_empty() || s == "-" { "0" } else { s })
    }
}

/// A color as ratex-svg's default `rgba(...)` paint.
struct Rgba<'a>(&'a Color);

impl std::fmt::Display for Rgba<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let c = self.0;
        let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        let alpha = if c.a.is_finite() {
            c.a.clamp(0.0, 1.0)
        } else {
            1.0
        };
        write!(f, "rgba({},{},{},{alpha})", byte(c.r), byte(c.g), byte(c.b))
    }
}
