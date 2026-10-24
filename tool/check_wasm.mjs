// Checks a built ratex_ffi.wasm: no imports, no wasm-bindgen exports, the
// whole C ABI exported, and (optionally) a size budget. CI runs it on the
// output of tool/build_wasm.sh:
//   node tool/check_wasm.mjs <module.wasm> [--max-bytes N] [--max-gzip-bytes N]
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    "max-bytes": { type: "string" },
    "max-gzip-bytes": { type: "string" },
  },
});
if (positionals.length !== 1) {
  console.error(
    "usage: node tool/check_wasm.mjs <module.wasm> [--max-bytes N] [--max-gzip-bytes N]",
  );
  process.exit(2);
}

const bytes = readFileSync(positionals[0]);
const module = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(module);
const exports = WebAssembly.Module.exports(module).map((e) => e.name);
const gzipped = gzipSync(bytes, { level: 9 }).length;
const abi = [
  "memory",
  "ratex_alloc",
  "ratex_free",
  "ratex_render_display_list",
  "ratex_render_svg",
  "ratex_buffer_status",
  "ratex_buffer_data",
  "ratex_buffer_len",
  "ratex_buffer_free",
  "ratex_version_ptr",
  "ratex_version_len",
];

const failures = [];
if (imports.length) {
  const names = imports.map((i) => `${i.module}.${i.name}`);
  failures.push(`${imports.length} imports (want none): ${names.slice(0, 5).join(", ")}`);
}
const bindgen = exports.filter((name) => name.startsWith("__wbindgen"));
if (bindgen.length) failures.push(`${bindgen.length} __wbindgen* exports (want none)`);
const missing = abi.filter((name) => !exports.includes(name));
if (missing.length) failures.push(`missing exports: ${missing.join(", ")}`);
const budget = (option, actual, what) => {
  const max = values[option] === undefined ? Infinity : Number(values[option]);
  if (actual > max) failures.push(`${what} is ${actual} bytes, over the ${max}-byte budget`);
};
budget("max-bytes", bytes.length, "module");
budget("max-gzip-bytes", gzipped, "gzipped module");

console.log(
  `${positionals[0]}: ${bytes.length} bytes, ${gzipped} gzipped, ` +
    `${imports.length} imports, ${exports.length} exports`,
);
for (const failure of failures) console.error(`error: ${failure}`);
process.exit(failures.length ? 1 : 0);
