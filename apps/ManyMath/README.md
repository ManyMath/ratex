# manymath

A minimal LaTeX LaTeX editor on the ratex stack: plaintext LaTeX on
the left, the rendered document on the right, rendering on demand (the Render
button or Ctrl/Cmd+Enter). No accounts, no persistence, no cloud, that
plumbing comes later (Postgres + Garage); this is the rendering core of
ManyMath.com working end to end.

Math is typeset by the Rust RaTeX engine (natively over FFI, on the web as
WebAssembly). A deliberately small document layer handles the prose around
it: `\begin{document}`, `\maketitle` metadata, sections, paragraphs, inline
math and `\textbf`/`\textit`/`\emph`, single-level lists, comments, and
display math (`$$...$$`, `\[...\]`, `equation`/`align`/`gather`/`alignat`).

## Run (web, the primary target)

```sh
melos run native:build:web   # drops ratex_ffi.wasm into web/
flutter run -d chrome        # or: flutter build web
```

## Run (desktop)

```sh
flutter run -d linux         # cargokit builds the Rust engine automatically
```
