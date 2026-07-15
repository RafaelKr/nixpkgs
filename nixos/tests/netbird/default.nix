{ runTest }:

{
  client = runTest ./client.nix;
  server-signal = runTest ./server-signal.nix;
  server-management = runTest ./server-management.nix;
  server-relay = runTest ./server-relay.nix;
  server-relay-coturn = runTest ./server-relay-coturn.nix;
  server-ingress = runTest ./server-ingress.nix;
}
