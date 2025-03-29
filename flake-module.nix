{
  lib,
  flake-parts-lib,
  inputs,
  ...
}:
let
  inherit (flake-parts-lib) mkPerSystemOption;
  inherit (lib) mkOption mkPackageOption types;
in
{
  options = {
    perSystem = mkPerSystemOption (
      {
        pkgs,
        ...
      }:
      {
        options.uvpart = mkOption {
          description = ''
            Configuration for uv-based python projects.
          '';
          type = types.submodule {
            options = {
              outputs = mkOption {
                description = "uvpart will write an output set to this option";
              };
              workspaceRoot = mkOption {
                type = types.path;
                description = "Root of the python workspace";
              };
              projectName = mkOption {
                type = types.nullOr types.str;
                description = "Name of the project. By default, this will be parsed from the toml file";
                default = null;
              };
              pythonOverlays = mkOption {
                type = types.listOf (types.functionTo (types.functionTo types.attrs));
                description = "extra python overlays to apply (for fixups)";
                default = [ ];
              };
              workspaceConfig = mkOption {
                type = types.oneOf [ (types.functionTo types.attrs) types.attrs ];
                description = "the workspace configuration";
                default = _: {};
              };
              extraPackages = mkOption {
                type = types.listOf types.package;
                description = "extra packages to include in the dev shells";
                default = [ ];
              };
              shellHook = mkOption {
                type = types.str;
                description = "shell hook to put into dev shells. Will be concatenated to the default shell hook.";
                default = "";
              };
              defaultShell = mkOption {
                type = types.enum [
                  "pure"
                  "impure"
                  "none"
                ];
                description = "whether to use the pure or impure shell as the default shell. 'none' will set no default shell.";
                default = "pure";
              };
              publishPackage = mkOption {
                type = types.bool;
                description = "Whether to expose the scripts as the default package";
                default = true;
              };
              publishApps = mkOption {
                type = types.bool;
                description = "Whether to expose the scripts as flake apps";
                default = true;
              };
              editableFilterSet = mkOption {
                type = types.listOf types.path;
                description = "A list of paths which make up the editable filter set. The 'editable' version of the python package will only be considered 'changed' if any file in these paths changes. Setting this ensures that most source changes will not trigger a rebuild. By default, only pyproject.toml is considered.";
                default = [ ];
              };
              python = mkPackageOption pkgs "python" {
                default = "python313";
              };
              uv = mkPackageOption pkgs "uv" { };
            };
          };
        };
      }
    );
  };
  config = {
    perSystem =
      { pkgs, config, ... }:
      let
        inherit (config) uvpart;
        workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = uvpart.workspaceRoot;
          config = uvpart.workspaceConfig;
        };
        overlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel";
        };
        pythonSet =
          (pkgs.callPackage inputs.pyproject-nix.build.packages {
            python = uvpart.python;
            stdenv = pkgs.stdenv.override {
              targetPlatform = pkgs.stdenv.targetPlatform // {
                darwinSdkVersion = "15.1";
              };
            };
          }).overrideScope
            (
              lib.composeManyExtensions (
                [
                  inputs.pyproject-build-systems.overlays.default
                  overlay
                  (pkgs.callPackage ./fix-git-deps.nix {
                    uvlock = builtins.fromTOML (builtins.readFile "${inputs.self}/uv.lock");
                  })
                ]
                ++ uvpart.pythonOverlays
              )
            );
        editableOverlay = workspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT";
        };
        projectToml = builtins.fromTOML (builtins.readFile "${inputs.self}/pyproject.toml");
        projectName = projectToml.project.name;
        projectName' = if uvpart.projectName == null then projectName else uvpart.projectName;
        moduleName = builtins.replaceStrings [ "-" ] [ "_" ] projectName;
        scripts = builtins.attrNames (projectToml.project.scripts or { });
        editablePythonSet = pythonSet.overrideScope (
          lib.composeManyExtensions [
            (final: prev: {
              "${projectName}" = prev.${projectName}.overrideAttrs (old: {
                # if workspaceRoot is a path (as in, it was not automatically derived) we're able to do much faster rebuilds.
                src =
                  if lib.isPath uvpart.workspaceRoot then
                    (lib.fileset.toSource {
                      root = old.src;
                      fileset = lib.fileset.unions (
                        [
                          (old.src + "/pyproject.toml")
                          (lib.fileset.maybeMissing (old.src + "/README.md"))
                          (lib.fileset.maybeMissing (old.src + "/${moduleName}/__init__.py"))
                        ]
                        ++ uvpart.editableFilterSet
                      );
                    })
                  else
                    old.src;

                nativeBuildInputs =
                  old.nativeBuildInputs
                  ++ final.resolveBuildSystem {
                    editables = [ ];
                  };
              });
            })
            editableOverlay
          ]
        );
        impure-shell = pkgs.mkShell {
          packages = [
            uvpart.python
            uvpart.uv
          ] ++ uvpart.extraPackages;
          env =
            {
              UV_PYTHON_DOWNLOADS = "never";
              UV_PYTHON = uvpart.python.interpreter;
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              LD_LIBRARY_PATH = lib.makeLibraryPath pkgs.pythonManylinuxPackages.manylinux1;
            };
          shellHook =
            ''
              unset PYTHONPATH
            ''
            + uvpart.shellHook;

        };
        environment = pythonSet.mkVirtualEnv (projectName' + "-env") workspace.deps.default;
        editableEnvironment = (
          editablePythonSet.mkVirtualEnv (projectName' + "-editable-env") workspace.deps.all
        );
        pure-shell = pkgs.mkShell {
          packages = [
            editableEnvironment
            uvpart.uv
          ] ++ uvpart.extraPackages;
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = "${editableEnvironment}/bin/python";
            UV_PYTHON_DOWNLOADS = "never";

          };
          shellHook =
            ''
              # Undo dependency propagation by nixpkgs.
              unset PYTHONPATH
              # Get repository root using git. This is expanded at runtime by the editable `.pth` machinery.
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            ''
            + uvpart.shellHook;
        };
        defaultShellExtension =
          if uvpart.defaultShell == "pure" then
            { default = pure-shell; }
          else if uvpart.defaultShell == "impure" then
            { default = impure-shell; }
          else
            { };

        package = pkgs.stdenv.mkDerivation {
          name = projectName';
          phases = [ "installPhase" ];
          inherit scripts;
          installPhase = ''
            mkdir -p $out/bin
            for script in $scripts; do
              ln -s ${environment}/bin/$script $out/bin/$script
            done
          '';
        };
        defaultPackageExtension = lib.optionalAttrs uvpart.publishPackage {
          default = package;
        };
        defaultApps = lib.optionalAttrs uvpart.publishApps (
          builtins.listToAttrs (
            map (name: {
              inherit name;
              value = {
                type = "app";
                program = "${package}/bin/${name}";
              };
            }) scripts
          )
        );

      in
      {
        config = {
          uvpart.outputs = {
            inherit
              pure-shell
              impure-shell
              environment
              package
              workspace
              pythonSet
              ;
          };
          devShells = {
            uv-pure-shell = pure-shell;
            uv-impure-shell = impure-shell;
          } // defaultShellExtension;
          packages = {
            uv-lock = pkgs.writeScriptBin "uv-lock" ''
              #!${pkgs.bash}/bin/bash
              ${uvpart.uv}/bin/uv lock --python ${uvpart.python}/bin/python
            '';
          } // defaultPackageExtension;
          apps = defaultApps;
        };
      };
  };
}
