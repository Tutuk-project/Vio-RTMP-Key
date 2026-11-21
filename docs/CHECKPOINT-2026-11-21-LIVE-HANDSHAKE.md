# Vio RTMP Key — Checkpoint Audit LIVE Handshake
**Date:** 2026-11-21 (Asia/Jakarta)  
**Repository:** [Tutuk-project/Vio-RTMP-Key](https://github.com/Tutuk-project/Vio-RTMP-Key)  
**Branch:** `main`  
**Latest code commit:** `935fd640b69195823df7deb52976e9ab5ab1f019`

## 1. Test evidence received

Test logs from 21 November 2026:

- `GO_LIVE`: `create_room` returned HTTP 200 and `status_code=0`.
- The old diagnostic only inspected `data.room_id`; it reported no room ID.
- `prompts_present=false`.
- `END_STREAM` was called with an empty `room_id`; the old implementation still returned `true` because it only checked HTTP 200, `status_code=0`, and absence of prompts.
- The TikTok web page displayed **“LIVE will begin shortly”**.
- The external streaming app showed a green indicator and a running timer, but the TikTok page did not transition to a visible LIVE session.

No cookie values or RTMP credentials are stored in this report.

## 2. Findings

### Confirmed defects in the repository code

1. **Room ID extraction was incomplete.**  
   The code only read `data.room_id`. The inspected LIVE Studio protocol notes specify that the room ID can be returned as `data.living_room_attrs.room_id_str`; the stream ID is `data.stream_id_str`. The old model discarded the stream ID entirely.

2. **The old GO_LIVE success condition was too permissive.**  
   A response with `status_code=0` could be treated as successful even when the room identifiers or RTMP URL were missing. That created false-positive success states.

3. **SDK version formatting was incorrect.**  
   The previous code removed both periods and every zero from `webcast_sdk_version`. With LIVE Studio version `1.12.0`, it generated `112`; the protocol format removes periods only, yielding `1120`.

4. **Create-room POST omitted request headers used by the inspected protocol.**  
   The request did not set `sdk_aid` or `x-ss-stub`. The current implementation adds both and explicitly encodes the form body so the checksum is calculated from the submitted body.

5. **The old End Stream request did not identify the room.**  
   It posted to `finish_abnormal/` without a room ID or stream ID. The HTTP response therefore did not prove that the intended room had ended.

### Protocol-level limitation still open

The inspected protocol notes describe a separate anchor lifecycle:

- `POST /webcast/room/ping/anchor/` with `status`, `room_id`, and `stream_id`.
- Status `1` means preparing; status `2` means live; status `4` means finished.
- The anchor ping is expected every five seconds.
- The same protocol notes describe native MetaSec signing and distinguish the RTMP push URL from the additional stream metadata needed by LIVE Studio.

The current Vio app still does **not** implement TikTok MetaSec request-signature generation or stream-frame/SEI signing. It also does not run an Android foreground service. A Dart timer is not guaranteed to keep firing while Vio is backgrounded behind the external streaming app. These gaps mean this checkpoint is a protocol and false-success repair, **not proof that public LIVE activation is fixed**.

## 3. Changes committed to main

| Commit | Change |
|---|---|
| `70eec6607d1c218736f0fa8f724fadf9a17d8add` | Fix SDK version formatting, parse nested room/stream IDs, validate room response, add anchor ping request and correct end status endpoint |
| `1762bc554f92ab813a924a1a30c9ed4fbb76f1d5` | Add `crypto` dependency for request body checksum |
| `2ab11f6da3a5771462fc51fff0bf5b8037a4edd2` | Preserve stream ID in `StreamInfo` |
| `935fd640b69195823df7deb52976e9ab5ab1f019` | Add five-second anchor heartbeat and UI control to send status 2 after the external encoder starts |

### Parameter request berubah?
**Ya.**

- `webcast_sdk_version` now removes periods only.
- Create-room POST now includes `sdk_aid=8311`, `x-ss-stub`, and explicit form content type.
- Anchor ping uses form fields `status`, `room_id`, and `stream_id`.
- End Live now sends anchor status `4` rather than an empty `finish_abnormal` request.

The server URL resolution logic and user-selected priority-region value were not changed in this patch.

## 4. Required next validation

1. Rebuild and install the APK from the latest `main`.
2. Run Go Live once and check that the diagnostic output now contains `room_id_present=true`, `stream_id_present=true`, and `rtmp_url_present=true`.
3. Start the external streaming app and then press **“Saya sudah mulai streaming”** in Vio.
4. Check the anchor-ping log for HTTP status, API status code, and result. Do not treat the external app's green indicator or timer as proof that TikTok is LIVE.
5. Verify the TikTok web/app page actually transitions from “LIVE will begin shortly” to a visible LIVE state.

## 5. Build and live-test status

- Repository source changes: committed to `main`.
- Static source readback: completed for the changed files.
- Flutter analyze / APK build: **not run in this environment**; Flutter and Dart executables are unavailable here. The repository workflow is currently manual (`workflow_dispatch`).
- End-to-end TikTok LIVE verification: **pending**; no fresh live test was performed by this audit.

## 6. External protocol references

- [LIVE Studio protocol notes](https://github.com/averagenative/tiktok-live-studio-linux/blob/main/docs/PROTOCOL.md)
- [Loukious TikTokStreamKeyGenerator README](https://github.com/Loukious/TikTokStreamKeyGenerator/blob/main/README.md)

The references describe reverse-engineered, version-sensitive behavior. TikTok can change these endpoints and requirements without notice.
