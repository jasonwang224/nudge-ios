# 1.1.16 (28): accept equivalent empty notification text

A future reminder moved by five minutes produced a verification warning in 1.1.15. The device report showed that all 24 intermediate pending records were present, with no missing or extra records. Only the new request failed native content equality; the trigger and named content fields matched. A retirement-only retry subsequently completed and retained the requested future time.

The returned iOS 17.4.1 contents show absent body/subtitle values. The request factory explicitly assigns an empty notes string. Native notification record serialization can omit empty text, and Swift can read a nil Objective-C string as an empty String. Native object equality still distinguishes those two representations. This explains why the old diagnostic reported `content.other properties` despite equal public text getters. Native implementation evidence inspected from iOS 18.2 corroborates the mechanism; the physical 17.4.1 retest remains the final confirmation.

The shared comparator first tries unchanged native equality. On failure, it copies both contents, verifies that copying itself preserves equality, and canonicalizes only body/subtitle fields that are empty on both sides. Full native content equality must then pass. It never changes the submitted requests. Nonempty text, title, sound, badge, category, thread, payload, other/private properties, trigger, identifier, pending count and repeated phase multiplicity remain checked.

The comparator is shared by one-minute replacement/retirement verification, hourly-phase schedule verification, mismatch reporting, and delivered-card protection. There are no database changes, schedule-budget changes, new global clears, or changes to notification delivery intervals.

Regression coverage models the nil-text readback using Objective-C setters in test fixtures. Tests must demonstrate raw inequality, normalized equality without input mutation, rejection of genuine concurrent content/trigger changes and missing/duplicate phases, future empty-notes replacement success, and retirement of an already accepted normalized replacement. The normal iOS 17.4 typecheck and complete regression/build pipeline also run.

On the phone, install over the existing app and adjust a future reminder with blank notes using +5 minutes. Repeat with the other time buttons and nag intervals. If a warning remains, the saved notification report is still available in Settings.
