{ lib
, buildPythonPackage
, pythonOlder
, fetchPypi
, freezegun
, pytestCheckHook
}:

buildPythonPackage rec {
  pname = "itsdangerous";
  version = "2.2.0";
  format = "setuptools";
  disabled = pythonOlder "3.6";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-4AUMC32h7qU/+vFJwM+7XG4uK2nEvvIsgfputz5fYXM=";
  };

  nativeCheckInputs = [
    freezegun
    pytestCheckHook
  ];

  pytestFlagsArray = [
    "-W" "ignore::DeprecationWarning"
  ];

  meta = with lib; {
    description = "Safely pass data to untrusted environments and back";
    homepage = "https://itsdangerous.palletsprojects.com";
    license = licenses.bsd3;
  };

}
