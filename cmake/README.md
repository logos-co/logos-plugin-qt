# `LogosView*.in` — the view-plugin templates, and why they live here

These four files are `configure_file` templates instantiated per module by
`logos_module(REP_FILE ...)`:

| template | produces | linked into |
|---|---|---|
| `LogosViewPluginBase.{h,cpp}.in` | `<Rep>ViewPluginBase` | the module plugin |
| `LogosViewReplicaFactory.{h,cpp}.in` | `<Rep>ReplicaFactoryPlugin` | `<name>_replica_factory` |

They are pure Qt: `Q_OBJECT`, `Q_PLUGIN_METADATA`, `repc`-generated
`*SimpleSource`/`*Replica` types, `qmlRegisterUncreatableMetaObject`. Nothing
outside the Qt backend can use them.

## The rule

**There is exactly one copy of each, and it is this one.** No consumer keeps a
local copy — not even a test fixture.

## Why this repo and not logos-module-builder

`LogosModule.cmake` — the code that instantiates these templates — lives in
logos-module-builder, so that repo looks like the obvious home, and the
templates did live next to it. But two consumers need them:

1. logos-module-builder's `LogosModule.cmake`, for every real `ui_qml` module;
2. this repo's `tests/rep-file-plugin` fixture, which is the check that proves
   the repc + factory pipeline still produces a loadable plugin.

The dependency runs **logos-module-builder → logos-plugin-qt**, one way. A
fixture inside logos-plugin-qt therefore cannot reach logos-module-builder, and
that is exactly how the fixture ended up holding a byte-identical second copy
with nothing comparing the two. This repo is the only place both consumers can
read from, so ownership moves to the direction that actually works: the
templates are published here, and logos-module-builder receives the directory
as `LOGOS_VIEW_TEMPLATE_DIR`.

`LogosModule.cmake` itself does **not** move back here — that file is
logos-module-builder's and stays there. Only the Qt-specific templates it
instantiates are published from this side of the edge.

## How consumers get them

* nix: `packages.<system>.logos-view-templates`, and
  `lib.buildPlugin` / `lib.generate` set `LOGOS_VIEW_TEMPLATE_DIR` in the
  build environment automatically, so a module build needs no extra wiring.
* CMake: `logos_module()` resolves `LOGOS_VIEW_TEMPLATE_DIR` (cache variable
  first, then environment) and hard-errors when it is unset. There is no
  "look next to LogosModule.cmake" fallback — a silent fallback to a second
  copy is the failure this layout exists to remove.

## The interface declared inside the templates

`LogosViewPlugin` and `LogosViewReplicaFactory` are also declared, separately,
by logos-view-module-runtime — the host that loads these plugins. That
duplication is deliberate and cannot be collapsed: a module plugin must build
against Qt alone, and logos-view-module-runtime depends on *this* repo, so the
include could only ever go the wrong way. The two declarations meet at runtime
via the IID string, where a mismatch is silent.

That pair is enforced instead of documented: logos-module-builder's
`view-interface-abi` check (it is the one repo that can see both sides) extracts
the IID and the pure-virtual signature list from each and fails on any
difference.
