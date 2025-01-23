{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, uv2nix, pyproject-nix, pyproject-build-systems }:
    let
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.aarch64-linux;

      # Use Python 3.12 from nixpkgs
      python = pkgs.python312;

      # Load a uv workspace from a workspace root.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Create package overlay from workspace.
      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        sourcePreference = "wheel"; # or sourcePreference = "sdist";
        # Optionally customise PEP 508 environment
        # environ = {
        #   platform_release = "5.10.65";
        # };
      };

      # Customized Python package set combining base pyproject-nix builders with 
      # build system overlays, workspace-specific uv.lock overlay, and build fixes.
      # Used for both production and development environments.
      pythonSet =
        # Use base package set from pyproject.nix builders
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
          # Add the stdenv override here to set the MacOS SDK version
          stdenv = pkgs.stdenv.override {
            targetPlatform = pkgs.stdenv.targetPlatform // {
              # This sets MacOS SDK version to 15.1 (Darwin 24)
              darwinSdkVersion = "13.3";
            };
          };
        }).overrideScope (lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
        ]);

      # Package hello into executable using uv2nix
      app = let
        # Import the build util function from pyproject-nix
        mkApp = pkgs.callPackage pyproject-nix.build.util { };
      in mkApp.mkApplication {
        # Use the function passing two arguments: the Python package set and the package name.
        venv = pythonSet.mkVirtualEnv "hello" {
          # Use only the default dependencies for the hello package
          inherit (workspace.deps.default) hello;
        };
        package = pythonSet.hello;
      };

    in {
      # Packages for hello-world project
      packages.aarch64-darwin = {
        app = app;

        # Use the `dockerTools.buildImage` function from Nixpkgs to create a Docker image.
        # More on: https://nix.dev/tutorials/nixos/building-and-running-docker-images.html
        docker = pkgs.dockerTools.buildImage {
          name = "hello-image";
          tag = "latest";
          created = "now";

          config = { Cmd = [ "${app}/bin/hello" ]; };
        };
      };

      # Development shell for hello-world project
      devShells.aarch64-darwin.default = let

        # This overlay configuration enables "editable mode" for local Python packages.
        # In editable mode, Python looks for packages in your source directory rather than 
        # site-packages, allowing you to modify code without rebuilding the environment.
        editableOverlay =
          workspace.mkEditablePyprojectOverlay { root = "$REPO_ROOT"; };

        # Create Python set with the editable overlay applied.
        editablePythonSet = pythonSet.overrideScope (final: prev: {
          hello-world = prev.hello-world.overrideAttrs (old: {
            # Add editables build dependency
            nativeBuildInputs = old.nativeBuildInputs
              ++ final.resolveBuildSystem { editables = [ ]; };
          });
        });

        # Create a virtual environment from our editable package set.
        # This venv will contain all dependencies (workspace.deps.all includes optional deps),
        # with local packages installed in editable mode.
        localVenv =
          editablePythonSet.mkVirtualEnv "hello-world-env" workspace.deps.all;

      in pkgs.mkShell {
        # Include the virtual environment and development tools:
        # - uv: Modern Python package installer and resolver
        # - git: Required for getting the repository root
        packages = [ localVenv python pkgs.uv pkgs.git pkgs.docker ];

        shellHook = ''
          unset PYTHONPATH
          export UV_NO_SYNC=1
          export UV_PYTHON_DOWNLOADS=never 
          export REPO_ROOT=$(git rev-parse --show-toplevel)
        '';
      };
    };
}
