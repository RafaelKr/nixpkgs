{ lib
, buildPythonPackage
, fetchPypi
, flit-core
, colorama
, sphinx
, livereload
}:

buildPythonPackage rec {
  pname = "sphinx-autobuild";
  version = "2024.4.16";
  pyproject = true;

  src = fetchPypi {
    pname = "sphinx_autobuild";
    inherit version;
    hash = "sha256-HA7Tehlw7tGX+cWmbWV1nnxOTLp7Wl13lAdSvxpZ8sc=";
  };

  build-system = [
    flit-core
  ];

  dependencies = [
    colorama
    sphinx
    livereload
  ];

  # No tests included.
  doCheck = false;

  pythonImportsCheck = [ "sphinx_autobuild" ];

  meta = with lib; {
    description = "Rebuild Sphinx documentation on changes, with live-reload in the browser";
    mainProgram = "sphinx-autobuild";
    homepage = "https://github.com/sphinx-doc/sphinx-autobuild";
    license = with licenses; [ mit ];
    maintainers = with maintainers; [holgerpeters];
  };
}
