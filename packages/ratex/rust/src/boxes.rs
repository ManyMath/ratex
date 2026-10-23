//! Sub-expression boxes: `\ratexBox{id}{body}` and
//! `\ratexHighlight{color}{id}{body}`.
//!
//! A box reports where its body landed, in display-list coordinates, without
//! changing how the body is laid out. RaTeX has no hook for that, so the
//! geometry is smuggled through the engine:
//!
//! 1. The macros expand to `\htmlStyle{ratex-box:N}{body}`, where `N` indexes
//!    a per-render registry holding the id, the body's source span and the
//!    highlight color ([`BoxSource`]).
//! 2. [`mark`] rewrites each such `Html` node in the parse tree so its style
//!    is a transparent background in a color unique to that node. In a math
//!    list the wrapper is also split into one wrapper per child: the engine
//!    picks inter-atom spacing from its neighbors, so a single wrapper would
//!    make `a\ratexBox{t}{-x}` lay out like `a{-x}` (unary minus).
//! 3. Each background becomes a `Rect` display item. [`Marks::extract`]
//!    removes those rects, merges the pieces of each box, and paints the
//!    highlight (if any) as one rect where the first piece was.
//!
//! A box used as the base of a script (`\ratexBox{f}{f}_2`,
//! `\ratexBox{s}{\sum}_{i}`) lays out like a braced base (`{f}_2`): box the
//! whole `f_2` or `\sum_{i}` instead.

use std::cell::RefCell;
use std::collections::HashMap;

use ratex_lexer::token::{SourceLocation, Token};
use ratex_parser::macro_expander::{FnMacroHandler, MacroExpander};
use ratex_parser::parse_node::{ArrayTag, Mode, ParseNode, ProofBranch};
use ratex_parser::{ParseError, ParseResult};
use ratex_types::color::Color;
use ratex_types::display_item::{DisplayItem, DisplayList};

/// The box macros, registered as function macros (see `register_compat_macros`).
pub(crate) const BOX_MACROS: &[(&str, FnMacroHandler)] = &[
    ("\\ratexBox", expand_box),
    ("\\ratexHighlight", expand_highlight),
];

/// Style prefix of the `\htmlStyle` wrapper the macros expand to.
const STYLE_PREFIX: &str = "ratex-box:";

/// Marker colors are `#7aKKKK00`: fully transparent, so a marker that ever
/// escaped would paint nothing, with the instance number in green and blue.
const MAX_INSTANCES: usize = 1 << 16;

/// One `\ratexBox`/`\ratexHighlight` expansion.
struct BoxSource {
    id: String,
    /// Candidate byte range of the body in the parser's source, and whether
    /// it was braced (see [`body_span`]).
    body: Option<(usize, usize, bool)>,
    highlight: Option<Color>,
}

thread_local! {
    // Renders never nest, and each runs start to finish on one thread.
    static SOURCES: RefCell<Vec<BoxSource>> = const { RefCell::new(Vec::new()) };
}

/// Clears the registry before a parse.
pub(crate) fn begin() {
    SOURCES.with(|s| s.borrow_mut().clear());
}

fn expand_box(me: &mut MacroExpander) -> ParseResult<Vec<Token>> {
    expand(me, None)
}

fn expand_highlight(me: &mut MacroExpander) -> ParseResult<Vec<Token>> {
    let arg = me.consume_arg(None)?;
    let spec = arg_text(&arg.tokens);
    let color = crate::parse_finite_color(spec.trim()).ok_or_else(|| {
        ParseError::new(
            format!("invalid \\ratexHighlight color '{spec}'"),
            Some(&arg.start),
        )
    })?;
    expand(me, Some(color))
}

fn expand(me: &mut MacroExpander, highlight: Option<Color>) -> ParseResult<Vec<Token>> {
    let id_arg = me.consume_arg(None)?;
    let id = arg_text(&id_arg.tokens);
    if !is_valid_id(&id) {
        return Err(ParseError::new(
            format!("invalid box id '{id}': use letters, digits, '_', '.', ':' or '-'"),
            Some(&id_arg.start),
        ));
    }
    let body = me.consume_arg(None)?;
    let index = SOURCES.with(|s| {
        let mut s = s.borrow_mut();
        s.push(BoxSource {
            id,
            body: body_span(&body.start, &body.end, &body.tokens),
            highlight,
        });
        s.len() - 1
    });

    // \htmlStyle{ratex-box:N}{<body>}, in stack order (last token first).
    let at = body.start.loc.start;
    let synthetic = |text: String| Token::new(text, at, at);
    let mut tokens = Vec::with_capacity(body.tokens.len() + 6);
    tokens.push(synthetic("}".into()));
    tokens.extend(body.tokens);
    tokens.push(synthetic("{".into()));
    tokens.push(synthetic("}".into()));
    tokens.push(synthetic(format!("{STYLE_PREFIX}{index}")));
    tokens.push(synthetic("{".into()));
    tokens.push(synthetic("\\htmlStyle".into()));
    Ok(tokens)
}

/// Concatenated text of an argument's tokens (which arrive in stack order).
fn arg_text(tokens: &[Token]) -> String {
    tokens.iter().rev().map(|t| t.text.as_str()).collect()
}

fn is_valid_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// Candidate source range of a macro argument's contents: inside the braces
/// for `{...}`, the token itself otherwise. Checked against the source text
/// in [`Marks::extract`], since tokens from macro expansions carry locations
/// in the macro's own text.
fn body_span(start: &Token, end: &Token, tokens: &[Token]) -> Option<(usize, usize, bool)> {
    let braced = start.text == "{";
    let (from, to) = if braced {
        (start.loc.end, end.loc.start)
    } else {
        (start.loc.start, end.loc.end)
    };
    let inside = |loc: &SourceLocation| loc.start >= from && loc.end <= to;
    (from <= to && tokens.iter().all(|t| inside(&t.loc))).then_some((from, to, braced))
}

/// The marked boxes of one parse.
pub(crate) struct Marks {
    sources: Vec<BoxSource>,
    /// Source index of each marked `Html` node, by instance number.
    instances: Vec<usize>,
}

/// Takes the registry filled during the parse and marks every box wrapper in
/// `nodes`. `None` when the formula has no boxes.
pub(crate) fn mark(nodes: &mut Vec<ParseNode>) -> Option<Marks> {
    let sources = SOURCES.with(|s| std::mem::take(&mut *s.borrow_mut()));
    if sources.is_empty() {
        return None;
    }
    let mut marks = Marks {
        sources,
        instances: Vec::new(),
    };
    marks.list(nodes);
    Some(marks)
}

fn marker_color(instance: usize) -> String {
    format!("#7a{instance:04x}00")
}

fn marker_instance(color: &Color) -> Option<usize> {
    let byte = |c: f32| {
        let v = (c * 255.0).round();
        ((c * 255.0 - v).abs() < 1e-3 && (0.0..=255.0).contains(&v)).then_some(v as usize)
    };
    if color.a != 0.0 || byte(color.r)? != 0x7a {
        return None;
    }
    Some(byte(color.g)? << 8 | byte(color.b)?)
}

impl Marks {
    /// Source index of a box wrapper that is not marked yet.
    fn box_source(&self, node: &ParseNode) -> Option<usize> {
        let ParseNode::Html { attributes, .. } = node else {
            return None;
        };
        let index: usize = attributes
            .get("style")?
            .strip_prefix(STYLE_PREFIX)?
            .parse()
            .ok()?;
        (index < self.sources.len()).then_some(index)
    }

    fn new_instance(&mut self, source: usize) -> Option<String> {
        if self.instances.len() >= MAX_INSTANCES {
            return None;
        }
        self.instances.push(source);
        Some(format!(
            "background-color:{}",
            marker_color(self.instances.len() - 1)
        ))
    }

    /// Marks a math or text list, splitting box wrappers in math mode into
    /// one wrapper per child so spacing sees the same neighbors as unboxed.
    fn list(&mut self, nodes: &mut Vec<ParseNode>) {
        if !nodes.iter().any(|n| self.box_source(n).is_some()) {
            for node in nodes.iter_mut() {
                self.node(node);
            }
            return;
        }
        let mut out = Vec::with_capacity(nodes.len());
        for mut node in std::mem::take(nodes) {
            let Some(source) = self.box_source(&node) else {
                self.node(&mut node);
                out.push(node);
                continue;
            };
            let ParseNode::Html {
                mode,
                mut attributes,
                mut body,
                ..
            } = node
            else {
                unreachable!("box_source only accepts Html nodes");
            };
            let style = self.new_instance(source);
            self.list(&mut body);
            let Some(style) = style else {
                // Out of marker colors: keep the body, drop the box.
                out.extend(body);
                continue;
            };
            attributes.insert("style".into(), style);
            if mode != Mode::Math || body.len() <= 1 {
                out.push(ParseNode::Html {
                    mode,
                    attributes,
                    body,
                    loc: None,
                });
                continue;
            }
            for child in body {
                if matches!(child, ParseNode::Cr { .. }) {
                    out.push(child);
                } else {
                    out.push(ParseNode::Html {
                        mode,
                        attributes: attributes.clone(),
                        body: vec![child],
                        loc: None,
                    });
                }
            }
        }
        *nodes = out;
    }

    /// Marks a node in a single-node slot (script, fraction part, array
    /// cell...), where a box wrapper stays whole.
    fn node(&mut self, node: &mut ParseNode) {
        if let Some(source) = self.box_source(node) {
            let style = self.new_instance(source);
            if let ParseNode::Html {
                attributes, body, ..
            } = node
            {
                self.list(body);
                match style {
                    Some(style) => attributes.insert("style".into(), style),
                    None => attributes.remove("style"),
                };
            }
            return;
        }
        match node {
            ParseNode::OrdGroup { body, .. }
            | ParseNode::OperatorName { body, .. }
            | ParseNode::Text { body, .. }
            | ParseNode::Color { body, .. }
            | ParseNode::Styling { body, .. }
            | ParseNode::Sizing { body, .. }
            | ParseNode::LeftRight { body, .. }
            | ParseNode::Phantom { body, .. }
            | ParseNode::MClass { body, .. }
            | ParseNode::Href { body, .. }
            | ParseNode::HBox { body, .. }
            | ParseNode::Pmb { body, .. }
            | ParseNode::Html { body, .. }
            | ParseNode::Op {
                body: Some(body), ..
            } => self.list(body),
            ParseNode::SupSub { base, sup, sub, .. } => {
                for slot in [base, sup, sub].into_iter().flatten() {
                    self.node(slot);
                }
            }
            ParseNode::GenFrac { numer, denom, .. } => {
                self.node(numer);
                self.node(denom);
            }
            ParseNode::Sqrt { body, index, .. } => {
                self.node(body);
                if let Some(index) = index {
                    self.node(index);
                }
            }
            ParseNode::Accent { base, .. }
            | ParseNode::AccentUnder { base, .. }
            | ParseNode::HorizBrace { base, .. }
            | ParseNode::Font { body: base, .. }
            | ParseNode::Overline { body: base, .. }
            | ParseNode::Underline { body: base, .. }
            | ParseNode::VPhantom { body: base, .. }
            | ParseNode::Smash { body: base, .. }
            | ParseNode::Enclose { body: base, .. }
            | ParseNode::Lap { body: base, .. }
            | ParseNode::RaiseBox { body: base, .. }
            | ParseNode::VCenter { body: base, .. }
            | ParseNode::Environment {
                name_group: base, ..
            }
            | ParseNode::CdLabel { label: base, .. }
            | ParseNode::CdLabelParent { fragment: base, .. } => self.node(base),
            ParseNode::XArrow { body, below, .. } => {
                self.node(body);
                if let Some(below) = below {
                    self.node(below);
                }
            }
            ParseNode::CdArrow {
                label_above,
                label_below,
                ..
            } => {
                for label in [label_above, label_below].into_iter().flatten() {
                    self.node(label);
                }
            }
            ParseNode::Array { body, tags, .. } => {
                for cell in body.iter_mut().flatten() {
                    self.node(cell);
                }
                for tag in tags.iter_mut().flatten() {
                    if let ArrayTag::Explicit(nodes) = tag {
                        self.list(nodes);
                    }
                }
            }
            ParseNode::MathChoice {
                display,
                text,
                script,
                scriptscript,
                ..
            } => {
                for branch in [display, text, script, scriptscript] {
                    self.list(branch);
                }
            }
            ParseNode::Tag { body, tag, .. } => {
                self.list(body);
                self.list(tag);
            }
            ParseNode::HtmlMathMl { html, mathml, .. } => {
                self.list(html);
                self.list(mathml);
            }
            ParseNode::ProofTree { tree, .. } => self.branch(tree),
            _ => {}
        }
    }

    fn branch(&mut self, branch: &mut ProofBranch) {
        self.list(&mut branch.conclusion);
        for label in [&mut branch.left_label, &mut branch.right_label]
            .into_iter()
            .flatten()
        {
            self.list(label);
        }
        for premise in &mut branch.premises {
            self.branch(premise);
        }
    }

    /// Removes the marker rects from `list` and returns the boxes they
    /// outline, outer boxes before the boxes nested in them. Body spans are
    /// mapped onto the input with `span` (see `input_span`).
    pub(crate) fn extract(
        &self,
        list: &mut DisplayList,
        source: &str,
        span: impl Fn(usize, usize) -> Option<(usize, usize)>,
    ) -> Vec<SubtermBox> {
        // Union of each instance's pieces, and where its first piece was.
        let mut bounds: HashMap<usize, [f64; 4]> = HashMap::new();
        let mut first_piece: Vec<Option<usize>> = Vec::with_capacity(list.items.len());
        let items = std::mem::take(&mut list.items);
        let mut kept = Vec::with_capacity(items.len());
        for item in items {
            let instance = match &item {
                DisplayItem::Rect { color, .. } => {
                    marker_instance(color).filter(|&k| k < self.instances.len())
                }
                _ => None,
            };
            let (
                Some(k),
                DisplayItem::Rect {
                    x,
                    y,
                    width,
                    height,
                    ..
                },
            ) = (instance, &item)
            else {
                kept.push(item);
                first_piece.push(None);
                continue;
            };
            let piece = [*x, *y, x + width, y + height];
            match bounds.get_mut(&k) {
                Some(b) => {
                    b[0] = b[0].min(piece[0]);
                    b[1] = b[1].min(piece[1]);
                    b[2] = b[2].max(piece[2]);
                    b[3] = b[3].max(piece[3]);
                }
                None => {
                    bounds.insert(k, piece);
                    // Placeholder for the highlight, filled in below.
                    first_piece.push(Some(k));
                    kept.push(item);
                }
            }
        }

        let mut boxes = Vec::with_capacity(bounds.len());
        let mut out = Vec::with_capacity(kept.len());
        for (item, piece) in kept.into_iter().zip(first_piece) {
            let Some(k) = piece else {
                out.push(item);
                continue;
            };
            let [x0, y0, x1, y1] = bounds[&k];
            let source_box = &self.sources[self.instances[k]];
            if let Some(color) = source_box.highlight {
                out.push(DisplayItem::Rect {
                    x: x0,
                    y: y0,
                    width: x1 - x0,
                    height: y1 - y0,
                    color,
                });
            }
            let body = source_box
                .body
                .filter(|&(from, to, braced)| typed_in(source, from, to, braced))
                .and_then(|(from, to, _)| span(from, to));
            boxes.push((
                self.instances[k],
                k,
                SubtermBox {
                    id: source_box.id.clone(),
                    x: x0,
                    y: y0,
                    width: x1 - x0,
                    height: y1 - y0,
                    start: body.map(|b| b.0),
                    end: body.map(|b| b.1),
                },
            ));
        }
        list.items = out;
        // Expansion order is source order, and an outer box expands before
        // the boxes in its body.
        boxes.sort_by_key(|&(source, instance, _)| (source, instance));
        boxes.into_iter().map(|(_, _, b)| b).collect()
    }
}

/// Whether `from..to` is an argument as typed in `source`: in range, and
/// between braces if it was braced.
fn typed_in(source: &str, from: usize, to: usize, braced: bool) -> bool {
    if source.get(from..to).is_none() {
        return false;
    }
    !braced || (source[..from].ends_with('{') && source[to..].starts_with('}'))
}

/// A sub-expression box in display-list coordinates (em, y down, origin at
/// the top-left of the formula's box; see `DisplayList`).
#[derive(Debug, Clone, serde::Serialize)]
pub(crate) struct SubtermBox {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Byte range of the body in the input (inside its braces), when the
    /// body was typed in the input rather than produced by a macro.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<usize>,
}

/// Appends one invisible `<rect data-ratex-box="id">` per box to `svg` (a
/// document from `ratex_svg`, mapped with the same `font_size`/`padding`),
/// in [`Marks::extract`] order so inner boxes sit on top for hit testing.
/// `pointer-events="all"` makes the unfilled rects hit targets.
pub(crate) fn add_svg_hit_areas(
    mut svg: String,
    boxes: &[SubtermBox],
    font_size: f64,
    padding: f64,
) -> String {
    use crate::svg::Num;
    use std::fmt::Write;
    if boxes.is_empty() || !svg.ends_with("</svg>") {
        return svg;
    }
    svg.truncate(svg.len() - "</svg>".len());
    let user = |em: f64| em * font_size;
    for b in boxes {
        // Ids are restricted to [A-Za-z0-9_.:-], which need no escaping.
        let _ = write!(
            svg,
            r#"<rect data-ratex-box="{}" x="{}" y="{}" width="{}" height="{}""#,
            b.id,
            Num(user(b.x) + padding),
            Num(user(b.y) + padding),
            Num(user(b.width)),
            Num(user(b.height)),
        );
        if let (Some(start), Some(end)) = (b.start, b.end) {
            let _ = write!(svg, r#" data-ratex-start="{start}" data-ratex-end="{end}""#);
        }
        svg.push_str(r#" fill="none" pointer-events="all"/>"#);
    }
    svg.push_str("</svg>");
    svg
}
