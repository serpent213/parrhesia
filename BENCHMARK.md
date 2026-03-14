Running 2 comparison run(s)...
Versions:
  parrhesia 0.2.0
  strfry 1.0.4 (nixpkgs)
  nostr-rs-relay 0.9.0
  nostr-bench 0.4.0

[run 1/2] Parrhesia
[run 1/2] strfry
[run 1/2] nostr-rs-relay

[run 2/2] Parrhesia
[run 2/2] strfry
[run 2/2] nostr-rs-relay

=== Bench comparison (averages) ===
metric                      parrhesia  strfry    nostr-rs-relay  strfry/parrhesia  nostr-rs/parrhesia
--------------------------  ---------  --------  --------------  ----------------  ------------------
connect avg latency (ms) ↓  11.50      3.50      2.50            0.30x             0.22x             
connect max latency (ms) ↓  20.00      5.50      3.50            0.28x             0.17x             
echo throughput (TPS) ↑     81805.50   62033.50  162281.50       0.76x             1.98x             
echo throughput (MiB/s) ↑   44.75      34.65     88.90           0.77x             1.99x             
event throughput (TPS) ↑    1524.50    3518.00   782.50          2.31x             0.51x             
event throughput (MiB/s) ↑  1.00       2.25      0.50            2.25x             0.50x             
req throughput (TPS) ↑      2539.00    1809.00   847.00          0.71x             0.33x             
req throughput (MiB/s) ↑    12.45      11.70     2.35            0.94x             0.19x             

Legend: ↑ higher is better, ↓ lower is better.
Ratio columns are server/parrhesia (for ↓ metrics, <1.00x means that server is faster).

Run details:
  run 1: parrhesia(echo_tps=80431, event_tps=1427, req_tps=2546, connect_avg_ms=13) | strfry(echo_tps=61421, event_tps=3581, req_tps=1811, connect_avg_ms=3) | nostr-rs-relay(echo_tps=167436, event_tps=792, req_tps=897, connect_avg_ms=3)
  run 2: parrhesia(echo_tps=83180, event_tps=1622, req_tps=2532, connect_avg_ms=10) | strfry(echo_tps=62646, event_tps=3455, req_tps=1807, connect_avg_ms=4) | nostr-rs-relay(echo_tps=157127, event_tps=773, req_tps=797, connect_avg_ms=2)
