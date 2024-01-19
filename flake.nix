{
  description = "mach engine flake";
  inputs.zig2nix.url = "github:Cloudef/zig2nix";

  outputs = { zig2nix, ... }: with builtins; let
    flake-utils = zig2nix.inputs.flake-utils;
    outputs = (flake-utils.lib.eachDefaultSystem (system: let
      #! Structures.

      zig-env = zig2nix.zig-env.${system};
      pkgs = (zig-env {}).pkgs;

      # Mach nominated Zig versions.
      # <https://machengine.org/about/nominated-zig/>
      zigv = pkgs.callPackage ./versions.nix {
        zigSystem = (zig-env {}).lib.zigDoubleFromString system;
        zigHook = (zig-env {}).zig-hook;
      };

      #:! Helper function for building and running Mach projects.
      #:! For more options see zig-env from <https://github.com/Cloudef/zig2nix>
      mach-env = {
        # Zig version to use. Normally there is no need to change this.
        zig ? zigv.mach-latest,
        # Enable Vulkan support.
        enableVulkan ? true,
        # Enable OpenGL support.
        enableOpenGL ? true,
        # Enable Wayland support.
        # Disabled by default because mach-core example currently panics with:
        # error(mach): glfw: error.FeatureUnavailable: Wayland: The platform does not provide the window position
        enableWayland ? false,
        # Enable X11 support.
        enableX11 ? true,
        ...
      } @attrs: let
        env = pkgs.callPackage zig-env (attrs // {
          inherit zig enableVulkan enableOpenGL enableWayland enableX11;
        });
      in (env // {
        #! --- Outputs of mach-env {} function.
        #!     access: (mach-env {}).thing

        #! Autofix tool
        #! https://github.com/ziglang/zig/issues/17584
        autofix = pkgs.writeShellApplication {
          name = "zig-autofix";
          runtimeInputs = with pkgs; [ zig gnused gnugrep ];
          text = ''
            if [[ ! -d "$1" ]]; then
              printf 'error: no such directory: %s\n' "$@"
              exit 1
            fi

            cd "$@"
            has_wontfix=0

            while {
                IFS=$':' read -r file line col msg;
            } do
              if [[ "$msg" ]]; then
                case "$msg" in
                  *"local variable is never mutated")
                    printf 'autofix: %s\n' "$file:$line:$col:$msg" 1>&2
                    sed -i "''${line}s/var/const/" "$file"
                    ;;
                  *)
                    printf 'wontfix: %s\n' "$file:$line:$col:$msg" 1>&2
                    has_wontfix=1
                    ;;
                esac
              fi
            done < <(zig build 2>&1 | grep "error:")

            exit $has_wontfix
            '';
        };

        #! QOI - The “Quite OK Image Format” for fast, lossless image compression
        #! Packages the `qoiconv` binary.
        #! <https://github.com/phoboslab/qoi/tree/master>
        extraPkgs.qoi = pkgs.callPackage ./packages/qoi.nix {};

        #! Package for specific target supported by nix.
        #! You can still compile to other platforms by using package and specifying zigTarget.
        #! When compiling to non-nix supported targets, you can't rely on pkgsForTarget, but rather have to provide all the pkgs yourself.
        #! NOTE: Even though target is supported by nix, cross-compiling to it might not be, in that case you should get an error.
        packageForTarget = target: (env.crossPkgsForTarget target).callPackage (pkgs.callPackage ./src/package.nix {
          inherit target;
          inherit (env) packageForTarget;
          inherit (env.lib) resolveTargetSystem;
        });

        #! Packages mach project.
        #! NOTE: You must first generate build.zig.zon2json-lock using zon2json-lock.
        #!       It is recommended to commit the build.zig.zon2json-lock to your repo.
        #!
        #! Additional attributes:
        #!    zigTarget: Specify target for zig compiler, defaults to nix host.
        #!    zigInheritStdenv:
        #!       By default if zigTarget is specified, nixpkgs stdenv compatible environment is not used.
        #!       Set this to true, if you want to specify zigTarget, but still use the derived stdenv compatible environment.
        #!    zigPreferMusl: Prefer musl libc without specifying the target.
        #!    zigDisableWrap: makeWrapper will not be used. Might be useful if distributing outside nix.
        #!    zigWrapperArgs: Additional arguments to makeWrapper.
        #!    zigBuildZon: Path to build.zig.zon file, defaults to build.zig.zon.
        #!    zigBuildZonLock: Path to build.zig.zon2json-lock file, defaults to build.zig.zon2json-lock.
        #!
        #! <https://github.com/NixOS/nixpkgs/blob/master/doc/hooks/zig.section.md>
        package = packageForTarget system;

        #! Update Mach deps in build.zig.zon
        #! Handy helper if you decide to update mach-flake
        #! This does not update your build.zig.zon2json-lock file
        update-mach-deps = let
          mach = (env.lib.fromZON ./templates/engine/build.zig.zon).dependencies.mach;
          core = (env.lib.fromZON ./templates/core/build.zig.zon).dependencies.mach_core;
        in with pkgs; env.app [ gnused jq zig2nix.outputs.packages.${system}.zon2json ] ''
          replace() {
            while {
              read -r url;
              read -r hash;
            } do
              sed -i -e "s;$url;$2;" -e "s;$hash;$3;" build.zig.zon
            done < <(zon2json build.zig.zon | jq -r ".dependencies.\"$1\" | .url, .hash")
          }
          replace mach "${mach.url}" "${mach.hash}"
          replace mach_core "${core.url}" "${core.hash}"
          '';
      });

      # Default mach env used by this flake
      env = mach-env {};
      app = env.app-bare;

      mach-binary-triples = [
        "aarch64-linux-musl" "x86_64-linux-musl"
        "aarch64-linux-gnu" "x86_64-linux-gnu"
        "aarch64-macos-none" "x86_64-macos-none"
        "x86_64-windows-gnu"
      ];

      # nix compatible doubles, macos becomes darwin and so on
      mach-binary-doubles = with env.lib; with env.pkgs.lib; let
        # Currently cross-compiling to these is broken
        # https://github.com/ziglang/zig/issues/18571
        filtered = [ "aarch64-darwin" "x86_64-darwin" ];
      in subtractLists filtered (unique (map
        (t: systems.parse.doubleFromSystem (mkZigSystemFromString t)) mach-binary-triples));
    in rec {
      #! --- Architecture dependent flake outputs.
      #!     access: `mach.outputs.thing.${system}`

      #! Helper function for building and running Mach projects.
      inherit mach-env;

      #! Expose mach nominated zig versions and extra packages.
      #! <https://machengine.org/about/nominated-zig/>
      packages = {
        inherit (zig2nix.outputs.packages.${system}) zon2json zon2json-lock zon2nix;
        inherit (env) autofix;
        zig = zigv;
      } // env.extraPkgs;

      #! Run a Mach nominated version of a Zig compiler inside a `mach-env`.
      #! nix run#zig."mach-nominated-version"
      #! example: nix run#zig.mach-latest
      apps.zig = mapAttrs (k: v: (mach-env {zig = v;}).app-no-root [] ''zig "$@"'') zigv;

      #! Run a latest Mach nominated version of a Zig compiler inside a `mach-env`.
      #! nix run
      apps.default = apps.zig.mach-latest;

      #! Develop shell for building and running Mach projects.
      #! nix develop#zig."mach-nominated-version"
      #! example: nix develop#zig.mach-latest
      devShells.zig = mapAttrs (k: v: (mach-env {zig = v;}).mkShell {}) zigv;

      #! Develop shell for building and running Mach projects.
      #! Uses `mach-latest` nominated Zig version.
      #! nix develop
      devShells.default = devShells.zig.mach-latest;

      apps.mach = env.pkgs.callPackage src/mach.nix {
        inherit app mach-binary-triples;
        inherit (packages) zon2json;
        inherit (env) zig;
      };

      apps.test = env.pkgs.callPackage src/test.nix {
        inherit app mach-binary-doubles;
      };

      # nix run .#readme
      apps.readme = let
        project = "Mach Engine Flake";
      in with env.pkgs; app [ gawk gnused packages.zon2json jq ] (replaceStrings ["`"] ["\\`"] ''
      zonrev() {
        zon2json templates/"$1"/build.zig.zon | jq -e --arg k "$2" -r '.dependencies."\($k)".url' |\
          sed 's,^.*/\([0-9a-f]*\).*,\1,'
      }
      cat <<EOF
      # ${project}

      Flake that allows you to get started with Mach engine quickly.

      https://machengine.org/

      ---

      [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

      * Mach Zig: `${env.zig.version} @ ${env.zig.machNominated}`
      * Mach Engine: `$(zonrev engine mach)`
      * Mach Core: `$(zonrev core mach_core)`

      ## Mach Engine

      ```bash
      nix flake init -t github:Cloudef/mach-flake#engine
      nix run .
      # for more options check the flake.nix file
      ```

      ## Mach Core

      ```bash
      nix flake init -t github:Cloudef/mach-flake#core
      nix run .
      # for more options check the flake.nix file
      ```

      ## Using Mach nominated Zig directly

      ```bash
      nix run github:Cloudef/mach-flake#zig.mach-latest -- version
      ```

      ## Shell for building and running a Mach project

      ```bash
      nix develop github:Cloudef/mach-flake
      ```

      ## Crude documentation

      Below is auto-generated dump of important outputs in this flake.

      ```nix
      $(awk -f doc.awk flake.nix | sed "s/```/---/g")
      ```
      EOF
      '');
    }));

    welcome-template = description: prelude: ''
      # ${description}
      ${prelude}

      ## Build & Run

      ```
      nix run .
      ```

      See flake.nix for more options.
      '';
  in outputs // rec {
    #! --- Generic flake outputs.
    #!     access: `mach.outputs.thing`

    #! Mach engine project template
    #! nix flake init -t templates#engine
    templates.engine = {
      path = ./templates/engine;
      description = "Mach engine project";
      welcomeText = welcome-template description ''
        - Mach engine: https://machengine.org/engine/
        '';
    };

    #! Mach core project template
    #! nix flake init -t templates#core
    templates.core = rec {
      path = ./templates/core;
      description = "Mach core project";
      welcomeText = welcome-template description ''
        - Mach core: https://machengine.org/core/
        '';
    };

    # nix flake init -t templates
    templates.default = templates.engine;
  };
}
