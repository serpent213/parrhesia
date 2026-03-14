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
connect avg latency (ms) ↓  10.00      3.00      2.50            0.30x             0.25x             
connect max latency (ms) ↓  18.50      5.00      4.00            0.27x             0.22x             
echo throughput (TPS) ↑     76972.00   68204.50  158779.00       0.89x             2.06x             
echo throughput (MiB/s) ↑   42.15      38.15     86.95           0.91x             2.06x             
event throughput (TPS) ↑    1749.00    3560.00   787.50          2.04x             0.45x             
event throughput (MiB/s) ↑  1.15       2.30      0.50            2.00x             0.43x             
req throughput (TPS) ↑      2463.00    1808.00   822.00          0.73x             0.33x             
req throughput (MiB/s) ↑    13.00      11.70     2.25            0.90x             0.17x             

Legend: ↑ higher is better, ↓ lower is better.
Ratio columns are server/parrhesia (for ↓ metrics, <1.00x means that server is faster).

Run details:
  run 1: parrhesia(echo_tps=78336, event_tps=1796, req_tps=2493, connect_avg_ms=9) | strfry(echo_tps=70189, event_tps=3567, req_tps=1809, connect_avg_ms=3) | nostr-rs-relay(echo_tps=149317, event_tps=786, req_tps=854, connect_avg_ms=2)
  run 2: parrhesia(echo_tps=75608, event_tps=1702, req_tps=2433, connect_avg_ms=11) | strfry(echo_tps=66220, event_tps=3553, req_tps=1807, connect_avg_ms=3) | nostr-rs-relay(echo_tps=168241, event_tps=789, req_tps=790, connect_avg_ms=3)
