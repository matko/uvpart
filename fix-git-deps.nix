{ lib, uvlock }:
final: prev:
let
  isGitDependency = (p: builtins.hasAttr "git" p.source);
  addHatchling = (
    p:
    p.overrideAttrs (old: {
      buildInputs =
        old.buildInputs or [ ]
        ++ (with final; [
          hatchling
          pathspec
          pluggy
          packaging
          trove-classifiers
        ]);
    })
  );
in
lib.listToAttrs (
  lib.map (p: {
    inherit (p) name;
    value = addHatchling prev.${p.name};
  }) (builtins.filter isGitDependency uvlock.package)
)
