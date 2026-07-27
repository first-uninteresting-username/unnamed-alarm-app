{ pkgs, lib, config, ... }:

################################################################################
#  Android development shell for NixOS — SDK lives in ~/Android/Sdk
#
#  Design goal: Nix provides the *host toolchain* (JDK, build utils, IDE,
#  libraries). Google's `sdkmanager` provides the *SDK* into a normal, mutable
#  directory that Android Studio and Gradle can write to.
#
#  This deliberately does NOT use devenv's `android.enable = true`, because that
#  module builds the SDK with nixpkgs' `androidenv` and points ANDROID_HOME at
#  an immutable /nix/store path. That is what causes the classic
#  "Failed to install the following SDK components ... The SDK directory is not
#  writable (/nix/store/...-androidsdk/libexec/android-sdk)" error whenever
#  Gradle or the IDE wants a component you did not declare in Nix.
#
#  READ ONCE: see NOTES.md — you need `programs.nix-ld.enable = true;` in your
#  NixOS configuration for the SDK's prebuilt binaries (aapt2, d8, the NDK
#  clang, the emulator) to run at all.
################################################################################

let
  ##############################################################################
  # Tunables
  ##############################################################################

  # Where the SDK lives. "$HOME/Android/Sdk" is the location Android Studio
  # uses by default on Linux, so the IDE will find it with zero configuration.
  sdkRelativePath = "Android/Sdk";

  # Android Studio is unfree, so Hydra never builds it and cache.nixos.org never
  # serves it — every nixpkgs bump makes you re-fetch the ~1.5 GB tarball and
  # re-run the unpack/wrap locally. Set this to false to keep it out of the
  # shell entirely and install it once at the system/home-manager level, or to
  # use the JetBrains Toolbox build. See NOTES.md for how to get it cached.
  enableAndroidStudio = true;

  # Used only by the `android-sdk-bootstrap` helper below.
  defaultApiLevel = "36";
  defaultBuildTools = "36.0.0";

  # Google publishes this as `commandlinetools-linux-<build>_latest.zip`.
  # Bump the build number from https://developer.android.com/studio
  # ("Command line tools only") when you want a newer sdkmanager.
  cmdlineToolsBuild = "14742923";
  cmdlineToolsUrl =
    "https://dl.google.com/android/repository/commandlinetools-linux-${cmdlineToolsBuild}_latest.zip";

  # Android Gradle Plugin 8.x targets JDK 17; AGP is happy on 21 too but 17 is
  # the widest-compatibility choice. Swap to pkgs.jdk21 if your project needs it.
  jdk = pkgs.jdk17;

  ##############################################################################
  # Shared libraries needed by Google's prebuilt, non-Nix binaries
  ##############################################################################
  #
  # Everything sdkmanager downloads is built for a normal FHS distro and has
  # /lib64/ld-linux-x86-64.so.2 hardcoded as its ELF interpreter. nix-ld provides
  # that path and reads NIX_LD / NIX_LD_LIBRARY_PATH, so we hand it the exact
  # library closure the Android tools want.

  # Some attribute names drift between nixpkgs releases (e.g. `mesa` vs
  # `libgbm`, `systemdLibs`). Resolve those by name and silently skip any that
  # don't exist, so this file keeps evaluating across channel bumps.
  optionalPkgs = names:
    map (name: pkgs.${name}) (builtins.filter (name: pkgs ? ${name}) names);

  # X11/XCB libraries.
  #
  # The `xorg.*` package set was deprecated in nixpkgs 26.05 and its members
  # were moved to the top level under lowercase names (`xorg.libX11` is now
  # `libx11`). The old paths still resolve via `pkgs/top-level/aliases.nix`, but
  # every reference emits:
  #
  #   evaluation warning: The xorg package set has been deprecated,
  #   'xorg.libX11' has been renamed to 'libx11'
  #
  # and aliases are disabled entirely when `allowAliases = false`. Prefer the
  # new name, fall back to the legacy attribute on 25.11 and older.
  xlib = newName: oldName:
    if pkgs ? ${newName} then pkgs.${newName} else pkgs.xorg.${oldName};

  x11Libs = [
    (xlib "libx11" "libX11")
    (xlib "libxext" "libXext")
    (xlib "libxrender" "libXrender")
    (xlib "libxtst" "libXtst")
    (xlib "libxi" "libXi")
    (xlib "libxrandr" "libXrandr")
    (xlib "libxcursor" "libXcursor")
    (xlib "libxfixes" "libXfixes")
    (xlib "libxdamage" "libXdamage")
    (xlib "libxcomposite" "libXcomposite")
    (xlib "libxcb" "libxcb")
    (xlib "libxau" "libXau")
    (xlib "libxdmcp" "libXdmcp")
    (xlib "libice" "libICE")
    (xlib "libsm" "libSM")
  ];

  androidRuntimeLibs = (with pkgs; [
    # --- Core C/C++ runtime: aapt2, d8/r8, apksigner helpers, NDK clang ------
    (lib.getLib stdenv.cc.cc) # libstdc++.so.6, libgcc_s.so.1
    zlib # aapt2 wants libz.so.1
    libxml2 # NDK clang
    libxslt
    expat
    bzip2
    xz
    openssl
    curl
    util-linux # libuuid
    e2fsprogs # libext2fs, probed by the emulator

    # --- Graphics / emulator -------------------------------------------------
    libGL
    libglvnd
    vulkan-loader
    libdrm
    libxkbcommon
    wayland
    fontconfig
    freetype

    # --- Audio (emulator) ----------------------------------------------------
    alsa-lib
    libpulseaudio

    # --- Misc GUI bits some tools dlopen ------------------------------------
    dbus
    nss
    nspr
    glib
    gtk3
    cairo
    pango
    gdk-pixbuf
    atk
  ])
  ++ x11Libs
  # Renamed / release-dependent attributes.
  ++ optionalPkgs [
    "ncurses5"    # NDK lldb; falls back to ncurses on channels without it
    "systemdLibs" # libudev.so.1
    "mesa"        # older nixpkgs
    "libgbm"      # newer nixpkgs (mesa split)
  ]
  ++ lib.optional (!(pkgs ? ncurses5)) pkgs.ncurses;

  androidLibraryPath = lib.makeLibraryPath androidRuntimeLibs;

  ##############################################################################
  # Escape hatch: a real FHS sandbox
  ##############################################################################
  #
  # nix-ld covers ~95% of cases. A few Android binaries are 32-bit (`mksdcard`)
  # or exec helper scripts that expect /usr/bin to exist. Run `android-fhs` to
  # drop into a shell where the filesystem genuinely looks like Ubuntu.

  androidFhs = pkgs.buildFHSEnv {
    name = "android-fhs";
    targetPkgs = p: androidRuntimeLibs ++ [ jdk ] ++ (with p; [
      coreutils
      findutils
      gnugrep
      gnused
      gnutar
      gzip
      unzip
      zip
      which
      file
      git
      curl
      procps
      usbutils
      pciutils
    ]);
    # 32-bit variants for mksdcard and friends.
    multiPkgs = p: [ p.zlib (lib.getLib p.stdenv.cc.cc) ]
      ++ (if p ? ncurses5 then [ p.ncurses5 ] else [ p.ncurses ]);
    runScript = "bash";
    profile = ''
      export ANDROID_HOME="$HOME/${sdkRelativePath}"
      export ANDROID_SDK_ROOT="$ANDROID_HOME"
      export JAVA_HOME="${jdk}/lib/openjdk"
      export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
      echo "[android-fhs] FHS sandbox — SDK at $ANDROID_HOME"
    '';
  };

in
{
  ##############################################################################
  # Packages — host tooling only. No SDK components here, by design.
  ##############################################################################

  packages = with pkgs; [
    # Host-side adb/fastboot. Handy before the SDK exists; once platform-tools
    # is installed the SDK copy takes priority on PATH (see enterShell).
    android-tools

    # Needed by android-sdk-bootstrap and by sdkmanager itself.
    curl
    unzip
    zip
    which
    file

    # Native builds / CMake-based NDK projects.
    cmake
    ninja
    pkg-config

    # The FHS escape hatch defined above.
    androidFhs

    # Uncomment if you don't use the Gradle wrapper (./gradlew).
    # gradle
  ]
  # The IDE. nixpkgs already wraps this in its own buildFHSEnv, so the binaries
  # Studio downloads itself will run. It inherits ANDROID_HOME from this shell,
  # so it points straight at ~/Android/Sdk.
  ++ lib.optional enableAndroidStudio pkgs.android-studio;

  ##############################################################################
  # Java
  ##############################################################################

  languages.java = {
    enable = true;
    jdk.package = jdk;
  };

  ##############################################################################
  # Static environment (pure Nix values only)
  ##############################################################################

  env = {
    # Point nix-ld at the real glibc loader and the Android library closure.
    NIX_LD = lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker";
    DEVENV_ANDROID_LIBS = androidLibraryPath;

    # Studio/IDEA behave better on tiling WMs.
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };

  ##############################################################################
  # Dynamic environment (anything that needs $HOME expanded by the shell)
  ##############################################################################

  enterShell = ''
    # ---- SDK location ------------------------------------------------------
    export ANDROID_HOME="$HOME/${sdkRelativePath}"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"   # deprecated, kept for old tooling
    export ANDROID_USER_HOME="$HOME/.android"
    export ANDROID_AVD_HOME="$HOME/.android/avd"
    export ANDROID_EMULATOR_HOME="$HOME/.android"
    export GRADLE_USER_HOME="$HOME/.gradle"

    mkdir -p "$ANDROID_HOME" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"

    # NDK, if one is installed. Picks the highest version present.
    if [ -d "$ANDROID_HOME/ndk" ]; then
      _ndk="$(ls -1d "$ANDROID_HOME/ndk"/* 2>/dev/null | sort -V | tail -n1 || true)"
      if [ -n "$_ndk" ]; then
        export ANDROID_NDK_ROOT="$_ndk"
        export ANDROID_NDK_HOME="$_ndk"
      fi
      unset _ndk
    fi

    # ---- nix-ld: make Google's prebuilt binaries runnable -------------------
    # Prepend our closure but keep whatever programs.nix-ld.libraries provides.
    export NIX_LD_LIBRARY_PATH="$DEVENV_ANDROID_LIBS''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"

    # ---- PATH --------------------------------------------------------------
    # SDK dirs go first so the locally-managed adb/emulator win over the Nix ones.
    export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

    # Newest build-tools on PATH (gives you aapt2, apksigner, zipalign, d8).
    if [ -d "$ANDROID_HOME/build-tools" ]; then
      _bt="$(ls -1d "$ANDROID_HOME/build-tools"/* 2>/dev/null | sort -V | tail -n1 || true)"
      [ -n "$_bt" ] && export PATH="$_bt:$PATH"
      unset _bt
    fi

    # ---- Banner ------------------------------------------------------------
    echo
    echo "  Android dev shell"
    echo "  ─────────────────────────────────────────────────────────"
    echo "  ANDROID_HOME : $ANDROID_HOME"
    echo "  JAVA_HOME    : ''${JAVA_HOME:-unset}"
    if [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
      echo "  sdkmanager   : ok"
    else
      echo "  sdkmanager   : MISSING → run 'android-sdk-bootstrap'"
    fi
    if [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
      echo
      echo "  !! /lib64/ld-linux-x86-64.so.2 not found."
      echo "     Add 'programs.nix-ld.enable = true;' to configuration.nix and"
      echo "     rebuild, or aapt2/d8/the NDK will fail with 'No such file or"
      echo "     directory'. See NOTES.md."
    fi
    echo "  ─────────────────────────────────────────────────────────"
    echo "  android-sdk-bootstrap   install/refresh the SDK"
    echo "  android-sdk-doctor      diagnose the setup"
    echo "  android-fhs             FHS sandbox for stubborn binaries"
    ${lib.optionalString enableAndroidStudio ''echo "  android-studio          launch the IDE"''}
    echo
  '';

  ##############################################################################
  # Helper scripts
  ##############################################################################

  # Install the SDK into ~/Android/Sdk using Google's own sdkmanager.
  # Everything it writes is a plain, mutable directory — Android Studio and
  # Gradle can add components on their own later.
  scripts.android-sdk-bootstrap.exec = ''
    set -euo pipefail

    API_LEVEL="''${1:-${defaultApiLevel}}"
    BUILD_TOOLS="''${2:-${defaultBuildTools}}"

    # Usable even if invoked before enterShell has exported anything.
    export ANDROID_HOME="''${ANDROID_HOME:-$HOME/${sdkRelativePath}}"
    mkdir -p "$ANDROID_HOME"

    echo ":: SDK root: $ANDROID_HOME"

    if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
      echo ":: Installing command-line tools (build ${cmdlineToolsBuild})"
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      curl -fL --progress-bar -o "$tmp/cmdline-tools.zip" "${cmdlineToolsUrl}"
      unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
      # The zip contains a top-level "cmdline-tools/" dir; sdkmanager requires
      # it to sit at $ANDROID_HOME/cmdline-tools/latest.
      mkdir -p "$ANDROID_HOME/cmdline-tools"
      rm -rf "$ANDROID_HOME/cmdline-tools/latest"
      mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
      echo ":: Installed to $ANDROID_HOME/cmdline-tools/latest"
    else
      echo ":: Command-line tools already present"
    fi

    SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

    echo ":: Accepting licenses"
    yes 2>/dev/null | "$SDKMANAGER" --licenses >/dev/null || true

    echo ":: Installing SDK components"
    "$SDKMANAGER" --install \
      "platform-tools" \
      "platforms;android-$API_LEVEL" \
      "build-tools;$BUILD_TOOLS" \
      "cmdline-tools;latest"

    echo
    echo ":: Done. Optional extras:"
    echo "   sdkmanager --install 'emulator' 'system-images;android-$API_LEVEL;google_apis_playstore;x86_64'"
    echo "   sdkmanager --install 'ndk;27.2.12479018' 'cmake;3.22.1'"
    echo
    echo ":: Re-enter the shell so PATH picks up the new tools."
  '';

  # Quick sanity check of the whole chain.
  scripts.android-sdk-doctor.exec = ''
    set -uo pipefail

    ok()   { echo "  [ ok ] $1"; }
    bad()  { echo "  [FAIL] $1"; }
    warn() { echo "  [warn] $1"; }

    echo
    echo "Android environment report"
    echo "=========================="
    echo "ANDROID_HOME      = ''${ANDROID_HOME:-unset}"
    echo "ANDROID_NDK_ROOT  = ''${ANDROID_NDK_ROOT:-unset}"
    echo "JAVA_HOME         = ''${JAVA_HOME:-unset}"
    echo "GRADLE_USER_HOME  = ''${GRADLE_USER_HOME:-unset}"
    echo

    echo "Loader / nix-ld"
    echo "---------------"
    if [ -e /lib64/ld-linux-x86-64.so.2 ]; then
      ok "/lib64/ld-linux-x86-64.so.2 present (nix-ld active)"
    else
      bad "/lib64/ld-linux-x86-64.so.2 missing — set programs.nix-ld.enable = true;"
    fi
    [ -n "''${NIX_LD:-}" ] && ok "NIX_LD set" || bad "NIX_LD unset"
    [ -n "''${NIX_LD_LIBRARY_PATH:-}" ] && ok "NIX_LD_LIBRARY_PATH set" || bad "NIX_LD_LIBRARY_PATH unset"
    echo

    echo "SDK is local (not in /nix/store)"
    echo "--------------------------------"
    case "''${ANDROID_HOME:-}" in
      /nix/store/*) bad "ANDROID_HOME points into the Nix store — SDK will be read-only" ;;
      "")           bad "ANDROID_HOME unset" ;;
      *)            ok "ANDROID_HOME is a normal writable path" ;;
    esac
    if [ -w "''${ANDROID_HOME:-/nonexistent}" ]; then ok "writable"; else bad "not writable"; fi
    echo

    echo "Tools"
    echo "-----"
    for t in sdkmanager avdmanager adb emulator aapt2 apksigner d8 java; do
      p="$(command -v "$t" 2>/dev/null || true)"
      if [ -n "$p" ]; then ok "$t -> $p"; else warn "$t not on PATH"; fi
    done
    echo

    echo "Can the prebuilt binaries actually execute?"
    echo "------------------------------------------"
    if command -v aapt2 >/dev/null 2>&1; then
      if aapt2 version >/dev/null 2>&1; then
        ok "aapt2 runs: $(aapt2 version 2>/dev/null | head -n1)"
      else
        bad "aapt2 found but will not execute — nix-ld is not working"
        echo "         try: android-fhs   (then re-run aapt2 version)"
      fi
    else
      warn "aapt2 not installed yet (install build-tools)"
    fi
    if command -v adb >/dev/null 2>&1; then
      adb version >/dev/null 2>&1 && ok "adb runs" || bad "adb will not execute"
    fi
    echo

    echo "Installed SDK components"
    echo "------------------------"
    for d in platform-tools build-tools platforms ndk emulator system-images cmake; do
      if [ -d "''${ANDROID_HOME:-/nonexistent}/$d" ]; then
        echo "  $d: $(ls -1 "$ANDROID_HOME/$d" 2>/dev/null | tr '\n' ' ')"
      fi
    done
    echo
  '';

  # Write local.properties for projects/IDEs that ignore ANDROID_HOME.
  scripts.android-local-properties.exec = ''
    set -euo pipefail
    target="''${1:-local.properties}"
    {
      echo "# Generated by devenv — do not commit."
      echo "sdk.dir=$ANDROID_HOME"
      [ -n "''${ANDROID_NDK_ROOT:-}" ] && echo "ndk.dir=$ANDROID_NDK_ROOT"
    } > "$target"
    echo "Wrote $target"
    cat "$target"
  '';

  ##############################################################################
  # Guardrail: fail loudly if the SDK ever ends up in the Nix store
  ##############################################################################

  enterTest = ''
    echo "Checking that the SDK is locally managed..."
    case "$ANDROID_HOME" in
      /nix/store/*)
        echo "ANDROID_HOME must not be in /nix/store: $ANDROID_HOME" >&2
        exit 1
        ;;
    esac
    test -d "$ANDROID_HOME"
    java -version
  '';
}
