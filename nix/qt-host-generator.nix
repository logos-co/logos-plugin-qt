# Builds logos-qt-host-generator — the cdylib -> Qt-plugin glue emitter.
#
# Qt Core plus the canonical LIDL frontend, and deliberately nothing else: the
# one shared-frontend helper this backend uses is inlined (see
# qt-host-generator/lidl_emit_common.h), so no SDK appears in this repo's
# inputs on account of the generator.
{ pkgs, src, logos-lidl }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host-generator";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.qt6.wrapQtAppsNoGuiHook
  ];

  buildInputs = [
    pkgs.qt6.qtbase
    logos-lidl
  ];

  cmakeFlags = [ "-GNinja" ];

  meta = with pkgs.lib; {
    description = "Emits the Qt plugin glue around a cdylib module's C ABI";
    platforms = platforms.unix;
    mainProgram = "logos-qt-host-generator";
  };
}
