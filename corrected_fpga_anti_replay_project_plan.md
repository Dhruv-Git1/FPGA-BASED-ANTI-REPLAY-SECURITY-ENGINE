# Design, Implementation, and Evaluation of an FPGA-Based Anti-Replay Security Engine

**Integrated SipHash-2-4 Authentication and Configurable Sliding-Window Replay Detection**

## 1. Project Description

This project implements a hardware-based anti-replay security engine on an FPGA. A Python application running on a PC generates packets and transmits them to the FPGA over a USB-to-UART serial link. The FPGA receives the serial stream, reconstructs the packet, extracts its fields, computes the expected SipHash-2-4 message authentication code (MAC), and compares the calculated tag with the tag received in the packet.

Replay-protection state may be modified only after successful authentication. Each authenticated packet is evaluated independently by two replay-detection engines: (1) a strict sequence-counter engine, which accepts only the expected next sequence number, and (2) a configurable sliding-window engine, which can accept previously unseen out-of-order packets that remain within its window. Duplicate, stale, and unauthenticated packets are rejected according to the selected policy.

The project will compare window configurations using functional verification and actual AMD/Xilinx Vivado synthesis and implementation reports. Measurements will include resource utilization, timing, and packet-processing latency. LEDs and UART telemetry will provide visible hardware status, subject to the interfaces available on the selected FPGA board.

The project is an educational FPGA prototype. It is not intended to claim production-grade key management, full IPsec/RFC 4303 compliance, or protection against physical key extraction.

## 2. Objectives

- Implement a synthesizable SipHash-2-4 authentication core and compare the calculated 64-bit tag with the received tag.
- Ensure that an unauthenticated packet cannot modify either replay engine's state.
- Implement a strict sequence-counter baseline and a parameterized sliding-window replay detector.
- Demonstrate acceptance of new packets, rejection of duplicate/replayed packets, rejection of stale packets, and handling of unseen in-window out-of-order packets.
- Compare the two replay algorithms by applying the same authenticated packet stream to both engines in parallel.
- Evaluate supported window sizes using Vivado synthesis and static timing analysis.
- Report LUTs, flip-flops, slices where applicable, timing slack, estimated maximum frequency, packet-processing latency, and functional verification results using actual tool reports and tests.
- Demonstrate status through LEDs and UART telemetry, if supported by the selected FPGA board.

## 3. Packet and Interface Definition

### 3.1 Logical packet fields

The logical packet is 128 bits (16 bytes):

| Field | Width | Purpose |
|---|---:|---|
| `Device_ID` | 16 bits | Identifies the source/device in the packet |
| `Seq_Num` | 32 bits | Sequence number used for replay detection |
| `Payload` | 16 bits | Data or command being protected |
| `MAC_Tag` | 64 bits | SipHash-2-4 authentication tag |
| **Total** | **128 bits** | **16 bytes** |

The MAC input consists of the eight bytes representing `Device_ID`, `Seq_Num`, and `Payload`, in that order. The received `MAC_Tag` is not part of the MAC input. The implementation must define and use the same byte order in Python and RTL. For this project, serialize each field most-significant byte first and pass those exact first eight packet bytes to the Python SipHash reference model; implement the SipHash specification's internal word loading, message-length encoding, compression, and finalization rules correctly in RTL.

The PC and FPGA must use the same fixed 128-bit test key for the demonstration. The key is a laboratory key, not a production key-management solution. Since `Device_ID` is authenticated as part of the message, changing it without recomputing the tag must cause authentication to fail. A separate device allow-list or per-device key selection is outside the basic project scope unless added explicitly.

### 3.2 UART framing

UART is a byte stream and does not preserve packet boundaries automatically. Use an explicit frame marker before each 16-byte logical packet. For example:

`SOF = 0xA5 0x5A` followed by the 16 packet bytes.

The FPGA UART receiver scans for the marker, collects the fixed-length packet, and passes the fields to the authentication engine. A UART framing error or receive timeout should return the parser to its marker-search state. The exact parser recovery behavior must be implemented and tested.

UART telemetry travels from the FPGA back to the PC over the UART TX path. A practical initial configuration is 115200 baud, 8 data bits, no parity, and 1 stop bit (8-N-1), provided the selected board supports that configuration.

## 4. Design Architecture

```text
PC / Python packet generator
        |
        | USB-to-UART: SOF + 16-byte packet
        v
FPGA UART RX and frame parser
        |
        v
Packet registers / metadata alignment
        |
        v
SipHash-2-4 authentication core
        |
        +----------------------------+
        |                            |
        v                            v
Strict sequence-counter       Sliding-window replay
engine                        engine (parameter W)
        |                            |
        +-------------+--------------+
                      |
                      v
            Verdict and event logic
                      |
             +--------+--------+
             |                 |
             v                 v
         Status LEDs       UART TX telemetry
                               |
                               v
                              PC
```

The two replay engines receive the same authenticated packet and keep independent replay state. Their verdicts are reported separately. Do not combine both verdicts using a logical AND for the main acceptance decision: doing so would prevent the sliding-window policy from accepting packets that the strict-counter policy rejects. The project may expose either result as the selected policy verdict or report both for comparison.

### 4.1 Authentication and metadata alignment

The authentication engine calculates a 64-bit tag and asserts `mac_valid` only when the calculated tag matches the received tag for a valid frame. Since the MAC core can require multiple clock cycles, packet metadata such as `Seq_Num` must be held in registers or pipelined alongside the authentication operation. The `mac_valid` result must be paired with the sequence number and packet that produced it—not with a newer packet that arrived later.

Define the basic signals clearly, for example:

- `frame_valid`: the parser has produced a complete, valid-length packet.
- `mac_valid`: the frame has passed tag verification.
- `strict_accept`: the strict-counter engine accepts the authenticated sequence number.
- `window_accept`: the sliding-window engine accepts the authenticated sequence number.

Each replay engine's state-update logic must be gated by authentication success and by that engine's own acceptance decision.

## 5. Replay-Detection Rules

### 5.1 Strict sequence-counter engine

The strict engine stores `expected_seq`. For this project's demonstration, use sequence number **1** as the initial expected value and make the Python generator and testbench use the same value.

For every authenticated packet:

1. If `Seq_Num == expected_seq`, accept the packet and increment `expected_seq` by one.
2. Otherwise, reject the packet and leave `expected_seq` unchanged.
3. If authentication fails, reject the packet and leave `expected_seq` unchanged.

Because a rejected out-of-order packet does not advance the strict counter, the same sequence number may be accepted later if it equals the then-current expected value. This behavior is intentional for the strict-counter baseline.

### 5.2 Sliding-window engine

Use a parameter `W` for the window size. Recommended experimental configurations are `W = 16, 32, 64, 128`.

Maintain:

- `initialized`: whether any authenticated packet has been accepted in the current test session.
- `S_max`: the highest accepted sequence number in the current session.
- `window_mask[W-1:0]`: a bitmap indicating which sequence numbers in the current window have been accepted.

Define bit 0 as the bit for `S_max`; bit 1 represents `S_max - 1`, and so on. When the engine has not yet been initialized, its first authenticated packet is accepted, `S_max` is set to that sequence number, and bit 0 is set.

For a later authenticated packet, use these rules within a session in which sequence numbers do not wrap:

1. **Newer packet (`Seq_Num > S_max`):** Accept it. Let `advance = Seq_Num - S_max`. If `advance >= W`, set the bitmap to `...0001`; otherwise shift the bitmap left by `advance` and set bit 0. Update `S_max` to `Seq_Num`.
2. **Packet at or below `S_max`:** Compute `age = S_max - Seq_Num`. If `age >= W`, reject the packet as stale. Otherwise inspect `window_mask[age]`: if the bit is already 1, reject it as a duplicate; if the bit is 0, accept the packet and set that bit to 1.
3. **Authentication failure:** Reject the packet without modifying `initialized`, `S_max`, or `window_mask`.

The initial project version will not support 32-bit sequence-number rollover. Start a new, explicitly coordinated test session before the sequence counter wraps. Clearing the replay state while reusing the same key and old sequence numbers would allow a previously recorded packet to be accepted again; do not describe a simple reset as secure session recovery.

**Standards note:** RFC 4303 requires support for a receive window of at least 32 packets for 32-bit sequence numbers and prefers 64 as the default. Therefore, treat `W = 16` as an experimental comparison point, not as an RFC 4303-conforming window size. Describe this block as an *RFC 4303-style sliding-window detector* unless all relevant standard requirements have been implemented and verified. See the references at the end.

## 6. Design Methodology

1. **Python packet generation:** Implement a Python reference model for SipHash-2-4. Generate packets containing a device ID, sequence number, payload, and correct 64-bit tag. Generate additional test cases with corrupted payloads or tags, duplicate sequence numbers, stale sequence numbers, and out-of-order packets.
2. **UART transmission and reception:** Send `SOF + 16-byte packet` frames from the PC. Implement the FPGA UART receiver and packet parser. Confirm that the extracted fields match the transmitted values.
3. **Authentication:** Compute the expected tag over exactly the agreed eight message bytes. Compare it with the received tag and assert `mac_valid` only on a match.
4. **Replay checking:** Feed the authenticated packet and its aligned sequence number to the strict-counter and sliding-window engines in parallel. Only authenticated packets may affect replay state.
5. **Verdict and reporting:** Record MAC status and each engine's separate verdict. Maintain event counters where practical and send concise ASCII status records to the PC over UART TX.
6. **Functional verification:** Use a self-checking simulation testbench and the Python reference model to compare expected and actual results. Include assertions or checks showing that a failed MAC leaves all replay state unchanged.
7. **Synthesis and timing evaluation:** Build the supported window configurations using the same target FPGA, clock constraints, and Vivado settings. Save the actual synthesis and implementation reports for comparison.
8. **Hardware demonstration:** Program the selected board, send test frames from the PC, and compare the physical LED indications and UART log with the expected results.

## 7. Demonstration Plan

Use an initial sequence number of 1. Test cases that require a fresh state should begin from a documented reset/test-session setup.

| Test | Input | Expected result |
|---|---|---|
| Normal in-order traffic | `1`, then `2`, each with a valid MAC | Both engines accept both packets |
| Out-of-order arrival | After accepting `1` and `2`, send `4` | Strict engine rejects `4`; sliding window accepts it |
| Delayed in-window packet | Then send `3` | Strict engine accepts `3`, because it is still expecting `3`; sliding window also accepts unseen `3` if it remains in the window |
| Duplicate/replay | Send `3` again with its original valid MAC | Both engines reject it: strict engine expects `4`, and sliding window has already marked `3` as seen |
| Authentication failure | Tamper with a payload or tag without recomputing the MAC | MAC fails; neither replay engine changes state |
| State-isolation check | After the failed-MAC test, send the next packet valid for a fresh or known test state | The result matches the expected state as it stood before the failed packet; the tampered sequence number must not have advanced it |
| Stale packet | With `W = 32`, first advance the window far enough (for example, accept sequence `40` in a fresh test session), then send sequence `1` with a valid MAC | Sliding window rejects sequence `1` as stale; strict engine rejects it as not expected |
| Window-size comparison | Repeat the same valid/invalid packet traces for each supported `W` | Functional results agree with the specified rules; resource/timing results are recorded from Vivado |

The state-isolation test must use a carefully controlled sequence so the expected verdict is unambiguous. A tampered packet with a very high sequence number is a useful case because it demonstrates why MAC verification must precede any replay-state update.

## 8. Hardware Components and Software

### Hardware

- FPGA development board with a supported clock source, UART interface, and status LEDs.
- USB-to-UART connection between the FPGA board and PC, either onboard or through an external adapter.
- Host PC for packet generation and telemetry logging.

**Board selection is to be finalized before writing the constraints file.** Record the exact board name and FPGA part number, then use that board's official pin assignments and clock information. Do not reuse an `.xdc` file or pin assignments from a different board.

### Software

- Verilog or SystemVerilog RTL.
- AMD/Xilinx Vivado for simulation, synthesis, implementation, and timing reports.
- Python for packet generation, the SipHash reference model, test automation, and UART communication.
- A serial terminal or Python logger for telemetry inspection.

## 9. Evaluation and Reporting

For each `W` configuration, record the following using actual tool outputs and tests:

| Metric | How it will be obtained |
|---|---|
| LUT utilization | Vivado synthesis/implementation utilization report |
| Flip-flops/registers | Vivado utilization report |
| Slices or equivalent device resource metric | Vivado report, where applicable to the selected FPGA family |
| Worst negative slack (WNS) | Vivado static timing analysis with documented clock constraints |
| Critical path | Vivado timing report; identify the startpoint, endpoint, and relevant logic |
| Estimated maximum frequency | Derived from valid timing results and clearly stated assumptions; do not copy a prediction table as a measurement |
| Authentication and replay correctness | Self-checking testbench and recorded hardware test cases |
| Processing latency | Count clock cycles from the defined packet-acceptance point to the corresponding verdict |
| UART end-to-end transfer rate | Measured or calculated separately from the core's timing performance |

Use the same target FPGA, clock period, constraints, tool settings, and reporting method for every comparison. A 115200-baud UART link will limit the rate at which packets are delivered to the core; it does not determine the FPGA core's maximum clock frequency. Do not claim one packet per clock or line-rate throughput unless the implemented architecture and measurements demonstrate it.

Do not include predicted LUT counts, WNS values, or maximum frequencies as if they were results. Present the completed results only after the relevant Vivado runs have finished.

## 10. Expected Outcomes

- Correct SipHash-2-4 tags pass authentication; tampered data or tags fail authentication.
- An unauthenticated frame does not advance `expected_seq`, set any sliding-window bit, change `S_max`, or initialize the sliding-window state.
- Previously accepted sequence numbers are rejected as duplicates by the sliding-window engine.
- Authenticated, unseen packets within the active sliding window are accepted even when they arrive out of order.
- The strict-counter and sliding-window engines produce different, explainable results for appropriate packet traces.
- The FPGA reports MAC and replay verdicts through UART telemetry and available LEDs.
- Actual Vivado reports quantify resource utilization and timing differences among the supported window sizes.
- The project produces a reproducible testbench, test vectors, logs, and a report that separates measured results from assumptions.

## 11. Scope and Limitations

- The project protects packet integrity/authenticity and detects replay; it does not encrypt the payload.
- A fixed key is used for the lab demonstration. Secure key provisioning, key storage protection, device authorization policy, and resistance to physical key extraction are outside the basic scope.
- Sequence-number rollover and persistent anti-replay state across reset are not implemented in the initial version. A reset must not be represented as secure session recovery when the same key and sequence space are reused.
- `W = 16` is an experimental configuration. Use at least `W = 32` when making comparisons relevant to RFC 4303's minimum receive-window requirement.
- Runtime or partial FPGA reconfiguration is not part of the basic plan. Comparing bitstreams built with different parameter values is a build-time design-space exploration, not proof of runtime reconfiguration.
- The exact FPGA board, its constraints, and its UART/LED interfaces must be confirmed before hardware integration.

## References

1. S. Kent, “IP Encapsulating Security Payload (ESP),” RFC 4303, especially Section 3.4.3 and Appendix A.2. RFC Editor: https://www.rfc-editor.org/rfc/rfc4303.html
2. J.-P. Aumasson and D. J. Bernstein, “SipHash: a fast short-input PRF,” specification and reference description: https://eprint.iacr.org/2012/351.pdf
