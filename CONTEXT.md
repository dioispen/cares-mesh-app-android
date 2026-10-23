# CARES Mesh

An off-grid disaster-response mesh built on bitchat. Survivors publish their condition and location over a Bluetooth LE mesh with no infrastructure; Rescuers — often other survivors — read those reports to prioritise who to reach first.

## Language

### Reporting

**Health Report**:
A self-published statement of a Status and position at a moment in time, under a Reporter Handle. The system never knows whether a real survivor stands behind it; reports sent during field experiments are Health Reports too.
_Avoid_: disaster report, casualty record, 實驗封包, test packet

**Status**:
The survivor's own description of their physical condition — 安全, 輕傷, or 重傷 — or 未宣告 when they raised an SOS without stating it. Always self-declared; never verified by the system.
_Avoid_: severity, injury level, triage state

**SOS**:
A Reporter's standing request to be rescued, carried on each of their Health Reports until they withdraw it or declare 安全. A mark on a Health Report, not a separate kind of report.
_Avoid_: SOS request, emergency request, distress signal

**Reporter**:
The person who published a Health Report. Over the mesh they are known only through their Reporter Handle; on the backend, the Detail Tier names them. Distinct from the device that relayed it.
_Avoid_: victim, casualty, user

**Reporter Handle**:
The opaque, random pseudonym of one app installation, under which every Health Report from that installation is published. Receivers treat one Reporter Handle as one Reporter, so two people sharing a phone appear as one, and a reinstall appears as a new Reporter.
_Avoid_: broadcast handle, user ID, peer ID

**Rescuer**:
Anyone who reads a Health Report in order to go and help its Reporter, including other survivors. A role taken by acting on a report; the system does not verify it.
_Avoid_: responder, rescue team, 救援人員

**Verified Rescuer**:
A Rescuer whom the project has verified out of band and listed on the backend. The only identity the system verifies, and only ever granted by an administrator, never by the app. Being one unlocks nothing on its own — only the Sensitive Tier of the Reporters they are currently the Helper for.
_Avoid_: rescue team, admin, 救援人員

**Administrator**:
An account the project has listed on the backend to run the management dashboard, granted only out of band, never by the app. The only role that can read Gateway uploads and which account a Reporter Handle belongs to. Independent of Verified Rescuer: holding one grants nothing of the other.
_Avoid_: admin user, 管理中心 (the organisation, not the account), Verified Rescuer

**Mutual-aid Task**:
A Health Report whose Status calls for help (輕傷 or 重傷), offered to Rescuers to take on. It is waiting until a Rescuer accepts it, then accepted until that Rescuer completes or releases it.
_Avoid_: rescue request, ticket, job

**Helper**:
The Rescuer who has accepted a Mutual-aid Task, from accepting it until they complete or release it. A task has at most one Helper at a time. Any Rescuer may become a Helper; verification is not required.
_Avoid_: assignee, volunteer, 協助者 (when the Rescuer has not accepted)

### Disclosure

**Broadcast Tier**:
The part of a Health Report every device in range may read — the Reporter Handle, the Status, and an approximate location. Carries nothing that identifies a person.
_Avoid_: public payload, tier 1, summary

**Detail Tier**:
The part of a Health Report withheld from broadcast but open to every signed-in account on the backend — real name, residential area, precise location, and the injury detail chosen with the Status. What a Rescuer needs to decide whether to go and to find the Reporter.
_Avoid_: private payload, tier 2, public profile

**Sensitive Tier**:
The part of a Health Report that tells someone how to reach and treat the Reporter — phone number, blood type, medical history, emergency contacts. Released only to the Reporter and to a Verified Rescuer while they are the Helper on that Reporter's Mutual-aid Task.
_Avoid_: PII blob, private payload, 個資

### Relaying

**Severity**:
A routing hint carried in the packet header, derived by the sending device from the Reporter's Status. Relays read it to decide how hard to work at forwarding a packet. It is a transport concern — relay code never learns what injury it represents.
_Avoid_: priority, urgency, 嚴重度 (ambiguous between this and Status)

**Severity Inflation**:
A Reporter declaring a Status more serious than their real condition, so their packets are relayed more aggressively. Cannot be prevented, only measured.
_Avoid_: cheating, abuse, spoofing

**Relay Decision**:
A device's choice about whether to forward a packet it received but was not addressed to, and when to send it relative to the other packets waiting to leave.
_Avoid_: routing, forwarding policy

**Severity-aware Relay**:
Any way of making Relay Decisions that reads Severity — weighting the chance of forwarding, ordering what is sent first, or both.
_Avoid_: severity routing, priority relay, 嚴重度傳播策略

**Gateway**:
A signed-in device with internet access that writes the Broadcast Tier of other Reporters' Health Reports, received over the mesh, to the backend. A relay passes a packet on to the mesh; a Gateway passes it out of the mesh. It never carries the Detail or Sensitive Tier, and the backend does not verify what it writes.
_Avoid_: uplink, bridge, 代理上網, relay (when the packet leaves the mesh)
