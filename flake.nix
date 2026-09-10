{
  description = "LLDAP - Light LDAP implementation for authentication";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "github:ipetkov/crane";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # MSRV from the project
        rustVersion = "1.91.0";
        
        # Rust toolchain with required components
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" ];
          targets = [ 
            "wasm32-unknown-unknown" 
            "x86_64-unknown-linux-musl"
            "aarch64-unknown-linux-musl" 
            "armv7-unknown-linux-musleabihf"
          ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # nixpkgs' packaged wasm-bindgen-cli attrs top out below the
        # wasm-bindgen version this project's Cargo.lock pins (0.2.120) --
        # wasm-pack requires an exact version match between the wasm-bindgen
        # crate and the wasm-bindgen-cli binary on PATH, or it tries to
        # download a matching one itself (blocked in the Nix sandbox). Build
        # 0.2.120 directly the same way nixpkgs builds its own versioned
        # attrs (buildWasmBindgenCli + fetchCrate + fetchCargoVendor).
        #
        # fetchCargoVendor's fetch helper uses Python's `requests` with its
        # default User-Agent, which crates.io blocks with a 403 -- the
        # preBuild below swaps in a UA-patched sitecustomize.py (see that
        # file's own comment for why it has to be a full replacement, not an
        # addition).
        wasmBindgenCli120 =
          let
            src = pkgs.fetchCrate {
              pname = "wasm-bindgen-cli";
              version = "0.2.120";
              hash = "sha256-Dkkx8Bhfk+y/jEz9Fzwytmv2N3Gj/7ST+5MlPRzzetU=";
            };
          in
          pkgs.buildWasmBindgenCli {
            inherit src;
            version = "0.2.120";
            cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
              inherit src;
              pname = "wasm-bindgen-cli";
              version = "0.2.120";
              hash = "sha256-5Zu/Sh9aBMxB+KGC1MHWJAQ8PuE40M6lsenkpFEwJ6A=";
              passAsFile = [ "siteCustomizeContent" ];
              siteCustomizeContent = builtins.readFile ./nix/fetch-cargo-vendor-sitecustomize.py;
              preBuild = ''
                mkdir -p $TMPDIR/pysite
                cp "$siteCustomizeContentPath" $TMPDIR/pysite/sitecustomize.py
                export PYTHONPATH=$TMPDIR/pysite
              '';
            };
          };

        # Common build inputs
        nativeBuildInputs = with pkgs; [
          # Rust toolchain and tools
          rustToolchain
          wasm-pack
          
          # Build tools
          pkg-config
          
          # Compression and utilities
          gzip
          curl
          wget
          
          # Development tools
          git
          jq
          
          # Cross-compilation support
          gcc
        ];

        buildInputs = with pkgs; [
          # System libraries that might be needed
          openssl
          sqlite
        ] ++ lib.optionals stdenv.isDarwin [
          # macOS specific dependencies
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.SystemConfiguration
        ];

        # Environment variables
        commonEnvVars = {
          CARGO_TERM_COLOR = "always";
          RUST_BACKTRACE = "1";
          
          # Cross-compilation environment
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = "${pkgs.pkgsStatic.stdenv.cc}/bin/cc";
          CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER = "${pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc}/bin/aarch64-unknown-linux-gnu-gcc";
          CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER = "${pkgs.pkgsCross.armv7l-hf-multiplatform.stdenv.cc}/bin/arm-unknown-linux-gnueabihf-gcc";
        };

        # The web UI's external CSS/JS/font dependencies (see
        # app/static/libraries.txt and app/static/fonts/fonts.txt) --
        # fetched once as a fixed-output derivation so the frontend build
        # below can stay fully offline/sandboxed. The hash and file lists
        # are shared verbatim with nixpkgs' own lldap package (same
        # upstream v0.6.3 app/static/*.txt content), so the pinned hash
        # is reused rather than re-derived here.
        staticAssets = pkgs.runCommand "lldap-static-assets"
          {
            outputHash = "sha256-xVbHD9s3ofbtHCDvjYwmsWXDEJ9z9vRxQDRR6pW6rt8=";
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
            nativeBuildInputs = [ pkgs.curl ];
            env.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          }
          ''
            mkdir $out
            mkdir $out/fonts
            for file in $(cat ${./app/static/libraries.txt}); do
              curl "$file" --location --remote-name --output-dir $out
            done
            for file in $(cat ${./app/static/fonts/fonts.txt}); do
              curl "$file" --location --remote-name --output-dir $out/fonts
            done
          '';

        # Builds the WASM web UI (app/) via wasm-pack, matching nixpkgs'
        # own lldap package's approach. wasm-bindgen-cli's version has to
        # match the wasm-bindgen crate version pinned in Cargo.lock
        # (0.2.120) exactly, or wasm-pack refuses the output -- providing
        # it pre-installed on PATH is what lets wasm-pack skip trying to
        # download a matching binary itself (which the Nix sandbox would
        # block anyway).
        #
        # Uses the unfiltered source (not cleanCargoSource, which strips
        # non-.rs files like app/build.sh, app/index_local.html and
        # app/static/* that this build actually needs).
        frontend = craneLib.buildPackage {
          src = craneLib.path ./.;

          # The root Cargo.toml is a bare [workspace] with no [package], so
          # crane cannot infer these and falls back to placeholders (with a
          # warning at every eval of a config that references this package).
          pname = "lldap-frontend";
          version = "0.6.3";

          nativeBuildInputs = nativeBuildInputs ++ [
            wasmBindgenCli120
            pkgs.binaryen
            pkgs.which
          ];
          inherit buildInputs;

          cargoArtifacts = null;
          doCheck = false;
          doNotPostBuildInstallCargoBinaries = true;

          buildPhaseCargoCommand = ''
            HOME=$TMPDIR ./app/build.sh
          '';
          installPhaseCommand = ''
            mkdir -p $out
            cp -R app/pkg $out/pkg
            cp -R app/static $out/static
            cp app/index_local.html $out/index.html
            cp -R ${staticAssets}/* $out/static/
            rm -f $out/static/libraries.txt $out/static/fonts/fonts.txt
          '';

          meta = with pkgs.lib; {
            description = "Web UI assets for LLDAP";
            license = licenses.gpl3Only;
          };
        };

      in
      {
        # Development shells
        devShells = {
          default = pkgs.mkShell ({
            inherit nativeBuildInputs buildInputs;
            
            shellHook = ''
              echo "🔐 LLDAP Development Environment"
              echo "==============================================="
              echo "Rust version: ${rustVersion}"
              echo "Standard cargo commands available:"
              echo "  cargo build --workspace    - Build the workspace"
              echo "  cargo test --workspace     - Run tests"
              echo "  cargo clippy --tests --workspace -- -D warnings - Run linting"
              echo "  cargo fmt --check --all    - Check formatting"
              echo "  ./app/build.sh              - Build frontend WASM"
              echo "  ./export_schema.sh          - Export GraphQL schema"
              echo "==============================================="
              echo ""
              
              # Ensure wasm-pack is available
              if ! command -v wasm-pack &> /dev/null; then
                echo "⚠️  wasm-pack not found in PATH"
              fi
              
              # Check if we're in the right directory
              if [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$PWD" ]]; then
                echo "⚠️  Run this from the project root directory"
              fi
            '';
          } // commonEnvVars);

          # Minimal shell for CI-like environment
          ci = pkgs.mkShell ({
            inherit nativeBuildInputs buildInputs;
            
            shellHook = ''
              echo "🤖 LLDAP CI Environment"
              echo "Running with Rust ${rustVersion}"
            '';
          } // commonEnvVars);
        };

        # Package outputs (optional - for building with Nix)
        packages = {
          inherit frontend;

          default = craneLib.buildPackage {
            src = craneLib.cleanCargoSource (craneLib.path ./.);

            inherit nativeBuildInputs buildInputs;

            # The root Cargo.toml is workspace-only (no [package] section), so
            # crane can't infer a name/version from it and falls back to the
            # placeholder "cargo-package"/"0.0.1" -- which `lib.getExe`
            # (assumes mainProgram == pname) then looks for at
            # $out/bin/cargo-package, a binary that doesn't exist (the real
            # one is $out/bin/lldap, from the "-p lldap" member crate below).
            pname = "lldap";
            version = "0.6.3";

            # Build only the server by default
            cargoExtraArgs = "-p lldap";

            # Skip tests in the package build
            doCheck = false;

            meta = with pkgs.lib; {
              description = "Light LDAP implementation for authentication";
              homepage = "https://github.com/lldap/lldap";
              license = licenses.gpl3Only;
              maintainers = with maintainers; [ ];
              platforms = platforms.unix;
              mainProgram = "lldap";
            };
          };
        };

        # Formatter for the flake itself
        formatter = pkgs.nixpkgs-fmt;

        # Apps for running via `nix run`
        apps = {
          default = flake-utils.lib.mkApp {
            drv = self.packages.${system}.default;
          };
        };
      });
}
