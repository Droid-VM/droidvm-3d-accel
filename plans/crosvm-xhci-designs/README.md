# crosvm xHCI design notes (wip/usb)

Design records written during the USB passthrough work, one per crosvm defect class, in the order they were found. Each states the symptom evidence, the xHCI 1.2 spec basis, the decided design and the commits that implement it. Verification records live in `../USB_PASSTHROUGH_SURVEY.md` §9.

| File | Defect | Commits |
|---|---|---|
| DESIGN-STREAMS.md | Windows UASPStor bulk streams: Not Valid stream contexts rejected, guest-caused context errors killed the command ring, Set TR Dequeue on a stream endpoint clobbered the SCA pointer | b6c9027, baf456e, ce5a1d2 |
| DESIGN-HCRST.md | HCRST did not reset CRCR / the command ring / the interrupter; CRCR reset value had CRR set; CS/CA abort unmodelled | 391518c (cherry-picked from eb47f50) |
| DESIGN-STOPPED.md | Stop Endpoint reported no Stopped event for the TD in progress; Windows waited 2-4 s after every stop | dc1e0bf, 9293b36, 13242f9 |
| DESIGN-STOPPED-ISO.md | Drained-ahead (isochronous) rings flooded the guest with completions at stop (see the erratum inside) | e5eece2 |
| DESIGN-STOPPED-STREAMS.md | A stream endpoint stop emitted one Stopped event per stream ring; Windows flagged duplicates | f96fd65 |
| DESIGN-STREAM-RESTART.md (+ ANALYSIS-STREAM-RESTART.md) | After a stream-endpoint stop the silently rewound stream ring never restarted: crosvm started only the doorbell-addressed ring, hardware resumes every stream | d849baf |
| DESIGN-STOPPED-DELIVERED.md (+ ANALYSIS-STREAM-RESTART-2.md) | A cancelled URB that had already moved the whole TD was treated as a stop and re-executed; the device never resends that tag (16 s UAS strand on a warm disk) | 2a8e371 |
