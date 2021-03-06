{ pkgs ? (import <nixpkgs> {}).pkgs
}:

let
  myemacs =
    with pkgs.emacsPackages; with pkgs.emacsPackagesNg; pkgs.emacsWithPackages
      [ helm-projectile magit tuaregMode ];
  hol_light = pkgs.callPackage (import ./hol_light) {};
  ocaml_tophook = pkgs.callPackage (import ./ocaml_tophook.nix) {};
  ocamlPackages_tophook =
    pkgs.ocaml-ng.mkOcamlPackages ocaml_tophook
      (self: super: pkgs.lib.mapAttrs (n: v: pkgs.newScope self v {})
                                      (import ./ocaml-packages.nix));
  hol_light_tophook = (hol_light.override {
    ocamlPackages = ocamlPackages_tophook;
  });
  hollightdeps = with pkgs; {
    name = "HOL-Light-Deps";
    buildInputs = with ocamlPackages_tophook; [
      ocaml findlib ezjsonm ocaml_batteries sexplib monadlib camlp5_strict
      hol_light_tophook
    ];
    findlib = "${ocamlPackages_tophook.findlib}/lib/ocaml/4.01.0-tophook/site-lib/";
    HOLLIGHT_DIR = "${hol_light_tophook}";
  };
in pkgs.stdenv.mkDerivation hollightdeps //
   {
     emacs = with pkgs; stdenv.mkDerivation (hollightdeps // {
       buildInputs = hollightdeps.buildInputs ++ [ myemacs ];
     });
   }
