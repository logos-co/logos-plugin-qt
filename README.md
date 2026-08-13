# logos-plugin-qt

Everything specific to running a Logos module as a **Qt 6 plugin**, in one repo:
the build logic logos-module-builder delegates to, and the runtime that build
produces plugins against. Keeping both here is what lets the plugin technology
be swapped without touching the module builder or individual modules.

## Outputs

| Output | What it is |
|---|---|
| `lib` / `rawLib` | The Nix build functions (`buildPlugin`, `buildHeaders`, `devShellInputs`). `rawLib` takes its Logos deps as arguments; `lib` pre-fills them from this flake. |
| `packages.<sys>.cmake-module` | `LogosModule.cmake` — the CMake half of the plugin build. Also the `default` package. |
| `packages.<sys>.logos-qt-host` | The **Qt host runtime** a plugin links: `LogosAPI`, `LogosAPIProvider`, `LogosProviderBase` + the `LOGOS_PROVIDER` / `LOGOS_METHOD` macros, the legacy `QtProviderObject` adapter, and `core/interface.h`. Static library, headers, and a `find_package(logos-qt-host)` config. |
| `packages.<sys>.logos-qt-host-generator` | Emits the Qt plugin glue around a cdylib module's C ABI (`<name>_cdylib_glue.{h,cpp}`) from its LIDL contract. |

The first two are pure Nix / CMake and stay that way: nothing reachable from
`lib`, `rawLib` or `cmake-module` mentions the two C++ derivations, so a
consumer that only wants the build functions never realises a Qt or protocol
build to get them.

## Layout

```
lib/                  the Nix build functions (buildPlugin, buildHeaders)
cmake/                LogosModule.cmake
cpp/                  the Qt host runtime library (logos-qt-host)
core/interface.h      the legacy Qt plugin interface (PluginInterface)
qt-host-generator/    the cdylib -> Qt-plugin glue emitter
nix/                  derivations for the two C++ outputs
tests/                flake checks
```
