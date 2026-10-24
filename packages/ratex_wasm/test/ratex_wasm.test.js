import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { before, describe, test } from "node:test";

import * as ratex from "../index.js";
import { fakeElement, skipUnlessBuilt, wasmPath } from "./helpers.js";

const QUADRATIC = String.raw`\frac{-b \pm \sqrt{b^2-4ac}}{2a}`;

/** @param {{x: number, y: number, width: number, height: number}} outer */
function contains(outer, inner) {
  const eps = 1e-9;
  return (
    inner.x >= outer.x - eps &&
    inner.y >= outer.y - eps &&
    inner.x + inner.width <= outer.x + outer.width + eps &&
    inner.y + inner.height <= outer.y + outer.height + eps
  );
}

describe("@manymath/ratex-wasm", { skip: skipUnlessBuilt }, () => {
  /** @type {import("../index.js").Ratex} */
  let engine;

  before(async () => {
    engine = await ratex.load(wasmPath);
  });

  test("the module needs no imports and exports only the C ABI", async () => {
    const module = await WebAssembly.compile(await readFile(wasmPath));
    assert.deepEqual(WebAssembly.Module.imports(module), []);
    const exports = WebAssembly.Module.exports(module).map((e) => e.name);
    assert.ok(!exports.some((name) => name.startsWith("__wbindgen")), exports.join());
    assert.ok(exports.includes("ratex_render_svg"));
  });

  test("loads from a path, a file URL, bytes, a Response, or a Module", async () => {
    const bytes = await readFile(wasmPath);
    const sources = [
      pathToFileURL(wasmPath),
      pathToFileURL(wasmPath).href,
      bytes,
      new Response(bytes, { headers: { "content-type": "application/wasm" } }),
      Promise.resolve(new Response(bytes)),
      await WebAssembly.compile(bytes),
    ];
    for (const source of sources) {
      const loaded = await ratex.load(source);
      assert.equal(loaded.version, engine.version);
      assert.match(loaded.renderSvg("x"), /^<svg /);
    }
    if (!process.env.RATEX_WASM) {
      // The default: ratex_ffi.wasm next to index.js.
      assert.equal((await ratex.load()).version, engine.version);
    }
    await assert.rejects(ratex.load(new Response("", { status: 404 })), /HTTP 404/);
    engine = await ratex.load(wasmPath);
    assert.equal(ratex.engine(), engine);
  });

  test("reports the engine version", () => {
    assert.match(engine.version, /^\d+\.\d+\.\d+/);
  });

  test("renders self-contained SVG", () => {
    const svg = ratex.renderSvg(QUADRATIC, { displayMode: true, fontSize: 22 });
    assert.match(svg, /^<svg xmlns="http:\/\/www.w3.org\/2000\/svg"/);
    assert.ok(svg.endsWith("</svg>"));
    assert.ok(!svg.includes("<text"), "glyphs are outlined");
    const big = ratex.renderSvg(QUADRATIC, { fontSize: 44 });
    const width = (s) => Number(/ width="([\d.]+)pt"/.exec(s)[1]);
    assert.ok(width(big) > width(svg) * 1.5);
  });

  test("renders display lists", () => {
    const list = ratex.renderDisplayList(QUADRATIC);
    assert.equal(list.version, 1);
    assert.ok(list.width > 0 && list.height > 0);
    assert.ok(list.items.some((item) => item.type === "GlyphPath"));
    assert.ok(list.items.some((item) => item.type === "Line"), "fraction bar");
    assert.equal(list.boxes, undefined);
    const inline = ratex.renderDisplayList(String.raw`\sum_{i=0}^n i`, { displayMode: false });
    const display = ratex.renderDisplayList(String.raw`\sum_{i=0}^n i`, { displayMode: true });
    assert.ok(inline.height + inline.depth < display.height + display.depth);
    const red = ratex.renderDisplayList("x", { color: "#ff0000" });
    assert.equal(red.items[0].color.r, 1);
  });

  test("reports nested boxes with their source spans", () => {
    const latex = String.raw`\ratexBox{lhs}{\frac{\ratexBox{num}{dy}}{dx}} = \ratexBox{rhs}{2x}`;
    const found = ratex.boxes(latex);
    assert.deepEqual(
      found.map((b) => b.id),
      ["lhs", "num", "rhs"],
    );
    const [lhs, num, rhs] = found;
    assert.ok(contains(lhs, num));
    assert.ok(rhs.x >= lhs.x + lhs.width);
    const lhsBody = String.raw`\frac{\ratexBox{num}{dy}}{dx}`;
    assert.equal(latex.slice(lhs.charStart, lhs.charEnd), lhsBody);
    assert.equal(latex.slice(num.charStart, num.charEnd), "dy");
    // Boxes do not move anything.
    const plain = ratex.renderDisplayList(String.raw`\frac{dy}{dx} = 2x`);
    assert.deepEqual(ratex.renderDisplayList(latex).items, plain.items);
    assert.deepEqual(ratex.boxes("x"), []);
  });

  test("string indices of spans account for multi-byte characters", () => {
    const latex = String.raw`\text{é} + \ratexBox{t}{\alpha}`;
    const [box] = ratex.boxes(latex);
    assert.ok(box.end - box.start === box.charEnd - box.charStart);
    assert.equal(box.start, box.charStart + 1, "é is two bytes");
    assert.equal(latex.slice(box.charStart, box.charEnd), String.raw`\alpha`);
  });

  test("SVG output carries hit areas for boxes", () => {
    const svg = ratex.renderSvg(String.raw`\ratexBox{a}{x} + \ratexHighlight{yellow}{b}{y}`);
    assert.match(svg, /<rect data-ratex-box="a" [^>]*pointer-events="all"\/>/);
    assert.match(svg, /<rect data-ratex-box="b" /);
  });

  test("errors carry the status and the input span", () => {
    assert.throws(
      () => ratex.renderSvg(String.raw`x + \frac{a}{`),
      (error) => {
        assert.ok(error instanceof ratex.RatexError);
        assert.equal(error.status, ratex.Status.PARSE_ERROR);
        assert.equal(error.code, "PARSE_ERROR");
        assert.equal(error.start, 13);
        assert.equal(error.charStart, 13);
        return true;
      },
    );
    assert.throws(
      () => ratex.renderDisplayList("x", { color: "#nope" }),
      (error) => error.status === ratex.Status.INVALID_INPUT && /invalid color/.test(error.message),
    );
    assert.throws(() => ratex.boxes(String.raw`\ratexBox{not an id}{x}`), /invalid box id/);
  });

  test("renderInto shows SVG, parse errors, and the source on other failures", () => {
    const el = fakeElement();
    assert.equal(ratex.renderInto(el, "a^2", { fontSize: 18 }), null);
    assert.match(el.innerHTML, /^<svg /);

    const error = ratex.renderInto(el, String.raw`\frac{<a>}{`);
    assert.equal(error.status, ratex.Status.PARSE_ERROR);
    assert.match(el.innerHTML, /^<span class="ratex-error">Parse error: /);

    engine.renderInto(el, "\\frac{", { errorClass: "oops" });
    assert.match(el.innerHTML, /^<span class="oops">/);

    const invalid = ratex.renderInto(el, "a < b", { color: "#nope" });
    assert.equal(invalid.status, ratex.Status.INVALID_INPUT);
    assert.equal(el.innerHTML, "<code>a &lt; b</code>");

    assert.equal(ratex.renderInto(null, "x"), null);
  });

  test("survives many renders (no leaks into a growing heap)", () => {
    const memory = engine.exports.memory;
    for (let i = 0; i < 200; i++) engine.renderSvg(QUADRATIC);
    const after = memory.buffer.byteLength;
    for (let i = 0; i < 2000; i++) engine.renderSvg(QUADRATIC);
    assert.equal(memory.buffer.byteLength, after);
  });
});
