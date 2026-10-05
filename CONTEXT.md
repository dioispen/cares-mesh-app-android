# CARES Mesh

An off-grid disaster-response mesh built on bitchat. Survivors publish their condition and location over a Bluetooth LE mesh with no infrastructure; Rescuers — often other survivors — read those reports to prioritise who to reach first.

## Language

### Reporting

**Health Report**:
A self-published statement of a Status and position at a moment in time, under a Reporter Handle. The system never knows whether a real survivor stands behind it; reports sent during field experiments are Health Reports too.
_Avoid_: disaster report, casualty record, 實驗封包, test packet

**Status**:
The survivor's own description of their physical condition — 安全, 輕傷, or 重傷. Always self-declared; never verified by the system.
_Avoid_: severity, injury level, triage state

**Reporter**:
The person who published a Health Report, known to receivers only through its Reporter Handle. Distinct from the device that relayed it.
_Avoid_: victim, casualty, user

**Reporter Handle**:
The opaque, random pseudonym of one app installation, under which every Health Report from that installation is published. Receivers treat one Reporter Handle as one Reporter, so two people sharing a phone appear as one, and a reinstall appears as a new Reporter.
_Avoid_: broadcast handle, user ID, peer ID

**Rescuer**:
Anyone who reads a Health Report in order to go and help its Reporter, including other survivors. A role taken by acting on a report, never an identity the system verifies.
_Avoid_: responder, rescue team, 救援人員

### Disclosure

**Broadcast Tier**:
The part of a Health Report every device in range may read — the Reporter Handle, the Status, and an approximate location. Carries nothing that identifies a person.
_Avoid_: public payload, tier 1, summary

**Detail Tier**:
The part of a Health Report withheld from broadcast — real name, phone number, blood type, precise location, free-text description. Released only to a specific Rescuer, on request, over an established secure session.
_Avoid_: private payload, tier 2, PII blob

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
