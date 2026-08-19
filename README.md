# logos-plugin-qt

Everything specific to running a Logos module as a **Qt 6 plugin**, in one repo:
the build logic logos-module-builder delegates to, and the runtime that build
produces plugins against. Keeping both here is what lets the plugin technology
be swapped without touching the module builder or individual modules.

## Outputs

| Output | What it is |
|---|---|
| `lib` / `rawLib` | The Nix build functions (`buildPlugin`, `generate`, `buildHeaders`, `devShellInputs`, plus `common`). `rawLib` takes its Logos deps as arguments; `lib` pre-fills them from this flake. |
| `packages.<sys>.logos-qt-host` | The **Qt host runtime** a plugin links: `LogosAPI`, `LogosAPIProvider`, `LogosProviderBase`, the legacy `QtProviderObject` adapter, and `core/interface.h`. Static library, headers, and a `find_package(logos-qt-host)` config. |
| `packages.<sys>.logos-qt-host-generator` | Emits the Qt plugin glue around a cdylib module's C ABI (`<name>_cdylib_glue.{h,cpp}`) from its LIDL contract. |
| `packages.<sys>.logos-view-templates` | The four `cmake/LogosView*.in` templates as a nameable output, so a consumer can refer to them without depending on this repo's source layout. |

`logos-qt-host` is also the `default` package.

`LogosProviderBase`'s two pure slots — `callMethod()` and `getMethods()` — are
filled by `logos-qt-host-generator --backend cdylib`, in the emitted
`<name>_cdylib_glue.cpp`. `logos_provider_object.h` also still defines the
`LOGOS_PROVIDER` / `LOGOS_METHOD` macros, but they are **vestigial**: they were
scanned by `logos-cpp-generator --provider-header` to emit a
`logos_provider_dispatch.cpp` for `interface: "provider"` modules, and that flag,
that interface value and that file are all gone (the flag is now refused with a
message naming `interface: "universal"`). Under `universal` a module's plain
public methods *are* its API — the contract is derived from the impl header
named by `codegen.impl_class` / `codegen.impl_header`, and there is no marker to
write. Nothing this repo builds expands either macro any more; they are kept
only so an older translation unit still compiles.

There is no `cmake-module` output and no `LogosModule.cmake` here.
`LogosModule.cmake` lives in **logos-module-builder**, and only there. This repo
shipped a second copy until the builder was made to point
`LOGOS_MODULE_BUILDER_ROOT` at its own copy for every module type: the builder
only overrode that variable when a MODULE carried the file (none does), so
`ui_qml` plugins configured with this repo's copy while core modules configured
with the builder's, and the two drifted apart in silence. The CMake module reads
the builder's own variables (`LOGOS_API_STYLE`, `LOGOS_MODULE_GO_STATIC_LIBS`,
`generated_code/`), so the builder is where it belongs.

`cmake/` went away with that copy, and has since come back for a narrower
reason: the four `LogosView*.in` templates `logos_module(REP_FILE ...)`
instantiates. Those had the mirror-image problem — they sat next to
`LogosModule.cmake` in the builder, but this repo's `tests/rep-file-plugin`
fixture also instantiates them and cannot reach the builder, so it kept a
byte-identical second copy with nothing comparing the two. `cmake/README.md`
has the full argument. `LogosModule.cmake` did **not** come back with them.

`lib` / `rawLib` are pure Nix and stay that way: nothing reachable from them
mentions the two C++ derivations, so a consumer that only wants the build
functions never realises a Qt or protocol build to get them.

## Layout

```
lib/                  the Nix build functions (buildPlugin, generate, buildHeaders)
cpp/                  the Qt host runtime library (logos-qt-host)
core/interface.h      the legacy Qt plugin interface (PluginInterface)
cmake/                the four LogosView*.in view-plugin templates (see cmake/README.md)
qt-host-generator/    the cdylib -> Qt-plugin glue emitter
nix/                  derivations for the two C++ outputs
tests/                flake checks
```
