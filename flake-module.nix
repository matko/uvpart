{
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, config, ... }:
    let
      inherit (config) uvpart;
      workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = uvpart.workspaceRoot;
      };
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };
      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages {
          python = uvpart.python;
        }).overrideScope
          (
            lib.composeManyExtensions (
              [
                inputs.pyproject-build-systems.overlays.default
                overlay
              ]
              ++ uvpart.pythonOverlays
            )
          );
      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };
      projectToml = builtins.fromTOML (builtins.readFile "${inputs.self}/pyproject.toml");
      projectName = projectToml.project.name;
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
      virtualEnv = (
        editablePythonSet.mkVirtualEnv (uvpart.projectName + "-editable-env") workspace.deps.all
      );
      pure-shell = pkgs.mkShell {
        packages = [
          virtualEnv
          uvpart.uv
        ] ++ uvpart.extraPackages;
        env = {
          UV_NO_SYNC = "1";
          UV_PYTHON = "${virtualEnv}/bin/python";
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
    in
    {
      options = {
        uvpart.outputs = lib.mkOption { };
        uvpart.workspaceRoot = lib.mkOption {
          type = lib.types.path;
          description = "Root of the python workspace";
        };
        uvpart.projectName = lib.mkOption {
          type = lib.types.str;
          description = "Name of the project. By default, this will be parsed from the toml file";
          default = projectName;
        };
        uvpart.pythonOverlays = lib.mkOption {
          type = lib.types.listOf (lib.types.functionTo (lib.types.functionTo lib.types.attrs));
          description = "extra python overlays apply (for fixups)";
          default = [ ];
        };
        uvpart.extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          description = "extra packages to include in the dev shells";
          default = [ ];
        };
        uvpart.shellHook = lib.mkOption {
          type = lib.types.str;
          description = "shell hook to put into dev shells. Will be concatenated to the default shell hook.";
          default = "";
        };
        uvpart.defaultShell = lib.mkOption {
          type = lib.types.enum [
            "pure"
            "impure"
            "none"
          ];
          description = "whether to use the pure or impure shell as the default shell. 'none' will set no default shell.";
          default = "pure";
        };
        uvpart.editableFilterSet = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          description = "A list of paths which make up the editable filter set. The 'editable' version of the python package will only be considered 'changed' if any file in these paths changes. Setting this ensures that most source changes will not trigger a rebuild. By default, only pyproject.toml is considered.";
          default = [ ];
        };
        uvpart.python = lib.mkPackageOption pkgs "python" {
          default = "python3";
        };
        uvpart.uv = lib.mkPackageOption pkgs "uv" { };
      };
      config = {
        uvpart.outputs = {
          inherit pure-shell;
          environment = pythonSet.mkVirtualEnv (uvpart.projectName + "-env") workspace.deps.default;
        };
        devShells = {
          uv-pure-shell = pure-shell;
          uv-impure-shell = impure-shell;
        } // defaultShellExtension;
        packages = {
          uvpython-uv-lock = pkgs.writeScriptBin "uv-lock" ''
            #!${pkgs.bash}/bin/bash
            ${uvpart.uv}/bin/uv lock --python ${uvpart.python}/bin/python
          '';
        };
      };
    };
}
