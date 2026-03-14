Running 2 comparison run(s)...
Versions:
  parrhesia 0.3.0
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
connect avg latency (ms) ↓  13.50      3.00      2.00            0.22x             0.15x             
connect max latency (ms) ↓  22.50      5.50      3.00            0.24x             0.13x             
echo throughput (TPS) ↑     80385.00   61673.00  164516.00       0.77x             2.05x             
echo throughput (MiB/s) ↑   44.00      34.45     90.10           0.78x             2.05x             
event throughput (TPS) ↑    2000.00    3404.50   788.00          1.70x             0.39x             
event throughput (MiB/s) ↑  1.30       2.20      0.50            1.69x             0.38x             
req throughput (TPS) ↑      3664.00    1808.50   877.50          0.49x             0.24x             
req throughput (MiB/s) ↑    20.75      11.75     2.45            0.57x             0.12x             

Legend: ↑ higher is better, ↓ lower is better.
Ratio columns are server/parrhesia (for ↓ metrics, <1.00x means that server is faster).

Run details:
  run 1: parrhesia(echo_tps=81402, event_tps=1979, req_tps=3639, connect_avg_ms=14) | strfry(echo_tps=61745, event_tps=3457, req_tps=1818, connect_avg_ms=3) | nostr-rs-relay(echo_tps=159974, event_tps=784, req_tps=905, connect_avg_ms=2)
  run 2: parrhesia(echo_tps=79368, event_tps=2021, req_tps=3689, connect_avg_ms=13) | strfry(echo_tps=61601, event_tps=3352, req_tps=1799, connect_avg_ms=3) | nostr-rs-relay(echo_tps=169058, event_tps=792, req_tps=850, connect_avg_ms=2)
