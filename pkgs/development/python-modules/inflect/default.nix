{ lib
, buildPythonPackage
, fetchPypi
, isPy27
, setuptools-scm
, pydantic
, pytestCheckHook
}:

buildPythonPackage rec {
  pname = "inflect";
  version = "7.2.0";
  disabled = isPy27;
  format = "pyproject";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-Mv6s+s/K4vIub8zeoQ8N3yamOPrENNDd2q+8oANPN4Q=";
  };

  nativeBuildInputs = [ setuptools-scm ];

  propagatedBuildInputs = [ pydantic ];

  nativeCheckInputs = [ pytestCheckHook ];

  disabledTests = [
    # https://errors.pydantic.dev/2.5/v/string_too_short
    "inflect.engine.compare"
  ];

  pythonImportsCheck = [ "inflect" ];

  meta = with lib; {
    description = "Correctly generate plurals, singular nouns, ordinals, indefinite articles";
    homepage = "https://github.com/jaraco/inflect";
    changelog = "https://github.com/jaraco/inflect/blob/v${version}/CHANGES.rst";
    license = licenses.mit;
    maintainers = teams.tts.members;
  };
}
