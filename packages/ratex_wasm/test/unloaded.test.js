// Runs in its own process (node --test isolates files), before any load().
import assert from "node:assert/strict";
import { test } from "node:test";

import * as ratex from "../index.js";
import { fakeElement } from "./helpers.js";

test("before load(), renderInto shows the source and the rest throw", () => {
  assert.equal(ratex.engine(), null);
  const el = fakeElement();
  assert.equal(ratex.renderInto(el, "a<b"), null);
  assert.equal(el.innerHTML, "<code>a&lt;b</code>");
  assert.throws(() => ratex.renderSvg("x"), /await load\(\) first/);
  assert.throws(() => ratex.boxes("x"), /not loaded/);
});
