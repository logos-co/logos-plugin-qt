# logos-plugin-qt

Everything specific to running a Logos module as a **Qt 6 plugin**, in one repo:
the build logic logos-module-builder delegates to, and the runtime that build
produces plugins against. Keeping both here is what lets the plugin technology
be swapped without touching the module builder or individual modules.

## Outputs

| Output | What it is |
|---|---|
| `lib` / `rawLib` | The Nix build functions (`buildPlugin`, `buildHeaders`, `devShellInputs`). `rawLib` takes its Logos deps as arguments; `lib` pre-fills them from this flake. |
| `packages.<sys>.logos-qt-host` | The **Qt host runtime** a plugin links: `LogosAPI`, `LogosAPIProvider`, `LogosProviderBase` + the `LOGOS_PROVIDER` / `LOGOS_METHOD` macros, the legacy `QtProviderObject` adapter, and `core/interface.h`. Static library, headers, and a `find_package(logos-qt-host)` config. |
| `packages.<sys>.logos-qt-host-generator` | Emits the Qt plugin glue around a cdylib module's C ABI (`<name>_cdylib_glue.{h,cpp}`) from its LIDL contract. |

`logos-qt-host` is also the `default` package.

There is no `cmake-module` output and no `cmake/` directory. `LogosModule.cmake`
lives in **logos-module-builder**, and only there. This repo shipped a second
copy until the builder was made to point `LOGOS_MODULE_BUILDER_ROOT` at its own
copy for every module type: the builder only overrode that variable when a
MODULE carried the file (none does), so `ui_qml` plugins configured with this
repo's copy while core modules configured with the builder's, and the two drifted
apart in silence. The CMake module reads the builder's own variables
(`LOGOS_API_STYLE`, `LOGOS_MODULE_GO_STATIC_LIBS`, `generated_code/`), so the
builder is where it belongs.

`lib` / `rawLib` are pure Nix and stay that way: nothing reachable from them
mentions the two C++ derivations, so a consumer that only wants the build
functions never realises a Qt or protocol build to get them.

## Layout

```
lib/                  the Nix build functions (buildPlugin, buildHeaders)
cpp/                  the Qt host runtime library (logos-qt-host)
core/interface.h      the legacy Qt plugin interface (PluginInterface)
qt-host-generator/    the cdylib -> Qt-plugin glue emitter
nix/                  derivations for the two C++ outputs
tests/                flake checks
```
