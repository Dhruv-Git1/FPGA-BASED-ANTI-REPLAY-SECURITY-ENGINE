# Implementation results (read from Vivado reports)

Part xc7z020clg484-1, clock constraint 10.000 ns (100 MHz), same settings for every W.
Estimated Fmax = 1 / (10 ns - WNS). It is derived from setup slack, not measured.

| W | Total LUTs | Total FFs | Slices | WNS (ns) | Est. Fmax (MHz) | Window LUTs | Window FFs | Strict LUTs | Strict FFs | Auth LUTs | Auth FFs |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 1085 | 1021 | 398 | 1.722 | 120.8 | 162 | 54 | 15 | 33 | 555 | 522 |
| 32 | 1158 | 1037 | 426 | 1.473 | 117.3 | 236 | 70 | 15 | 33 | 555 | 522 |
| 64 | 1314 | 1069 | 467 | 1.908 | 123.6 | 391 | 102 | 15 | 33 | 554 | 522 |
| 128 | 1681 | 1133 | 558 | 0.862 | 109.4 | 759 | 166 | 15 | 33 | 554 | 522 |
