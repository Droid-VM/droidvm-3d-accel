# run5 ETW reconstruction: why one stream URB strands 16 s after the first Stop Endpoint on cold attach

Sources: run5/usbtrace-c{1,2,3}.xml.gz (raw ETW, parsed directly; focused extracts in
run5x-c1-win.txt, run5x-c2-win.txt, run5x-c3-win.txt, run5x-c1-warm.txt, run5x-c1-slow.txt in
this directory), run5/w3-cold{1,2,3}-metrics.txt, w3-cold{1,2,3}-gaps.txt, w3-cold1-crosvm.log.
Code: crosvm f96fd65, tree clean.

## 0. What the ETW can and cannot show (event-id semantics, established from the traces)

* No USBXHCI event in these traces carries a per-transfer completion code. `fid_CompletionCode`
  appears on exactly 42 events in c1 and all 42 are command completions (event 33), all code=1.
  The Stopped Transfer Event (code 26/27) crosvm sends is therefore NOT directly visible; it is
  reconstructed below from which URB Windows completes with STATUS_CANCELLED (0xC0000120) and
  which it leaves pending.
* USBXHCI 41 "USB transfer initialized" (fields SlotId, EndpointContextIndex, StreamId,
  BytesTotal) = first mapping of an URB to ring TRBs. USBXHCI 45 (same fields minus BytesTotal)
  = the transfer being armed / handed to hardware. Proof that 45 is SUBMISSION, not completion:
  cold1 22:54:09.110, URB 0xFFFFB183EE4EBBA0 (512 B) shows 26 Start -> 41 -> 45 at .110 and its
  UCX 27 Stop (completion, status 0x0) only at 22:54:11.090, 1980 ms later, with no 45 at
  completion time (run5x-c1-slow.txt). A **bare 45** (no adjacent 41) is a re-arm of an
  already-initialized transfer; bare 45s also appear on EP2/stream 0 for every re-used URB.
* USBXHCI 42/43/44 are interrupt/DPC bracket noise. UCX 26/27 = URB start/complete
  (fid_IRP_NtStatus: 0x0 success, 0xC0000120 STATUS_CANCELLED).
* Set TR Dequeue TRB decode (fid_Command_TRB, 16 bytes in memory order, dwords LE):
  dword0 = ptr low | DCS(bit0) | SCT(bits3:1); dword1 = ptr high; dword2 bits31:16 = stream id;
  dword3 = slot(31:24) | endpoint(20:16) | type 16 (bits15:10).
* The endpoint under test: slot 1, DCI 7 (UAS 152d:a583 data/status IN with streams 2,3).
  DCI 5 also carries streams 2/3; only DCI 7 receives Stop Endpoint.

## 1. cold1 (FAILING, 18.7 s disk start) -- first Stop Endpoint 22:53:52.409

In flight on DCI 7 at the stop: stream 2 URB 0xFFFFB183EE4EBBA0 (256 B, armed .409, pipe
EEAA5BE0) and stream 3 URB 0xFFFFB183EE4EBD60 (192 B, armed .409, pipe EEAA5C28). The DCI 5
stream URBs completed 0x0 in the same ms, before the stop took effect.

Sequence (trace order within the ms):
1. 31 Stop Endpoint (TRB ...003C0701, slot 1 DCI 7) -> 33 code=1, same ms. crosvm completes the
   command only after every stream ring parked (RingBufferStopCallback), so by now both rings
   are rewound to their cancelled TDs and both stream contexts are written back.
2. 31 Set TR Dequeue stream 2, ptr 0x1_763B5800 DCS=1 SCT=1; 31 Set TR Dequeue stream 3,
   ptr 0x1_763B5A00 DCS=1 SCT=1; both 33 code=1 at .410. BOTH streams are re-pointed, in order
   s2 then s3, submitted back-to-back before either completes. The pointers are exactly what
   crosvm wrote back into the stream contexts (the rewound TD first-TRB + cycle): Windows echoes
   crosvm's reported position.
3. .410: UCX 27 for the STREAM-3 URB EE4EBD60, status 0xC0000120 -- Windows completes-cancels
   s3's URB. (UASPStor re-issues it later as part of normal flow.)
4. .410: bare 45, EndpointContextIndex 7, StreamId **2** -- Windows re-arms the stream-2
   transfer to hardware. No new 41: same URB, TDs believed still queued on the ring.
5. Then NOTHING. From 22:53:52.410 to 22:54:08.602 the entire trace contains only 8 Kernel-PnP
   query lines and the 902 watchdog: zero USBXHCI 41/45, zero UCX 26/27, zero commands, on any
   endpoint or stream. No re-point, no activity, no completion touches stream 2. crosvm's log
   has no line at all in the window (info level; no error!/warn! fired).
6. 22:54:08.602 (16.19 s): UASPStor timeout -> second Stop Endpoint -> 33 code=1 ->
   Set TR Dequeue stream 2 ONLY, with the IDENTICAL TRB value (ptr 0x1_763B5800 DCS=1) -> 27 for
   EE4EBBA0 status 0xC0000120 at 22:54:08.603. The URB is re-initialized at 22:54:09.110
   (26 -> 41 -> 45) and completes 0x0 at 22:54:11.090 (1980 ms = device busy/spin-up, not hung).

Stranded stream: **2** (metrics: 16194 ms, urb=0xFFFFB183EE4EBBA0). Which stream got crosvm's
one Stopped Transfer Event: **3** -- inferred, see section 4.

## 2. cold3 (FAILING, 16.6 s) -- first Stop Endpoint 23:10:37.028: exact mirror

In flight on DCI 7: s2 URB 0xFFFF8C8298B7F2A0 (256 B... the 8/12/64/256 B command-response
pipe traffic), s3 URB 0xFFFF8C8298B7C520 (256 B, armed .028). Sequence: Stop 31/33 code=1 ->
SetTRDeq s2 ptr 0x1_78BFC800 DCS=1, SetTRDeq s3 ptr 0x1_78BFCA00 DCS=1, both code=1 -> 27 for
the STREAM-2 URB 8B7F2A0 status 0xC0000120 -> bare 45 EP7 StreamId **3** -> total silence
(only Kernel-PnP 702/703 + the 902 watchdog) until 23:10:53.157 -> second Stop -> SetTRDeq
stream 3 ONLY -> 27 for 8B7C520 0xC0000120. Stranded stream: **3** (16131 ms). Reported
stream: **2**. Roles exactly swapped vs cold1 -- the claim is won by whichever ring's cancel
reaps first.

## 3. cold2 (CLEAN, 12 ms) and a warm cycle (CLEAN, 11 ms)

cold2, first stop 23:04:34.971: both DCI-7 stream URBs (s2 BB7CDE0, s3 BB80260) and both DCI-5
ones complete with status 0x0 naturally in the same ms, straddling the Stop 31/33. At the
instant the stop takes effect NO stream ring holds an unretired TD. SetTRDeq s2
(ptr 0x1_78510800) + s3 (0x1_78510A00) still issued, both code=1; **no 0xC0000120, no bare
45**; the s3/s2 URBs are re-armed within the same ms and traffic continues.

warm (3rd stop inside the c1 trace, 22:56:41.827, metrics said streams '2','3' queued that ms):
the s3 URB EE4F1860 and the DCI-5 URBs complete 0x0 during the stop handshake; only the s2 TD
(EE4F37E0) is actually cancelled. SetTRDeq s2 (0x1_02947800) + s3 (0x1_02947A00) -> 27 for the
s2 URB status 0xC0000120 immediately after the SetTRDeq completions -> **no bare 45** -> fresh
41+45 on s3 at .828, traffic flows. Same shape at the 4th stop and in all six warm cycles of
the aw trace (0 watchdogs).

**The precise difference:** a strand happens if and only if TWO stream rings hold a cancelled
TD when the stop lands (cold1, cold3: 2 of 2 such stops strand; every stop with <=1 cancelled
TD is clean: cold2, both warm stops in c1, all aw cycles). With one cancelled TD, the one
Stopped event names it, Windows completes that URB 0xC0000120 and re-issues it: clean. With
two, the claim winner's URB is completed-cancelled and re-issued, and the OTHER (silently
rewound, never reported) stream's URB is kept pending by Windows -- Windows re-points its ring
to crosvm's written-back TD position and re-arms the transfer (the bare 45, always carrying the
stranded stream's id), then waits for the controller to execute the still-queued TD. Nothing
ever runs it. Warm vs cold is only the race: on cold attach the disk is spinning up, both
outstanding reads are slow, so both TDs are still unretired when UASPStor's start-up Stop
Endpoint arrives.

## 4. Which stream got crosvm's Stopped event (reconstruction)

The warm case calibrates Windows's behavior: with exactly one cancelled TD, crosvm's Stopped
event names that TD (only claimant), and Windows's response is to complete that URB with
0xC0000120 right after its SetTRDeq. In cold1/cold3 the URB completed 0xC0000120 in that same
position is s3's/s2's respectively -- so the claim winner (= reported stream) is the stream
whose URB Windows released, and the stranded stream is the one that got NO event: the ring
f96fd65 rewinds silently. Windows's model matches real hardware (xHCI 4.12.1.1/4.6.9): an
unreported stream TD is simply still pending on its ring and will be executed once the endpoint
is restarted; no URB completion is due for it.

## 5. crosvm code walk (f96fd65)

* devices/src/usb/xhci/device_slot.rs stop_endpoint, stream branch (lines ~918-967): one shared
  Arc<AtomicBool> claim set on every stream ring, trc.stop(auto_cb) each; auto_cb writes every
  populated stream context (ptr/DCS, Stopped EDTLA only for td.reported) and completes the
  command after all rings parked. Matches the ETW: 33 code=1 arrives with contexts written.
* ring_buffer_controller.rs stop (312) / finish_stop_and_park (365) / on_event Stopping branch
  (426): the last cancelled-transfer reap triggers finish_stop -> handler.finish_stop(claim) ->
  Stopped event only for the claim winner (transfer_ring_controller.rs finish_stop, ~100-150:
  compare_exchange; loser logs "rewound silently" at debug and sends nothing) -> ring rewound to
  td.first_trb/cycle -> Stopped -> callbacks release. Event-before-command ordering is right.
* set_tr_dequeue_ptr / set_stream_tr_dequeue_ptr (1061-1194): checks Stopped/Error state,
  writes the Stream Context, and sets the live ring's dequeue pointer + DCS. Correct; both
  guest SetTRDeq commands in the traces completed code=1 and crosvm's ring position equals the
  guest's (identical echo at the 16 s retry).
* ring_doorbell (441-489) + doorbell_callback (mod.rs 461, stream id = value >> 16): for a
  stream endpoint it resolves get_trc(index, stream_id) -- the ONE addressed ring -- flips the
  Endpoint Context Stopped -> Running, and calls start() on that single ring. Every other
  parked stream ring of the endpoint stays Stopped forever until a doorbell carries its
  specific id. THIS is the divergence from hardware: per xHCI 4.12.2 the doorbell's Stream ID
  is a HINT; restarting the endpoint resumes servicing of ALL streams with pending TDs (the
  device ERDYs them). Windows relies on that: it re-armed the silent stream's TD and rang the
  doorbell it saw fit; crosvm started at most the hinted ring.
* Elimination: could crosvm have received a doorbell FOR the stranded stream and failed to run
  it? No plausible path: start() -> on_event -> dequeue at the (correct, verified) pointer/DCS
  -> handle_transfer_descriptor -> backend, is the same machinery that executes the identical
  re-issued transfer at 22:54:09.110 in 1980 ms from the same parked-endpoint state (doorbell
  s2 after the second stop: Stopped -> Running -> executes). Had the TD been submitted at
  .410, the device would have answered in ~2 s, not exactly at the moment of the second stop's
  cancel. And a host-side hang is excluded by the same 1980 ms success. So the 16 s of zero
  activity means the silent ring was never started: the doorbell Windows rang after re-arming
  did not carry the silent ring's id (or Windows considers the endpoint already restarted by
  the doorbell it rang with the reported stream's id when re-issuing nothing -- either way, no
  doorbell that crosvm maps to the silent ring ever arrives, which under hardware semantics is
  legal, because any doorbell restarts the endpoint as a whole).

Note also: run4 (pre-f96fd65, one Stopped per ring) stranded the stream whose SECOND Stopped
event Windows discarded as a duplicate -- same downstream state (Windows believes the TD is
still on the ring, hardware must run it on restart) -- so run4 and run5 are one bug with two
entrances, and the missing piece was always the restart, not the report count.

## 6. Verdict on the DESIGN-STREAM-RESTART.md hypothesis: PARTIAL (core holds, two details corrected)

HOLDS: crosvm cancels every stream ring's in-flight TD, reports ONE Stopped event (claim), and
silently rewinds the others; real hardware leaves unreported stream TDs pending and runs them
on any endpoint restart; in crosvm each stream ring restarts only on a doorbell carrying its
own id; the stranded URB is on the SILENT (unreported) ring both times; no doorbell that
crosvm maps to that ring arrives before the 16 s timeout. The decision's fix targets the real
gap.

CORRECTED BY THE EVIDENCE:
1. "Windows re-points (Set TR Dequeue) only the stream it considers current" -- false. Windows
   issues Set TR Dequeue for BOTH open streams at every stop (even in the clean cases), and it
   is the STRANDED/silent stream, not the reported one, that it additionally re-arms (bare 45).
   "whether ANY activity or re-point touched that stream" -- yes: one SetTRDeq (code=1) and one
   re-arm touched it, then 16.1-16.2 s of nothing.
2. "Warm cycles may differ because the class driver cancels both tags' URBs" -- false. Warm
   cycles show the identical driver behavior; they are clean only because at most one stream
   ring still held an unretired TD when the stop landed (the other URBs had just completed
   0x0). Cold attach loses that race on both streams at once because the disk is spinning up.

## 7. Recommended fix (the design's doorbell-restarts-all, confirmed; minimal, in device_slot.rs)

In DeviceSlot::ring_doorbell, when the endpoint resolves to TransferRingControllers::Stream and
the endpoint state is Running or Stopped: after validating the addressed stream id exactly as
today (invalid / Not Valid stream ids stay ignored, nothing else changes for them), start()
the addressed ring AND every other populated (Some) stream ring of that endpoint -- restart
rings that are parked Stopped; do not touch the halt path (halt_requested / a Halted endpoint
never gets here, the endpoint-state gate already blocks it). An empty ring re-parks on its
first on_event pass (existing None branch); a rewound ring re-executes its TD, and the fresh
backend URB fetches the data the device is still holding for that tag. Spec cover: xHCI 4.12.2
(doorbell Stream ID is a hint; the xHC may service any stream) -- restarting all populated
rings is exactly hardware's observable behavior. Windows is fixed because whatever hint its
post-stop doorbell carries, the silent ring starts and completes the re-armed TD; Linux is
unaffected (it doorbells each stream it restarts; extra starts of empty rings are no-ops).
Guard detail for the implementation: only call start() on the non-addressed rings, not any
stop/claim bookkeeping; start() already clears a parked ring's stale StoppedTd/claim, which is
correct since the stop those belonged to has completed (command completion precedes any
doorbell).

Plus, as the design already decided: downgrade device_slot.rs:887
`error!("endpoint at index {} is not running", index)` to debug! (Linux triggers it
legitimately twice per run; the Context State Error completion is the guest-visible answer).

Tests (device_slot.rs Fixture, stream endpoints + f96fd65's #[cfg(test)] helpers
set_stopped_td_for_test / stop_event_claim_for_test): (a) stream endpoint stopped with two
rings holding cancelled TDs -> doorbell for stream 2 restarts BOTH rings (both Running, the
silent one re-dequeues its TD); (b) doorbell on a plain endpoint unchanged; (c) doorbell for a
Not Valid / out-of-range stream still ignored and starts nothing (extend the existing 2895-2901
assertions to check the other rings stayed parked).

One commit: "xhci: a doorbell restarts every stream ring of the endpoint" (+ the log
downgrade), trailers per the design. Host tests with the rng shim, clippy, restore rng.rs
before committing; no phone, no push.
