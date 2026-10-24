// RaTeX in the browser and Node.js, over the C ABI of ratex_ffi.wasm (see
// packages/ratex/rust/src/lib.rs): strings cross as (pointer, length) UTF-8
// spans staged with ratex_alloc, and every render returns a buffer handle
// carrying a status code and a payload.

/**
 * @typedef {import("./index.d.ts").RenderOptions} RenderOptions
 * @typedef {import("./index.d.ts").RenderIntoOptions} RenderIntoOptions
 * @typedef {import("./index.d.ts").DisplayList} DisplayList
 * @typedef {import("./index.d.ts").Box} Box
 * @typedef {import("./index.d.ts").WasmSource} WasmSource
 * @typedef {import("./index.d.ts").HtmlTarget} HtmlTarget
 * @typedef {"ratex_render_svg" | "ratex_render_display_list"} RenderFn
 *
 * @typedef {object} RatexExports The C ABI, as seen from JS.
 * @property {WebAssembly.Memory} memory
 * @property {(len: number) => number} ratex_alloc
 * @property {(ptr: number, len: number) => void} ratex_free
 * @property {(input: number, inputLen: number, opts: number, optsLen: number) => number}
 *   ratex_render_svg
 * @property {(input: number, inputLen: number, opts: number, optsLen: number) => number}
 *   ratex_render_display_list
 * @property {(buf: number) => number} ratex_buffer_status
 * @property {(buf: number) => number} ratex_buffer_data
 * @property {(buf: number) => number} ratex_buffer_len
 * @property {(buf: number) => void} ratex_buffer_free
 * @property {() => number} ratex_version_ptr
 * @property {() => number} ratex_version_len
 */

/** Status codes of the engine's result buffers. */
export const Status = Object.freeze({
  OK: 0,
  PARSE_ERROR: 1,
  INVALID_INPUT: 2,
  INTERNAL_ERROR: 3,
});

const STATUS_NAMES = Object.fromEntries(
  Object.entries(Status).map(([name, code]) => [code, name]),
);

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8");

/**
 * A failed render. `status` is one of {@link Status}; for parse errors
 * `start`/`end` are byte offsets into the UTF-8 input (null when the engine
 * could not place the error) and `charStart`/`charEnd` the same positions
 * as string indices.
 */
export class RatexError extends Error {
  /**
   * @param {number} status
   * @param {{message?: string, start?: number | null, end?: number | null}} payload
   * @param {string} latex
   */
  constructor(status, payload, latex) {
    super(payload.message || `ratex error (status ${status})`);
    this.name = "RatexError";
    this.status = status;
    this.code = STATUS_NAMES[status] ?? "INTERNAL_ERROR";
    this.start = payload.start ?? null;
    this.end = payload.end ?? null;
    this.charStart = charIndex(latex, this.start);
    this.charEnd = charIndex(latex, this.end);
  }
}

/** A loaded engine. Obtain one with {@link load}. */
export class Ratex {
  /** @param {WebAssembly.Instance} instance */
  constructor(instance) {
    const e = instance.exports;
    for (const name of REQUIRED_EXPORTS) {
      if (!(name in e)) {
        throw new Error(`not a ratex_ffi module: missing export ${name}`);
      }
    }
    this.exports = /** @type {RatexExports} */ (/** @type {unknown} */ (e));
    /** The engine (ratex_ffi crate) version. */
    this.version = this.#read(this.exports.ratex_version_ptr(), this.exports.ratex_version_len());
  }

  /**
   * Renders `latex` to a self-contained SVG document (glyph outlines
   * embedded). A formula with `\ratexBox`es ends with one invisible
   * `<rect data-ratex-box="id">` hit area per box.
   * @param {string} latex
   * @param {RenderOptions} [options]
   * @returns {string}
   */
  renderSvg(latex, options) {
    return this.#render("ratex_render_svg", latex, options);
  }

  /**
   * Lays out `latex` and returns the display list (protocol version 1).
   * @param {string} latex
   * @param {RenderOptions} [options]
   * @returns {DisplayList}
   */
  renderDisplayList(latex, options) {
    const list = JSON.parse(this.#render("ratex_render_display_list", latex, options));
    if (list.boxes) {
      list.boxes = list.boxes.map((/** @type {Box} */ box) => withCharSpan(box, latex));
    }
    return list;
  }

  /**
   * The `\ratexBox`/`\ratexHighlight` boxes of `latex`, outermost first, in
   * em units with y down from the top of the formula.
   * @param {string} latex
   * @param {RenderOptions} [options]
   * @returns {Box[]}
   */
  boxes(latex, options) {
    return this.renderDisplayList(latex, options).boxes ?? [];
  }

  /**
   * Renders `latex` into `element` as inline SVG. Never throws: a parse
   * error shows its message in a `<span class="ratex-error">`, any other
   * failure shows the source in a `<code>`.
   * @param {HtmlTarget | null | undefined} element
   * @param {string} latex
   * @param {RenderIntoOptions} [options]
   * @returns {RatexError | null} the error, if rendering failed
   */
  renderInto(element, latex, options) {
    return renderWith(this, element, latex, options);
  }

  /**
   * @param {RenderFn} fn
   * @param {string} latex
   * @param {RenderOptions | undefined} options
   */
  #render(fn, latex, options) {
    const { status, payload } = this.call(fn, latex, options ?? {});
    if (status === Status.OK) return payload;
    let error;
    try {
      error = JSON.parse(payload);
    } catch {
      error = { message: payload };
    }
    throw new RatexError(status, error, latex);
  }

  /**
   * Calls a render entry point of the C ABI with raw options, returning the
   * status and the payload as text. Throws only if the module misbehaves.
   * @param {RenderFn} fn
   * @param {string} latex
   * @param {object} options
   * @returns {{status: number, payload: string}}
   */
  call(fn, latex, options) {
    const e = this.exports;
    const input = encoder.encode(String(latex));
    const opts = encoder.encode(JSON.stringify(options));
    let inputPtr = 0;
    let optsPtr = 0;
    try {
      inputPtr = this.#stage(input);
      optsPtr = this.#stage(opts);
      const buf = e[fn](inputPtr, input.length, optsPtr, opts.length) >>> 0;
      try {
        const status = e.ratex_buffer_status(buf);
        const payload = this.#read(e.ratex_buffer_data(buf), e.ratex_buffer_len(buf));
        return { status, payload };
      } finally {
        e.ratex_buffer_free(buf);
      }
    } finally {
      if (inputPtr) e.ratex_free(inputPtr, input.length);
      if (optsPtr) e.ratex_free(optsPtr, opts.length);
    }
  }

  /** @param {Uint8Array} bytes */
  #stage(bytes) {
    if (!bytes.length) return 0;
    const ptr = this.exports.ratex_alloc(bytes.length) >>> 0;
    if (!ptr) throw new Error("ratex_alloc failed");
    // Views go stale when memory grows, so take a fresh one per call.
    new Uint8Array(this.exports.memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  /**
   * @param {number} ptr
   * @param {number} len
   */
  #read(ptr, len) {
    len >>>= 0;
    if (!len) return "";
    return decoder.decode(new Uint8Array(this.exports.memory.buffer, ptr >>> 0, len));
  }
}

const REQUIRED_EXPORTS = [
  "memory",
  "ratex_alloc",
  "ratex_free",
  "ratex_render_svg",
  "ratex_render_display_list",
  "ratex_buffer_status",
  "ratex_buffer_data",
  "ratex_buffer_len",
  "ratex_buffer_free",
  "ratex_version_ptr",
  "ratex_version_len",
];

/** @type {Ratex | null} */
let current = null;

/**
 * Loads the engine and makes it the one the module-level functions use.
 *
 * `source` is a URL (a string resolves against the page in browsers; in
 * Node.js a string without a scheme is a file path, and `file:` URLs are
 * read from disk), a `Response` or a promise of one, the module's bytes, or
 * a compiled `WebAssembly.Module`. It defaults to the `ratex_ffi.wasm` next
 * to this file.
 * @param {WasmSource} [source]
 * @returns {Promise<Ratex>}
 */
export async function load(source = new URL("./ratex_ffi.wasm", import.meta.url)) {
  const module = await compile(await source);
  // Modules built by tool/build_wasm.sh have no imports. Builds with the
  // crate's default features declare a few wasm-bindgen ones that rendering
  // never calls; satisfy them with stubs that fail loudly.
  /** @type {Record<string, Record<string, () => never>>} */
  const imports = {};
  for (const { module: name, name: field } of WebAssembly.Module.imports(module)) {
    (imports[name] ??= {})[field] = () => {
      throw new Error(`unexpected wasm import call: ${name}.${field}`);
    };
  }
  current = new Ratex(await WebAssembly.instantiate(module, imports));
  return current;
}

/**
 * @param {Awaited<WasmSource>} source
 * @returns {Promise<WebAssembly.Module>}
 */
async function compile(source) {
  if (source instanceof WebAssembly.Module) return source;
  if (typeof source === "string" || source instanceof URL) {
    const base = globalThis.location?.href;
    const isPath = typeof source === "string" && !base && !/^[a-z][a-z0-9+.-]+:/i.test(source);
    const url = isPath ? null : new URL(source, base);
    if (!url || url.protocol === "file:") {
      const { readFile } = await import("node:fs/promises");
      return WebAssembly.compile(await readFile(url ?? source));
    }
    source = await fetch(url);
  }
  if (typeof Response !== "undefined" && source instanceof Response) {
    if (!source.ok) {
      throw new Error(`failed to fetch ratex_ffi.wasm: HTTP ${source.status}`);
    }
    const type = source.headers.get("content-type") ?? "";
    if (WebAssembly.compileStreaming && type.startsWith("application/wasm")) {
      return WebAssembly.compileStreaming(source);
    }
    return WebAssembly.compile(await source.arrayBuffer());
  }
  return WebAssembly.compile(/** @type {BufferSource} */ (source));
}

/** The engine {@link load} last loaded, or null. */
export function engine() {
  return current;
}

function loaded() {
  if (!current) throw new Error("ratex_ffi.wasm is not loaded; await load() first");
  return current;
}

/**
 * {@link Ratex#renderSvg} on the loaded engine.
 * @param {string} latex
 * @param {RenderOptions} [options]
 */
export function renderSvg(latex, options) {
  return loaded().renderSvg(latex, options);
}

/**
 * {@link Ratex#renderDisplayList} on the loaded engine.
 * @param {string} latex
 * @param {RenderOptions} [options]
 */
export function renderDisplayList(latex, options) {
  return loaded().renderDisplayList(latex, options);
}

/**
 * {@link Ratex#boxes} on the loaded engine.
 * @param {string} latex
 * @param {RenderOptions} [options]
 */
export function boxes(latex, options) {
  return loaded().boxes(latex, options);
}

/**
 * {@link Ratex#renderInto} on the loaded engine. Before {@link load}
 * finishes it shows the source in a `<code>` and returns null.
 * @param {HtmlTarget | null | undefined} element
 * @param {string} latex
 * @param {RenderIntoOptions} [options]
 */
export function renderInto(element, latex, options) {
  return renderWith(current, element, latex, options);
}

/**
 * @param {Ratex | null} ratex
 * @param {HtmlTarget | null | undefined} element
 * @param {string} latex
 * @param {RenderIntoOptions} [options]
 */
function renderWith(ratex, element, latex, options = {}) {
  if (!element) return null;
  const { errorClass = "ratex-error", ...renderOptions } = options;
  if (!ratex) {
    element.innerHTML = `<code>${escapeHtml(latex)}</code>`;
    return null;
  }
  try {
    element.innerHTML = ratex.renderSvg(latex, renderOptions);
    return null;
  } catch (error) {
    if (error instanceof RatexError && error.status === Status.PARSE_ERROR) {
      const message = escapeHtml(error.message);
      element.innerHTML = `<span class="${escapeHtml(errorClass)}">Parse error: ${message}</span>`;
    } else {
      element.innerHTML = `<code>${escapeHtml(latex)}</code>`;
    }
    if (error instanceof RatexError) return error;
    return new RatexError(Status.INTERNAL_ERROR, { message: String(error) }, latex);
  }
}

/** @param {unknown} text */
function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * The string index of a byte offset into `text`'s UTF-8 encoding.
 * @param {string} text
 * @param {number | null | undefined} byteOffset
 */
function charIndex(text, byteOffset) {
  if (byteOffset == null) return null;
  const bytes = encoder.encode(String(text));
  return decoder.decode(bytes.subarray(0, byteOffset)).length;
}

/**
 * @param {Box} box
 * @param {string} latex
 */
function withCharSpan(box, latex) {
  if (box.start == null) return box;
  return {
    ...box,
    charStart: charIndex(latex, box.start),
    charEnd: charIndex(latex, box.end),
  };
}
