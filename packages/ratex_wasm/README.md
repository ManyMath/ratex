# @manymath/ratex-wasm

KaTeX-compatible math rendering for browsers and Node.js: the RaTeX engine
(`packages/ratex/rust`) as a WebAssembly module with no imports, behind a
small JS API. Not published; use it from this repository.

## Build

`ratex_ffi.wasm` is not checked in. Build it (needs Rust with the
`wasm32-unknown-unknown` target, and binaryen's `wasm-opt` for the smallest
module) and it is copied next to `index.js`:

```sh
tool/build_wasm.sh            # or: npm run build, from this directory
```

The script's own output is
`packages/ratex/rust/target/wasm32-unknown-unknown/wasm-release/ratex_ffi.opt.wasm`;
copy that file to serve the module from elsewhere.

## Use

```js
import { load, renderSvg, renderInto, boxes } from "@manymath/ratex-wasm";

await load(); // or load(url | Response | bytes | WebAssembly.Module)
const svg = renderSvg(String.raw`\frac{a}{b}`, { displayMode: true, fontSize: 22 });
renderInto(document.getElementById("formula"), String.raw`E = mc^2`, { color: "#17201c" });
```

`load()` resolves to an engine object with the same methods, for apps that
want more than one. Failed renders throw `RatexError` with `status`
(`Status.PARSE_ERROR`, `INVALID_INPUT`, `INTERNAL_ERROR`) and, for parse
errors, the position as UTF-8 byte offsets (`start`, `end`) and string
indices (`charStart`, `charEnd`). `renderInto` never throws: it shows parse
errors in a `<span class="ratex-error">` (see `errorClass`), the source in a
`<code>` otherwise and before `load()` finishes, and returns the error.

Options: `displayMode` (default `true`), `color`, and for SVG `fontSize`
(user units per em, default 40), `padding` (default 10), `strokeWidth`,
`embedGlyphs` (default `true`: outlines, no webfonts needed).

## Sub-expression boxes

`\ratexBox{id}{body}` renders `body` unchanged and reports where it is;
`\ratexHighlight{color}{id}{body}` also paints `color` behind it. Ids match
`[A-Za-z0-9_.:-]+`.

```js
boxes(String.raw`\ratexBox{lhs}{\frac{dy}{dx}} = \ratexBox{rhs}{2x}`);
// [{ id: "lhs", x, y, width, height, start, end, charStart, charEnd }, { id: "rhs", ... }]
```

Boxes come outermost first, in em with y down from the top of the formula
(the display list's coordinates); `start`/`end` locate the body in the input
when it was typed there. A box that is the base of a script
(`\ratexBox{f}{f}_2`) lays out like a braced base (`{f}_2`); box `f_2`
instead. In SVG each box is a
`<rect data-ratex-box="id" fill="none" pointer-events="all">` drawn last, so
`event.target.dataset.ratexBox` names the innermost box under the pointer.

## Test

```sh
npm test   # node --test; set RATEX_REQUIRE_WASM=1 to fail if the module is missing
```
