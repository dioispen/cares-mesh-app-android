# CARES Mesh

An off-grid disaster-response mesh built on bitchat. Survivors publish their condition and location over a Bluetooth LE mesh with no infrastructure; rescuers read those reports to prioritise who to reach first.

## Language

### Reporting

**Health Report**:
A survivor's self-published account of their own condition, position and contact details at a moment in time.
_Avoid_: disaster report, casualty record

**Status**:
The survivor's own description of their physical condition — 安全, 輕傷, or 重傷. Always self-declared; never verified by the system.
_Avoid_: severity, injury level, triage state

**Reporter**:
The survivor who published a Health Report. Distinct from the device that relayed it.
_Avoid_: victim, casualty, user

### Disclosure

**Broadcast Tier**:
The part of a Health Report every device in range may read — an opaque reporter handle, the Status, and an approximate location. Carries nothing that identifies a person.
_Avoid_: public payload, tier 1, summary

**Detail Tier**:
The part of a Health Report withheld from broadcast — real name, phone number, blood type, precise location, free-text description. Released only to a specific rescuer, on request, over an established secure session.
_Avoid_: private payload, tier 2, PII blob

### Relaying

**Severity**:
A routing hint carried in the packet header, derived by the sending device from the Reporter's Status. Relays read it to decide how hard to work at forwarding a packet. It is a transport concern — relay code never learns what injury it represents.
_Avoid_: priority, urgency, 嚴重度 (ambiguous between this and Status)

**Severity Inflation**:
A Reporter declaring a Status more serious than their real condition, so their packets are relayed more aggressively. Cannot be prevented, only measured.
_Avoid_: cheating, abuse, spoofing

**Relay Decision**:
A device's choice about whether to forward a packet it received but was not addressed to.
_Avoid_: routing, forwarding policy
