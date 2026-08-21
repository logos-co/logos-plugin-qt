# Asserts the LAYERING of logos_qt_host_shared: it must OWN LogosAPI and BORROW
# everything logos-protocol owns.
#
# WHY THIS CHECK EXISTS SEPARATELY. The consumer-side symbol gate (logos-basecamp
# and logos-logoscore-cli nix/symbol-gate.nix) asserts that no in-process
# CONSUMER defines the runtime. It cannot see this failure: if
# liblogos_qt_host.dylib linked the STATIC protocol archive it would embed its
# own TokenManager, and the gate would treat that library as a provider and pass.
# The duplicate would then be one layer below anything the gate inspects.
#
# The failure is a single-word mistake -- ${LP_TARGET} instead of
# ${LP_SHARED_TARGET} in one target_link_libraries -- and it produces a library
# that builds, links, installs and loads. It surfaces only as refused
# cross-module calls at runtime, in a different repo.
#
# The positive assertion doubles as the validity control: LogosAPI must be
# DEFINED here, so a broken nm or a missing c++filt fails the check rather than
# reporting a reassuring zero.
{ pkgs, qtHost }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  definedCmd = if isDarwin then "nm -gU" else "nm -D --defined-only";
  undefCmd   = if isDarwin then "nm -gu" else "nm -D --undefined-only";
  stripAddr  = if isDarwin then "sed -E 's/^[0-9a-fA-F]+ [A-Za-z] //'" else "sed -E 's/^[0-9a-fA-F]* [A-Za-z] //'";
  stripUndef = if isDarwin then "sed -E 's/^ +U //'" else "sed -E 's/^ +U //'";
in
pkgs.runCommand "logos-qt-host-shared-runtime-layering" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.stdenv.cc.bintools ];
} ''
  set -uo pipefail
  FAIL=0
  note() { printf '  %-46s %s\n' "$1" "$2"; }
  bad()  { FAIL=1; printf '  %-46s %s\n' "$1" "$2"; }

  LIB=""
  for c in ${qtHost}/lib/liblogos_qt_host.dylib ${qtHost}/lib/liblogos_qt_host.so; do
    [ -e "$c" ] && LIB="$c" && break
  done
  [ -n "$LIB" ] || { echo "FATAL: no shared logos_qt_host under ${qtHost}/lib"; exit 1; }
  echo "library = $LIB"

  defines() { ${definedCmd} "$LIB" 2>/dev/null | c++filt 2>/dev/null | ${stripAddr} | grep -cE "^$1::" || true; }
  imports() { ${undefCmd}   "$LIB" 2>/dev/null | c++filt 2>/dev/null | ${stripUndef} | grep -cE "^$1::" || true; }

  echo
  echo "== it OWNS LogosAPI (expect >0; also the validity control) =="
  n=$(defines LogosAPI)
  if [ "$n" -gt 0 ]; then note "LogosAPI:: defined" "$n  OK"
  else bad "LogosAPI:: defined" "$n  EXPECTED >0 (or nm/c++filt is broken)"; fi

  echo
  echo "== it does NOT define what logos-protocol owns (expect 0) =="
  for sym in TokenManager LogosAPIClient; do
    n=$(defines "$sym")
    if [ "$n" -eq 0 ]; then note "$sym:: defined" "0  OK"
    else
      bad "$sym:: defined" "$n  LAYERING VIOLATION"
      echo "      logos_qt_host_shared linked the STATIC protocol archive."
      echo "      Use \''${LP_SHARED_TARGET}, not \''${LP_TARGET}, in target_link_libraries."
    fi
  done

  echo
  echo "== it BORROWS them instead (expect >0) =="
  n=$(imports TokenManager)
  if [ "$n" -gt 0 ]; then note "TokenManager:: imported" "$n  OK"
  else bad "TokenManager:: imported" "$n  EXPECTED >0"; fi

  echo
  echo "== and links the shared protocol =="
  if ${if isDarwin then ''otool -L "$LIB" 2>/dev/null'' else ''objdump -p "$LIB" 2>/dev/null''} | grep -qi 'liblogos_protocol\.\(dylib\|so\)'; then
    note "liblogos_protocol on the link line" "OK"
  else
    bad "liblogos_protocol on the link line" "MISSING — it took the archive"
  fi

  echo
  if [ "$FAIL" -eq 0 ]; then echo "LAYERING: PASS"; mkdir -p $out; echo ok > $out/result
  else echo "LAYERING: FAIL"; exit 1; fi
''
