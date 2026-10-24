/** Status codes of the engine's result buffers. */
export declare const Status: Readonly<{
  OK: 0;
  PARSE_ERROR: 1;
  INVALID_INPUT: 2;
  INTERNAL_ERROR: 3;
}>;

export type StatusCode = (typeof Status)[keyof typeof Status];

/** Render options; every field is optional. */
export interface RenderOptions {
  /** Display style (`$$...$$`) when true (the default), text style otherwise. */
  displayMode?: boolean;
  /**
   * Foreground color: a named color, `#rgb`, `#rgba`, `#rrggbb`,
   * `#rrggbbaa`, or `[MODEL]value`.
   */
  color?: string;
  /** SVG only: user units per em (default 40). */
  fontSize?: number;
  /** SVG only: padding on all sides, in user units (default 10). */
  padding?: number;
  /** SVG only: stroke width of unfilled paths, in user units (default 1.5). */
  strokeWidth?: number;
  /**
   * SVG only: outline glyphs from the embedded KaTeX fonts (the default);
   * false emits `<text>` that needs the KaTeX webfonts.
   */
  embedGlyphs?: boolean;
}

export interface RenderIntoOptions extends RenderOptions {
  /** Class of the `<span>` that shows a parse error (default `ratex-error`). */
  errorClass?: string;
}

/**
 * A `\ratexBox{id}{body}` / `\ratexHighlight{color}{id}{body}`, in display
 * list units: em, y down, origin at the top-left of the formula's box.
 */
export interface Box {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
  /**
   * UTF-8 byte range of the body in the input (inside its braces), present
   * when the body was typed in the input rather than assembled by a macro.
   */
  start?: number;
  end?: number;
  /** The same range as string indices, for `latex.slice(charStart, charEnd)`. */
  charStart?: number;
  charEnd?: number;
}

export interface Color {
  r: number;
  g: number;
  b: number;
  a: number;
}

export type PathCommand =
  | { type: "MoveTo" | "LineTo"; x: number; y: number }
  | { type: "QuadTo"; x1: number; y1: number; x: number; y: number }
  | {
      type: "CubicTo";
      x1: number;
      y1: number;
      x2: number;
      y2: number;
      x: number;
      y: number;
    }
  | { type: "Close" };

export type DisplayItem =
  | {
      type: "GlyphPath";
      x: number;
      y: number;
      scale: number;
      font: string;
      char_code: number;
      color: Color;
    }
  | {
      type: "Line";
      x: number;
      y: number;
      width: number;
      thickness: number;
      color: Color;
      dashed: boolean;
    }
  | { type: "Rect"; x: number; y: number; width: number; height: number; color: Color }
  | {
      type: "Path";
      x: number;
      y: number;
      commands: PathCommand[];
      fill: boolean;
      color: Color;
    };

/** DisplayList JSON, protocol version 1. Coordinates are in em, y down. */
export interface DisplayList {
  version: 1;
  width: number;
  /** Ascent above the baseline; the baseline is at `y = height`. */
  height: number;
  depth: number;
  items: DisplayItem[];
  /** Present only when the formula has boxes; outermost first. */
  boxes?: Box[];
}

export type WasmSource =
  | string
  | URL
  | Response
  | PromiseLike<Response>
  | BufferSource
  | WebAssembly.Module;

/** A failed render. */
export declare class RatexError extends Error {
  readonly status: StatusCode;
  readonly code: keyof typeof Status;
  /** Byte offsets of a parse error in the UTF-8 input, when known. */
  readonly start: number | null;
  readonly end: number | null;
  /** The same positions as string indices. */
  readonly charStart: number | null;
  readonly charEnd: number | null;
}

/** Something whose `innerHTML` can be set, normally an `Element`. */
export interface HtmlTarget {
  innerHTML: string;
}

/** A loaded engine. */
export declare class Ratex {
  constructor(instance: WebAssembly.Instance);
  /** The engine (ratex_ffi crate) version. */
  readonly version: string;
  readonly exports: WebAssembly.Exports;
  /** A self-contained SVG document; throws {@link RatexError}. */
  renderSvg(latex: string, options?: RenderOptions): string;
  /** The display list; throws {@link RatexError}. */
  renderDisplayList(latex: string, options?: RenderOptions): DisplayList;
  /** The formula's boxes, outermost first; throws {@link RatexError}. */
  boxes(latex: string, options?: RenderOptions): Box[];
  /**
   * Renders into `element` as inline SVG, never throwing: a parse error
   * shows its message in a `<span class="ratex-error">`, other failures the
   * source in a `<code>`. Returns the error, if any.
   */
  renderInto(
    element: HtmlTarget | null | undefined,
    latex: string,
    options?: RenderIntoOptions,
  ): RatexError | null;
  /** Raw C ABI call: the status and the payload as text. */
  call(
    fn: "ratex_render_svg" | "ratex_render_display_list",
    latex: string,
    options: object,
  ): { status: number; payload: string };
}

/**
 * Loads the engine (by default the `ratex_ffi.wasm` next to this module) and
 * makes it the one the module-level functions use.
 */
export declare function load(source?: WasmSource | PromiseLike<WasmSource>): Promise<Ratex>;

/** The engine {@link load} last loaded, or null. */
export declare function engine(): Ratex | null;

export declare function renderSvg(latex: string, options?: RenderOptions): string;
export declare function renderDisplayList(latex: string, options?: RenderOptions): DisplayList;
export declare function boxes(latex: string, options?: RenderOptions): Box[];
/** Like {@link Ratex.renderInto}; shows the source in a `<code>` until loaded. */
export declare function renderInto(
  element: HtmlTarget | null | undefined,
  latex: string,
  options?: RenderIntoOptions,
): RatexError | null;
