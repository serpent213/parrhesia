Running 2 comparison run(s)...
Versions:
  parrhesia 0.4.0
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
connect avg latency (ms) ↓  10.50      4.00      3.00            0.38x             0.29x             
connect max latency (ms) ↓  19.50      7.50      4.00            0.38x             0.21x             
echo throughput (TPS) ↑     78520.00   60353.00  164420.50       0.77x             2.09x             
echo throughput (MiB/s) ↑   43.00      33.75     90.05           0.78x             2.09x             
event throughput (TPS) ↑    1919.50    3520.50   781.00          1.83x             0.41x             
event throughput (MiB/s) ↑  1.25       2.25      0.50            1.80x             0.40x             
req throughput (TPS) ↑      4608.50    1809.50   875.50          0.39x             0.19x             
req throughput (MiB/s) ↑    26.20      11.75     2.40            0.45x             0.09x             

Legend: ↑ higher is better, ↓ lower is better.
Ratio columns are server/parrhesia (for ↓ metrics, <1.00x means that server is faster).

Run details:
  run 1: parrhesia(echo_tps=78892, event_tps=1955, req_tps=4671, connect_avg_ms=10) | strfry(echo_tps=59132, event_tps=3462, req_tps=1806, connect_avg_ms=4) | nostr-rs-relay(echo_tps=159714, event_tps=785, req_tps=873, connect_avg_ms=3)
  run 2: parrhesia(echo_tps=78148, event_tps=1884, req_tps=4546, connect_avg_ms=11) | strfry(echo_tps=61574, event_tps=3579, req_tps=1813, connect_avg_ms=4) | nostr-rs-relay(echo_tps=169127, event_tps=777, req_tps=878, connect_avg_ms=3)
