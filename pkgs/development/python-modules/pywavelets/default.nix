{ lib
, buildPythonPackage
, fetchPypi
, isPy27
, cython
, nose
, pytest
, numpy
}:

buildPythonPackage rec {
  pname = "pywavelets";
  version = "1.6.0";
  disabled = isPy27;

  src = fetchPypi {
    pname = "PyWavelets";
    inherit version;
    hash = "sha256-6gJ8cJdxIsX8J7JRDwoNlSj5w99uo+TFd8pV/QAyWls=";
  };

  nativeCheckInputs = [ nose pytest ];

  buildInputs = [ cython ];

  propagatedBuildInputs = [ numpy ];

  # Somehow nosetests doesn't run the tests, so let's use pytest instead
  doCheck = false; # tests use relative paths, which fail to resolve
  checkPhase = ''
    py.test pywt/tests
  '';

  # ensure compiled modules are present
  pythonImportsCheck = [
    "pywt"
    "pywt._extensions._cwt"
    "pywt._extensions._dwt"
    "pywt._extensions._pywt"
    "pywt._extensions._swt"
  ];

  meta = with lib; {
    description = "Wavelet transform module";
    homepage = "https://github.com/PyWavelets/pywt";
    license = licenses.mit;
  };

}
