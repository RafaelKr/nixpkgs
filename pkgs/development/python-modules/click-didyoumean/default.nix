{ lib, buildPythonPackage, fetchPypi,
  click
}:

buildPythonPackage rec {
  pname = "click-didyoumean";
  version = "0.3.1";
  format = "setuptools";

  src = fetchPypi {
    inherit pname version;
    sha256 = "sha256-T4L9/w2+ZO+Ksieb1qo/apnDsowFqgnL/AfJ1/u1pGM=";
  };

  propagatedBuildInputs = [ click ];

  meta = with lib; {
    description = "Enable git-like did-you-mean feature in click";
    homepage = "https://github.com/click-contrib/click-didyoumean";
    license = licenses.mit;
    maintainers = with maintainers; [ mbode ];
  };
}
