# Outstanding Database Issues - SPRINT-7

## CRITICAL - Missing Table

### `pr_publication_choices` Table Does NOT Exist
**Status**: ❌ MISSING

The `publication_choice` stage type references `pr_publication_choices` in its `data_tables` array, but this table was never created.

**Needs**:
- Migration to create `pr_publication_choices` table
- Store: activity_id, choice (`'published_on_ps'`, `'submitted_externally'`, `'made_private'`), chosen_at timestamp
- For now: focus ONLY on `'published_on_ps'` option
- When choice is `'published_on_ps'`, paper becomes publicly visible in library

---

## TEMPORARY HACKS - Document for Future Cleanup

### Etherpad Pad Creation Timing
**Status**: ⚠️ TEMPORARY HACK

**Current Behavior**:
- Etherpad pads are created during `author_response_1` stage
- This was randomly chosen because all templates have this stage
- This is **NOT** ideal architecture

**Why This is a Hack**:
- Etherpad is used in `assessment` stage, NOT author_response
- Pads should be created when entering `assessment` stage
- Current timing creates pads too early

**Future Fix**:
- Modify stage transition logic to create Etherpad pad when entering `collaborative_assessment` stage
- Remove pad creation from author_response stage
- Add documentation in migrations noting this change

**Where Documented**:
- Migration `00000000000024_pr_assessments.sql` should have comment noting this temporary behavior

---

## ARCHITECTURE CLARITY

### Transition Order Purpose
**Status**: ✅ CLARIFIED & DOCUMENTED

**Current Use**: 
- `template_stage_transitions.transition_order` exists but currently always = 1
- Linear workflows only (one valid transition per stage)
- No branching or multiple exit paths

**Future Use** (NOT YET IMPLEMENTED):
User described future scenarios:
- **User reporting**: Users flag activities/events for admin review
- **Reviewer timeout**: All reviewers kicked out for missing deadlines
- **Admin intervention**: Pause, cancel, or suspend problematic activities
- **Branching paths**: Multiple valid transitions from same stage

**Examples of Future Transitions** (reserved via transition_order):
```sql
-- From any stage:
current_stage → paused_activity (admin pause, order=99)
current_stage → cancelled_activity (admin cancellation, order=98)
current_stage → flagged_for_review (user report, order=97)

-- From assessment stage:
assessment → awarding (normal path, order=1)
assessment → needs_revision (quality issues, order=2)

-- Emergency transitions:
review_1 → activity_suspended (all reviewers removed, order=3)
```

**Why This Approach**:
- Gives platform clear history of what happened to each activity
- When things "go wrong", stage transitions document the deviation
- All lifecycle events visible in timeline

**For Now**: Single transition per stage, transition_order = 1 everywhere

### Stage Runtime Data Purpose
**Status**: ✅ CLARIFIED

**Purpose**: Analytics and performance metrics ONLY (NOT for business logic)

**Example Use Cases**:
- Track how long each stage takes to complete
- Identify which stages are slower/faster than expected
- Adjust template deadlines based on historical data
- Dashboard metrics showing average stage durations

**What it is NOT**:
- NOT for locking mechanisms (Etherpad handles that)
- NOT for storing business state (use dedicated tables)
- NOT for "current editor" tracking (no editors in platform - Etherpad handles collaboration)

**User Clarification**: 
- "I wanted this to have an overview of how long each stage is taking to progress"
- Useful for optimizing deadlines and understanding workflow bottlenecks

---

## JC PARTICIPANTS ARCHITECTURE

### ✅ IMPLEMENTED - Renamed to Participants
- Table: `jc_participants` (NOT `jc_reviewers`)
- Added `is_creator BOOLEAN` column to identify creator participation
- Creator row: `is_creator = true`, invited participants: `is_creator = false`
- Role enum updated: `'participant'` instead of `'reviewer'`

### Semantic Clarity
- **PR Activities**: Creator CANNOT review own paper → separate `pr_reviewers` table
- **JC Activities**: Creator CAN participate → included in `jc_participants` with `is_creator = true`
- More accurate terminology (creator is participant, not "reviewer" of own invited activity)

---

## NOT IMPLEMENTING YET

### Features Deferred to Future Sprints

**Activity Lifecycle Management**:
- ❌ Activity cancellation (no `cancelled_at` field yet)
- ❌ Reviewer removal after 72h timeout (commitment_deadline exists but no background job)
- ❌ Activity auto-cancellation when all reviewers removed
- ❌ Activity pausing/resuming (admin)
- ❌ User reporting/flagging system
- ❌ Penalty system for missing deadlines (lock-in exists but penalties undefined)

**Template Management**:
- ❌ Template deprecation workflow
- ❌ Template versioning strategy (all templates currently v1)
- ❌ Non-public templates (all templates `is_public = true` for now)
- ❌ Template activation/deactivation UI

**Paper Management**:
- ❌ Multiple activities on same paper
- ❌ Paper versioning/revisions
- ❌ Duplicate activity prevention

**JC Specific**:
- ❌ Ability for participants to leave activities
- ❌ Penalties for non-completion (doesn't make sense for free JC anyway)

---

## NOTES ON FUTURE ADMIN FUNCTIONALITY

When admin functionality is added (future sprint), consider:

1. **Activity State Transitions**:
   - Admin override transitions (bypass conditions)
   - Emergency suspension states
   - Forced progression for stalled activities

2. **Deadline Enforcement**:
   - Background jobs checking `activity_stage_state.stage_deadline`
   - Automatic penalties for late submissions
   - Reviewer removal after timeout

3. **Conflict Resolution**:
   - Insurance token pool for paying conflict mediators
   - Admin ability to award tokens manually
   - Activity rollback/reversal mechanisms

4. **Audit Trail**:
   - All admin actions logged
   - Reasoning/notes for admin overrides
   - User notifications when admin intervenes

---

**Last Updated**: October 19, 2025

