# run6 ETW reconstruction: the one strand d849baf did not cure (cold2 attach #3)

Sources: run6/usbtrace-c2.xml.gz parsed raw (microsecond timestamps, thread ids; the ms-level
extracts in w3-cold2-*.txt agree), run6/w3-cold{1,2,3,4}-metrics.txt, w3-cold2-gaps.txt,
w3-cold2-crosvm.log. Code: crosvm d849baf "xhci: a doorbell restarts every stream ring of the
endpoint", tree at that HEAD. Windows/guest clock runs ~0.80 s behind the host log clock
(attach#2: guest 01:08:47.25 vs host log "backend attached" 01:08:48.05; attach#3: 01:09:51.27
vs 01:09:52.08 — constant offset, no anomaly).

## 0. What run6 actually exercised (correcting the run brief)

Across the 12 attaches there was exactly ONE stop where BOTH stream rings parked holding a
cancelled TD:

* cold1: `CANCELLED TDs: 1 / 1 / 1` (three stops), `TWO_CANCELLED_TD_CASES = 0`. The 1977 ms
  DCI-7 strand on attach #1 is the ordinary one-cancel path plus disk spin-up: the reported s2
  URB was cancel-completed and re-issued at 01:01:05.904 and completed 0x0 at 01:01:07.883.
  It is NOT the restart-all fix re-executing a silent TD.
* cold2: `[1, 1, 2, 1]` — the third attach's stop is the one true two-cancel case, and it
  STRANDED (16114 ms).
* cold3: metrics say `CANCELLED TDs: 2` at 01:14:33.860, but the stream-3 line reads
  "completes **status=0x0** after 1.0 ms" — the s3 backend URB's discard lost the race and the
  reap carried the real success + data, so crosvm completed it normally; at park time only the
  s2 ring held a cancelled TD. Effectively a one-cancel stop. Clean (17 ms).
* cold4: `1 / 1 / 1`, clean.

So run6 contains zero passes of the scenario d849baf targets (two rings rewound, device still
owing data) and one pass of a nearby scenario it cannot cure (below). The metrics script's
"CANCELLED-BY-THE-STOP" label keys on completion-after-the-stop-timestamp, not on NtStatus;
only 0xC0000120 counts as a real cancel.

## 1. The failing stop, microsecond order (cold2 attach #3, usbtrace-c2 raw)

UASP traffic model visible in the trace (per SCSI exchange): 26+41+45 on DCI 7 (EP3 IN, data
pipe, 8..512 B, streams 2/3 per tag) + 26+41+45 on DCI 5 (EP2 IN, status/sense pipe, always
1024 B, streams 2/3) + 26+41+45 on DCI 2 (EP1 OUT, command pipe, 32 B IUs, stream 0); then the
27s complete in µs (the disk was already spun up: disk.sys start on this VM's attaches #1/#2
was 11/12 ms).

The two tags in flight when the stop lands:

    01:09:51.2876495  26 URB 0xFFFFBA84ABFA9620 -> 41 EP7 s2 192B + 45   (tag-2 data IN)
    01:09:51.2876890  26 URB 0xFFFFBA84ABFA84A0 -> 41 EP5 s2 1024B + 45  (tag-2 sense)
    01:09:51.2877200  26 URB 0xFFFFBA84ABFAAEA0 -> 41 EP2 32B + 45       (tag-2 command)
    01:09:51.2877670  26 URB 0xFFFFBA84ABFA6A60 -> 41 EP7 s3 256B + 45   (tag-3 data IN)
    01:09:51.2878216  26 URB 0xFFFFBA84ABFA6520 -> 41 EP5 s3 1024B + 45  (tag-3 sense URB)
    01:09:51.2878538  26 URB 0xFFFFBA84ABFA9460 -> 41 EP2 32B + 45       (tag-3 command)

The stop and its handshake — every command completion code is 1 (Success); no 19
(Context State Error), no 5 (TRB Error) anywhere in the whole c2 trace (the gaps decoder's
anomaly scan flags only the Kernel-PnP 902):

    01:09:51.2878828  31 Stop Endpoint  trb=0x...003C0701 (slot 1 DCI 7)
    01:09:51.2878741  27 EP5-s2 URB ABFA84A0  NtStatus=0x0     (just before: a sense IU lands)
    01:09:51.2880828  27 EP2 URB ABFA9460     NtStatus=0x0     (tag-3 command IU delivered)
    01:09:51.2880856  27 EP5-s3 URB ABFA6520  NtStatus=0x0     (a status-pipe IU on stream 3)
    01:09:51.2880903  33 Stop Endpoint code=1                  (all rings parked; contexts written)
    01:09:51.2881003  31 Set TR Dequeue s2  ptr=0x1_749E0800 DCS=1 SCT=1 (trb 0x03089E74...0200_00400701)
    01:09:51.2881151  31 Set TR Dequeue s3  ptr=0x1_749E0A00 DCS=1 SCT=1 (trb 0x030A9E74...0300_00400701)
    01:09:51.2881278  33 SetTRDeq s2 code=1
    01:09:51.2881289  33 SetTRDeq s3 code=1
    01:09:51.2881475  27 EP7-s2 URB ABFA9620  NtStatus=0xC0000120   <- Windows completes the
                          REPORTED stream's URB (crosvm's one Stopped event named the s2 TD)
    01:09:51.2881594  45 EP7 StreamId=3  (bare re-arm of the still-queued s3 TD; the doorbell
                          write itself is MMIO and invisible to ETW)

Then NOTHING: zero USB-provider events of any kind — not even a 42/43 interrupt bracket — from
01:09:51.2882 until 01:10:07.400 (16.11 s). The only event in the window is
`01:09:54.293 Kernel-PnP 902 WatchdogTriggered disk 3007 ms`. crosvm's log (info level) is
silent except `01:09:52.08 usb_hub: backend attached to port 9` (= this attach itself, 0.8 s
clock skew). No warn!/error! fired: no doorbell hit the out-of-range path (`get_trc` warn!),
no "doorbell rung when endpoint state is", no backend submit error.

The recovery (UASPStor request timeout):

    01:10:07.4002828  31 Stop Endpoint (second)
    01:10:07.4004552  26 EP5-s2 1024B 41+45; .4008404 26 EP2 **16B** 41+45   <- 16 B = UAS TASK
                          MANAGEMENT IU: UASPStor aborts the stuck tag before the stop completes
    01:10:07.4014212  33 Stop Endpoint code=1        <<== PROOF, see section 3
    01:10:07.4014470  31 Set TR Dequeue s3 ONLY — the IDENTICAL TRB 0x030A9E74...0300_00400701
                          (ptr 0x1_749E0A00 DCS=1: the ring never moved in 16 s)
    01:10:07.4015125  27 EP2 (task mgmt) 0x0
    01:10:07.4015313  33 SetTRDeq s3 code=1
    01:10:07.4015878  27 EP7-s3 URB ABFA6A60 NtStatus=0xC0000120  (the 16114 ms strand ends)
    01:10:07.9046..   (500 ms later) 27 EP5-s2 0x0 = task-management response; then fresh
                          26/41/45 bursts on EP7 s2 (256B etc.) complete 0x0 in µs — device
                          fully healthy the moment the tag state is reset.
    01:10:07.920      Kernel-PnP 218 disk.sys start complete: 16634 ms.

## 2. Clean stops with the same shape, for contrast

(a) cold2's own first stop, 01:07:42.6429571 (one real cancel): identical handshake — 33 stop
code=1 → SetTRDeq s2 + s3 both code=1 → 27 s2 0xC0000120 (reported) → then, within 300 µs,
fresh 41+45 EP7 s3 256B (a NEW 41: the tag-3 data URB queued during the stop gets mapped), the
cancelled s2 URB is re-submitted (26+41 EP7 s2 256B at .6434282) **together with a fresh EP2
32B command IU at .6434940** — after a cancel UASPStor re-drives the exchange at the SCSI
level, and the device serves the new command instantly. Traffic never pauses.

(b) cold3's pseudo-two-cancel stop, 01:14:33.860: s2 cancelled and reported (0xC0000120,
re-issued, clean); s3's discard lost the race host-side — the reap carried status 0 + the
data, crosvm completed the TD normally (URB 0x0 one ms after the stop), the claim was left to
the ring that really had a cancelled TD (exactly the machinery of
`a_stream_that_completed_before_the_cancel_leaves_the_claim_to_one_that_did_not`). This is the
shape the failing case NEEDED to take.

(c) run5-cold1's SECOND stop (pre-fix binary, for the Windows-behaviour calibration): at that
stop crosvm had NO cancelled TD anywhere (the stranded ring had been parked for 16 s), so it
sent ZERO Stopped events — and Windows still completed the stranded URB 0xC0000120 one ms
after its Set TR Dequeue. So: **after a stop that reports nothing, Windows self-completes the
cancelled URB; after a stop that reports some other stream's TD, Windows keeps the unreported
one pending, re-points its ring AT the TD (not past it) and re-arms it** — it believes the
controller still owns that TD and will execute it.

The precise difference failing-vs-clean, in order and codes: no completion code ever differs
(all 1). What differs is that in every clean case each cancelled-or-raced TD ends up either
(i) completed 0x0 by a normal transfer event, or (ii) completed 0xC0000120 by the one Stopped
event, and UASPStor then re-drives the SCSI exchange (new EP2 command IU). In the failing case
stream 3's TD ends in NEITHER class: no event of any kind names it, Windows re-arms it and
waits for hardware, and no new command IU is sent — the SCSI exchange for tag 3 is still
open from Windows's point of view, so UASPStor blocks for its 16 s SRB timeout.

## 3. Proof that the doorbell arrived and restart-all ran

d849baf's `stop_endpoint` refuses a Stop Endpoint on a non-Running endpoint with
`ContextStateError` (device_slot.rs:895-908; Linux exercises this legitimately). The second
Stop Endpoint at 01:10:07.400 completed **code=1**, so DCI 7's endpoint context read Running
at that moment. The only writer of Running outside Address/Configure (none ran in the window —
the last Configure Endpoint completed 01:09:51.279, before the first stop) is
`ring_doorbell`, and it sets Running only AFTER `get_trc(endpoint_index, stream_id)` returned
a live ring (the Not-Valid/out-of-range paths return before the state write). Therefore:

* a DCI-7 doorbell with a valid stream id WAS rung after the first stop — the only candidate
  instant is the bare 45 at 01:09:51.2881594 — and
* the d849baf restart-all loop DID run: every populated stream ring of DCI 7, ring 3
  included, got `trc.start()`.

Both Set TR Dequeue commands completed code=1, which also proves the doorbell did NOT arrive
before them (a doorbell first would have flipped the endpoint to Running and
`set_stream_tr_dequeue_ptr` would have answered 19 — the guard at device_slot.rs:1157-1164).
The guest-visible ordering was exactly as designed: stop → both SetTRDeq → doorbell.

So the run5 hypothesis "the silent ring never restarted because no doorbell reached it" is
DEAD for run6: the ring restarted. Yet crosvm raised not a single interrupt for 16 s.

## 4. Code walk at d849baf: what the restart did, and why it could not help

`ring_doorbell` (device_slot.rs:441-499): valid stream id → endpoint Stopped → set Running →
`for trc in trcs.iter().flatten() { trc.start(); }`. `start()`
(ring_buffer_controller.rs:~280) clears the stale StoppedTd/claim, flips Stopped→Running and
signals the ring's event; `on_event` then dequeues at the ring's pointer.

* Pointer/cycle at that moment are right by construction: `finish_stop_and_park` rewound the
  ring to `td.first_trb`/`td.cycle` (the TD's first TRB and the cycle READ from it at dequeue
  time), the stop's write-back put exactly those into the Stream Context, Windows's SetTRDeq
  echoed them (0x1_749E0A00, DCS=1), and `set_stream_tr_dequeue_ptr` wrote them back into the
  live ring (`trc.set_dequeue_pointer` / `set_consumer_cycle_state`, clearing `stopped`).
  A cycle mismatch would need Windows to have flipped the TD's TRB cycle bits between the
  SetTRDeq and the doorbell — for a transfer it re-armed as still-queued (bare 45, no new 41)
  that would be self-defeating, and the identical SetTRDeq TRB at the 16-s retry shows the
  ring state Windows believed in never changed.
* The task's hinted race (SetTRDeq for stream 3 arriving AFTER a doorbell restarted ring 3 →
  19, or pointer moved under a running TD) did not happen: the codes were 1 and ETW ordering
  is airtight. The same guard proves it cannot have happened invisibly.
* Nothing downstream refuses the TD: `handle_transfer_descriptor` → `create_transfer` →
  `send_to_backend_if_valid` → `submit_backend_transfer` goes straight to usbfs (no per-stream
  software queue that could be poisoned); a submit failure logs error! (silent log ⇒ none).
* On the second stop, `cancel_all` → discard → reap(Cancelled) → the only ring with a
  cancelled TD wins the claim → Stopped event → rewind to the same first TRB — which matches
  the retry's identical SetTRDeq pointer and the 0xC0000120 41 µs after its completion.

So the emulation-side restart machinery is coherent; the TD was (with high probability —
section 5) re-executed into a fresh backend URB within ~1 ms of 01:09:51.288. What never came
is the DATA.

## 5. The mechanism: the first execution's discard consumed the device's data for that tag

Timeline of tag 3 with the ~0.8 s clock offset removed: command IU delivered .2880828; the
data URB for it had been submitted (and its backend URB created) at .2877739; the disk is
warm (11 ms starts) and every neighbouring exchange completes in 200-400 µs. The Stop
Endpoint's `cancel_all` fires between .2879 and .2880 — **exactly the window in which the
device is delivering the 256-byte data IU for tag 3**. Three reap outcomes exist, and run6
shows all three:

1. Data fully landed before the unlink took effect → usbfs reaps status 0 + data → crosvm
   completes the TD normally → clean (cold3's "0x0 after 1 ms").
2. Unlink wins before the device sent anything (cold attach, disk spinning up, run5's cold
   strands) → device still owes the data → a restarted ring re-executes the TD and the fresh
   URB fetches it — the case d849baf fixes.
3. The unlink lands as/after the data lands but before the completion is given back: the
   kernel gives the URB back -ENOENT (→ TransferStatus::Cancelled) with the bytes it did
   accept; the host xHC's unlink (stop + set-deq past the removed TD on the phone's
   controller) throws the rest away. **The device has now delivered its data IU for tag 3 and
   will never send it again.** crosvm copies whatever arrived into the guest buffer
   (endpoint.rs DeviceToHost Cancelled arm), silently rewinds the ring to the TD start, and
   the restarted ring re-executes the TD with a brand-new URB — a request for data that no
   longer exists. Nothing ever completes it. That is the 16 s.

Outcome 3 fits every observation, uniquely:

* total silence (device owes nothing on stream 3; ring 2's re-executed 192B TD — tag 2's
  exchange was likewise past its data — starves equally silently, which is why no spurious
  s2 event appears either);
* the 16 s ends only when UASPStor sends a TASK MANAGEMENT IU (the 16 B EP2 transfer at
  01:10:07.4008!) and, 500 ms later (the response at .9046), re-drives the read — whereupon
  the very same 256 B transfer completes 0x0 in microseconds: the device was never wedged,
  the TAG state was;
* the identical SetTRDeq pointer at the retry (the ring rewound back to the TD when the
  second stop cancelled the starving re-execution);
* why cold attaches stranded in run5 (outcome 2 + missing restart) but a WARM attach strands
  in run6 (outcome 3 — the race with actual delivery needs a fast device);
* and why bare metal never sees this: a real xHC never discards; a Stop Endpoint freezes the
  transfer with link-level flow control holding the unacknowledged data at the device, and a
  restart RESUMES — no data can fall between two URBs, because there is only ever one
  transfer. crosvm's stop = cancel-URB + rewind + re-execute-from-scratch is the structural
  divergence, and it only bites on the SILENT ring: the REPORTED ring's URB is
  cancel-completed and UASPStor re-drives that exchange at the SCSI level (fresh command IU —
  section 2a), so lost data there never matters.

### The one competing mechanism that survives the evidence (ranked #2)

M2: "ring 3 never re-executed at all" — some unfound loss between `trc.start()` and the
backend (a swallowed event-loop wakeup, or an unconsidered state). I found no code path: the
signal/state machine in start()/on_event has no hole I could construct, the empty-park and
cycle-mismatch paths log at debug! (invisible in run6's info-level log, so they cannot be
excluded by the log either), and the second stop's instant Stopped-shaped completion mildly
favours an in-flight transfer being cancelled. M2 predicts the same 16 s silence, so run6
cannot separate them; the discriminators below can. Note M2 would ALSO not be fixed by any
doorbell logic — under M2 the bug would be in ring_buffer_controller — so the next
instrumented run decides where the next commit lands, but the DATA-LOSS mechanism of
section 5 is real in either case (it is forced by outcome-3 reaps existing at all) and is
what the proposed fix addresses.

## 6. Proposed fix (minimal), tests, and the confirming device evidence

**Fix: a cancelled transfer whose reap moved the TD's whole length is a completion, not a
stop.** File `devices/src/usb/xhci/xhci_transfer.rs`, `XhciTransfer::on_transfer_complete`,
the `TransferStatus::Cancelled` arm (~line 441): compute the TD's data length (sum of
`transfer_length()` over Normal/DataStage/Isoch TRBs — the same walk `stopped_at` does; add a
small `td_data_length()` helper). If `bytes_transferred >= td_len && td_len > 0` and the ring
is not drained-ahead (`!self.on_drained_ahead_ring()` — an isochronous sweep keeps its
one-Stopped semantics), then do NOT `record_stopped`: fall through to the Completed handling
and send the normal IOC/ISP transfer events. The data is already in the guest buffer (the
backend's Cancelled arm copies it before calling on_transfer_complete). The ring then parks
where it stands — past the TD — via the existing `take_stopped() == None` path; no rewind, no
re-arm, no claim consumed; the claim stays available for a ring that really was mid-TD
(existing behaviour, already tested). Guest-visibly this turns the failing case into cold3's
clean shape: the s3 URB completes 0x0 right at the stop, Windows never re-arms anything.

This also closes a latent write-corruption hazard: today a fully-delivered OUT TD on a silent
ring is rewound and re-executed, re-sending the data IU to the device.

Keep d849baf as is — it remains the correct and needed fix for outcome 2 (cold attach, data
still owed), which run6 never exercised.

Residual (document, don't fix now): a silent ring cancelled with 0 < bytes < td_len. The
re-executed TD then receives the REMAINDER of the device's IU into a fresh full-size URB
(data misaligned but a completion arrives, no strand). The true cure is resume-not-reexecute
(keep the backend URB alive across the stop and adopt it on restart), which is architectural.

**Unit tests** (xhci_transfer.rs / transfer_ring_controller.rs, existing Fixture + helpers):
1. `a_cancelled_td_that_moved_every_byte_completes_instead_of_stopping`: TD of 0x100,
   `on_transfer_complete(&Cancelled, 0x100)` → one normal Success event (IOC), and
   `take_stopped()` is None.
2. Stream-claim interplay: two stream handlers sharing one claim; s2 cancelled at 0x40/0x100
   → claims + Stopped event; s3 cancelled at full length → Success event, claim untouched
   (mirrors `a_stream_that_completed_before_the_cancel_leaves_the_claim...`).
3. Partial stays a stop: `(Cancelled, 0x40)` on a 0x100 TD → today's Stopped path (existing
   tests keep passing).
4. Drained-ahead ring excluded: a swept isoch TD reaped at full length still joins the
   stopped set (guards the `a_drained_ring_stop_reports_one_stopped_event...` semantics).

**Instrumentation to add in the same commit (the discriminators, all debug!):**
* `ring_doorbell`: the existing entry line is `xhci_trace!` (cros_tracing — compiled out in
  these builds); add a real `debug!("slot {} ep {}: doorbell stream {} restarts {} stream
  rings", ...)` — today NO log line proves a doorbell arrived, which is what made run6
  ambiguous.
* the Cancelled arm: `debug!("slot {} ep {} stream {:?}: cancelled TD at {:#x}: {}/{} bytes
  moved", ...)` — separates outcomes 2/3/partial on the next run and decides M2 vs M-A
  outright (M-A shows `256/256`; M2 shows the line missing entirely for the second
  execution).
* `TransferRingTrbHandler::handle_transfer_descriptor`: `debug!("slot {} ep {} stream {:?}:
  submitting TD at {:#x}", ...)` — proves/disproves the re-execution itself.

**Device evidence that confirms the fix** (run7, same 4×(1+2) matrix, crosvm at debug level
for `devices::usb`): (a) no DCI-7 strand > 3 s and zero Kernel-PnP 902 across all 12
attaches; (b) at least one stop whose metrics would previously have printed two 0xC0000120
lines instead shows one 0xC0000120 (reported ring) and one 0x0 completing within ~1 ms of the
stop (the reclassified full-length reap), with no bare45 following; (c) in the debug log, a
`cancelled TD ... N/N bytes moved` line at that stop, and every `doorbell ... restarts` line
paired with `submitting TD` lines on the restarted rings; (d) no 16 B task-management IU on
EP1-OUT during any attach (UASPStor never needed the abort path). If instead a strand
recurred with the log showing `0/256 bytes moved` and no `submitting TD` after the doorbell
line, mechanism M2 is real and the hunt moves into ring_buffer_controller with the exact
wakeup that vanished.

## 7. Answers to the specific questions asked

* Set TR Dequeue completion codes: all seven SetTRDeq commands in c2 (3 stops × 2 streams +
  the retry's 1) completed code=1; both DCI-7 Stop Endpoints in the failing attach completed
  code=1; no 19/5 anywhere. The submit/complete TRB "mismatch" in the gaps file
  (…0000400701 vs …0001400701) is only the command-ring cycle bit on the second lap.
* Doorbell-after-restart → Context State Error: cannot have occurred invisibly — the 19 would
  have appeared in the 33 events, and they all say 1.
* Cycle/DCS on rewind vs SetTRDeq: consistent by construction (rewind cycle is read from the
  TD's first TRB; write-back and the guest's echo carry the same bit); a Windows rewrite of
  the re-armed TD would use the same producer cycle it just set via DCS, so no
  park-empty-on-mismatch path is reachable from the observed commands.
* XhciTransfer on a re-executed TD: a brand-new XhciTransfer + fresh backend URB, no dedupe —
  the failure is not in accepting the TD, it is that the data for it was consumed by the
  discarded first URB.
