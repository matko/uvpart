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
                internal = true;
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
                type = types.oneOf [
                  (types.functionTo types.attrs)
                  types.attrs
                ];
                description = "the workspace configuration";
                default = _: { };
              };
              dependencyGroups = mkOption {
                type = types.nullOr (
                  types.oneOf [
                    types.str
                    (types.listOf types.str)
                  ]
                );
                description = "the dependency groups to enable. The default is to enable all of them. You can set this either to a string to get the corresponding property on the workspace, or set it to a list of strings, referring to dependency groups in your pyproject.toml.";
                default = null;
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
                type = types.listOf types.unspecified;
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
        projectToml = builtins.fromTOML (builtins.readFile "${inputs.self}/pyproject.toml");
        workspaceConfig = projectToml.tool.uv.workspace or null;
        isWorkspace = workspaceConfig != null;
        # Only use project name from toml if it exists and we're not overriding it
        projectNameFromToml = projectToml.project.name or null;
        projectName' = if uvpart.projectName != null then uvpart.projectName else projectNameFromToml;
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
        scripts = builtins.attrNames (projectToml.project.scripts or { });

        # Helper function to resolve glob patterns in workspace members
        resolveWorkspaceMembers =
          members: excludes:
          let
            allPaths = builtins.concatMap (
              member:
              if lib.hasSuffix "/*" member then
                let
                  baseDir = lib.removeSuffix "/*" member;
                  basePath = uvpart.workspaceRoot + "/${baseDir}";
                in
                if builtins.pathExists basePath then
                  map (name: "${baseDir}/${name}") (
                    builtins.filter (name: builtins.pathExists (basePath + "/${name}/pyproject.toml")) (
                      builtins.attrNames (builtins.readDir basePath)
                    )
                  )
                else
                  [ ]
              else
                [ member ]
            ) members;
            filteredPaths = builtins.filter (
              path:
              !builtins.any (
                exclude:
                if lib.hasSuffix "/*" exclude then
                  lib.hasPrefix (lib.removeSuffix "/*" exclude) path
                else
                  path == exclude
              ) excludes
            ) allPaths;
          in
          filteredPaths;

        # Get workspace members if this is a workspace
        workspaceMembers =
          if isWorkspace then
            resolveWorkspaceMembers (workspaceConfig.members or [ ]) (workspaceConfig.exclude or [ ])
          else
            [ ];
        editablePythonSet = pythonSet.overrideScope (
          lib.composeManyExtensions [
            (
              final: prev:
              let
                # Build fileset based on whether this is a workspace or single project
                buildFileset =
                  old:
                  if lib.isPath uvpart.workspaceRoot then
                    let
                      baseFiles = [
                        (old.src + "/pyproject.toml")
                        (lib.fileset.maybeMissing (old.src + "/README.md"))
                      ] ++ uvpart.editableFilterSet;

                      workspaceFiles =
                        if isWorkspace then
                          # For workspaces, include minimal files for each member
                          builtins.concatMap (
                            memberPath:
                            let
                              memberDir = old.src + "/${memberPath}";
                              memberTomlPath = memberDir + "/pyproject.toml";
                            in
                            if builtins.pathExists memberTomlPath then
                              let
                                memberToml = builtins.fromTOML (builtins.readFile memberTomlPath);
                                memberProjectName = memberToml.project.name or null;
                                memberModuleName =
                                  if memberProjectName != null then
                                    builtins.replaceStrings [ "-" ] [ "_" ] memberProjectName
                                  else
                                    null;
                              in
                              [
                                memberTomlPath
                                (lib.fileset.maybeMissing (memberDir + "/README.md"))
                              ]
                              ++ lib.optionals (memberModuleName != null) [
                                (lib.fileset.maybeMissing (memberDir + "/${memberModuleName}/__init__.py"))
                                (lib.fileset.maybeMissing (memberDir + "/src/${memberModuleName}/__init__.py"))
                              ]
                            else
                              [ ]
                          ) workspaceMembers
                        else
                          # For single projects, include the module directories
                          let
                            moduleName = builtins.replaceStrings [ "-" ] [ "_" ] projectName';
                          in
                          [
                            (lib.fileset.maybeMissing (old.src + "/${moduleName}/__init__.py"))
                            (lib.fileset.maybeMissing (old.src + "/src/${moduleName}/__init__.py"))
                          ];
                    in
                    lib.fileset.toSource {
                      root = old.src;
                      fileset = lib.fileset.unions (baseFiles ++ workspaceFiles);
                    }
                  else
                    old.src;
              in
              # Only override if we have a valid project name
              lib.optionalAttrs (projectName' != null) {
                "${projectName'}" =
                  (prev.${projectName'} or (throw "Project ${projectName'} not found in python set")).overrideAttrs
                    (old: {
                      src = buildFileset old;
                      nativeBuildInputs =
                        old.nativeBuildInputs
                        ++ final.resolveBuildSystem {
                          editables = [ ];
                        };
                    });
              }
            )
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

        makeDeps =
          dependencyGroups:
          if dependencyGroups != null then
            (
              if (builtins.typeOf dependencyGroups) == "string" then
                workspace.deps.${dependencyGroups}
              else
                workspace.deps.all
                // lib.optionalAttrs (projectName' != null) {
                  ${projectName'} = dependencyGroups;
                }
            )
          else
            workspace.deps.default;
        environment =
          if projectName' != null then
            pkgs.callPackage (
              {
                dependencyGroups ? uvpart.dependencyGroups,
              }:
              pythonSet.mkVirtualEnv (projectName' + "-env") (makeDeps dependencyGroups)
            ) { }
          else
            null;
        editableEnvironment =
          if projectName' != null then
            pkgs.callPackage (
              {
                dependencyGroups ? "all",
              }:
              editablePythonSet.mkVirtualEnv (projectName' + "-editable-env") (makeDeps dependencyGroups)
            ) { }
          else
            null;
        pure-shell = pkgs.mkShell {
          packages =
            lib.optionals (editableEnvironment != null) [
              editableEnvironment
            ]
            ++ [
              uvpart.uv
            ]
            ++ uvpart.extraPackages;
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = uvpart.python.interpreter;
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

        package =
          if projectName' != null then
            pkgs.callPackage (
              {
                dependencyGroups ? uvpart.dependencyGroups,
              }:
              let
                environment' = environment.override { inherit dependencyGroups; };
                inherit (pkgs.callPackages inputs.pyproject-nix.build.util { }) mkApplication;
              in
              mkApplication {
                venv = environment';
                package = pythonSet.${projectName'};
              }
            ) { }
          else
            null;
        defaultPackageExtension = lib.optionalAttrs (uvpart.publishPackage && package != null) {
          default = package;
        };
        defaultApps = lib.optionalAttrs (uvpart.publishApps && package != null) (
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
          uvpart.outputs =
            {
              inherit
                pure-shell
                impure-shell
                workspace
                pythonSet
                editablePythonSet
                ;
            }
            // lib.optionalAttrs (environment != null) {
              inherit environment;
            }
            // lib.optionalAttrs (editableEnvironment != null) {
              inherit editableEnvironment;
            }
            // lib.optionalAttrs (package != null) {
              inherit package;
            };
          devShells = {
            uv-pure-shell = pure-shell;
            uv-impure-shell = impure-shell;
          } // defaultShellExtension;
          packages =
            {
              uv-lock = pkgs.writeScriptBin "uv-lock" ''
                #!${pkgs.bash}/bin/bash
                ${uvpart.uv}/bin/uv lock --python ${uvpart.python}/bin/python
              '';
            }
            // lib.optionalAttrs (projectName' != null && package != null) {
              ${projectName'} = package;
            }
            // defaultPackageExtension;
          apps = defaultApps;
        };
      };
  };
}
