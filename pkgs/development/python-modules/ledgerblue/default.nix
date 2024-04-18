{ lib
, stdenv
, bleak
, buildPythonPackage
, ecpy
, fetchPypi
, future
, hidapi
, nfcpy
, pillow
, protobuf
, pycrypto
, pycryptodomex
, pyelftools
, python-u2flib-host
, pythonOlder
, websocket-client
}:

buildPythonPackage rec {
  pname = "ledgerblue";
  version = "0.1.50";
  format = "setuptools";

  disabled = pythonOlder "3.7";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-0SzUy0mPEbgeoOKEa9UtrjAQafrauKl1wvsONyosJNk=";
  };

  propagatedBuildInputs = [
    ecpy
    future
    hidapi
    nfcpy
    pillow
    protobuf
    pycrypto
    pycryptodomex
    pyelftools
    python-u2flib-host
    websocket-client
  ]
  ++ lib.optionals stdenv.isLinux [
    bleak
  ];

  # No tests
  doCheck = false;

  pythonImportsCheck = [
    "ledgerblue"
  ];

  meta = with lib; {
    description = "Python library to communicate with Ledger Blue/Nano S";
    homepage = "https://github.com/LedgerHQ/blue-loader-python";
    license = licenses.asl20;
    maintainers = with maintainers; [ np ];
  };
}
