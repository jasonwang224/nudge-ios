# 1.1.11 (23): 10-, 15- and 30-minute shared-card nags

Extends the 1.1.10 five-minute scheduling and card-preservation method to the requested intervals. Hourly groups use 12 entries for 5 minutes, 6 for 10, 4 for 15 and 2 for 30. Every phase within an occurrence uses the same notification identifier and existing Snooze/Done actions.

Allocation reserves each reminder's first alert before allocating full groups and accounts for mixed group sizes. Accepted groups retain priority; limited-queue fallback and warnings still apply if capacity is insufficient. One-minute nags retain their existing method; 2- and 20-minute nags are unchanged.

Compatibility: the existing phase and anchor keys remain intact. Old five-minute groups with no interval field are interpreted as five-minute groups. Newly scheduled groups record their interval, and group validation checks the interval, phase count, unique phase indices, hourly trigger unit, first dates and reminder content. Changing an interval continues to create a new generation through the existing lifecycle.

No reminder database migration or reset is performed. Card protection, journaled scheduling, interruption recovery, unknown-record preservation and near-delivery guards are unchanged. Install over the existing app and open it to update accepted schedules. Check the status for capacity or recovery warnings before closing it.

Validation: existing regression suites plus seven-day arithmetic for all 60 starting minute offsets at every supported interval, mixed-capacity allocation, old five-minute metadata, archive/multiset checks, and Snooze/Done/edit isolation for each interval. These are build/model checks. The user confirmed five-minute device behavior; 10/15/30-minute Lock Screen behavior still requires device testing on iOS 17.4.1.

Device checks: leave a reminder at each new interval running with the app closed; verify one card per reminder, unrelated cards retained, correct sounds and spacing, operation beyond the first hour, Snooze for 15 minutes followed by the selected cadence, and Done cancelling only that occurrence. The private scheduling transaction still has the documented interruption/recovery limitation from 1.1.10.
