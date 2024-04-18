{ lib
, buildPythonPackage
, fetchPypi
, cryptography
}:

buildPythonPackage rec {
  pname = "pymysql";
  version = "1.1.0";

  src = fetchPypi {
    pname = "PyMySQL";
    inherit version;
    sha256 = "sha256-TxOn34vzalHoHdnzYF/t5FpIeP4C+SNjSf2Co/BhL5Y=";
  };

  propagatedBuildInputs = [ cryptography ];

  # Wants to connect to MySQL
  doCheck = false;

  meta = with lib; {
    description = "Pure Python MySQL Client";
    homepage = "https://github.com/PyMySQL/PyMySQL";
    license = licenses.mit;
    maintainers = [ maintainers.kalbasit ];
  };
}
