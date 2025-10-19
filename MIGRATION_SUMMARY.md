# Migration Summary - SPRINT 7 Architecture

## Status: ✅ ALL 33 MIGRATIONS CREATED

**Date**: October 18, 2024  
**Architecture**: Activity-type separation with flexible template system  
**Documentation**: See SPRINT-7.md for complete architecture design

---

## Migration Organization

### **Foundation Layer (00-04): 5 migrations**
```
00_extensions.sql     - PostgreSQL extensions, utility functions
01_users.sql          - User accounts, preferences, auth helper
02_wallet.sql         - Wallet balances, transactions, token functions (consolidated)
03_papers.sql         - Papers, contributors, versions
04_storage.sql        - File storage, buckets
```

### **Activity System Core (10-13): 4 migrations**
```
10_activity_system_core.sql    - Activity/stage/condition registries, template tables
11_activity_stage_state.sql    - Runtime stage tracking (polymorphic)
12_condition_evaluators.sql    - AND/OR/NOT expression evaluator + all conditions
13_progression_engine.sql      - Generic progression engine + transition executor
```

### **PR Activity Domain (20-29): 10 migrations**
```
20_pr_activities.sql                    - pr_activities, pr_templates (user_facing_name), pr_template_ranks
21_pr_reviewers.sql                     - pr_reviewers (lock-in mechanism), pr_activity_permissions
22_pr_review_submissions.sql            - pr_review_submissions
23_pr_author_responses.sql              - pr_author_responses
24_pr_assessments.sql                   - pr_assessments, pr_finalization_status (Etherpad)
25_pr_awards.sql                        - pr_award_distributions, pr_reviewer_rankings
26_pr_timeline.sql                      - pr_timeline_events
27_pr_template_quick_review_v1.sql      - Template: "Quick Review" (4+3+2 tokens + 1 insurance)
28_pr_template_thorough_review_v1.sql   - Template: "Thorough Review" (7+5+4+2 tokens + 2 insurance)
29_pr_publication_choices.sql           - pr_publication_choices (published_on_ps focus)
```

### **JC Activity Domain (40-47): 8 migrations**
```
40_jc_activities.sql                - jc_activities, jc_templates, jc_invitations
41_jc_reviewers.sql                 - jc_participants (creator can participate), jc_activity_permissions
42_jc_review_submissions.sql        - jc_review_submissions
43_jc_assessments.sql               - jc_assessments, jc_finalization_status
44_jc_awards.sql                    - jc_award_distributions, jc_award_distribution_status
45_jc_timeline.sql                  - jc_timeline_events
46_jc_workflow.sql                  - JC helper functions
47_jc_template_standard_v1.sql      - Template: jc_standard_v1
```

### **Platform Features (50-53): 4 migrations**
```
50_notifications.sql        - user_notifications (cross-activity)
51_feed.sql                 - Feed optimization indexes + helper functions
52_library.sql              - Library tables (placeholder)
53_library_publishing.sql   - Library publishing (placeholder)
```

### **Admin & Monitoring (70-71): 2 migrations**
```
70_admin_views.sql      - Admin dashboard views, user activity summary
71_audit_logs.sql       - Security audit logs, processing logs, state logs
```

---

## Key Architecture Changes

### **✅ Activity Type Separation**
- `pr_activities` and `jc_activities` (separate tables)
- No more `activity_type` discriminator column
- Each type has its own timeline, reviewers, permissions tables
- Both use template system (JC has simpler templates with manual progression)

### **✅ Explicit Stage Types**
- PR: `posted`, `review_round_1`, `review_round_2`, `review_round_3`, `author_response_round_1`, `author_response_round_2`, `collaborative_assessment`, `award_distribution`, `publication_choice`
- JC: `jc_review`, `jc_assessment`, `jc_awarding`
- DB is source of truth, React components follow
- **Posted stage**: PR activities start "posted" on feed, seeking reviewers

### **✅ Flexible Template System**
- `template_stage_graph` (workflow nodes)
- `template_stage_transitions` (workflow edges with condition expressions)
- AND/OR/NOT condition logic support
- Templates are data, not code

### **✅ Generic Progression Engine**
- `check_and_progress_activity()` works for all activity types
- `eval_condition_expression()` recursive evaluator
- Pluggable condition evaluators

### **✅ Clean Separation**
- PR domain: migrations 20-39
- JC domain: migrations 40-59
- Each domain is a complete vertical slice

---

## Migration File Count by Domain

| Domain | Migrations | Tables Created |
|--------|-----------|----------------|
| Foundation | 5 | ~8 tables |
| Activity Core | 4 | 5 tables |
| PR Domain | 10 | ~16 tables |
| JC Domain | 8 | ~11 tables |
| Platform | 4 | ~2 tables + views |
| Admin | 2 | ~3 tables + views |
| **TOTAL** | **33** | **~45 tables** |

---

## Next Steps

1. **Test Migrations**
   ```bash
   cd ps-database
   ./scripts/dev-workflow.sh reset
   ```

2. **Verify Schema**
   - Check all tables created
   - Verify foreign keys
   - Test RLS policies

3. **Generate Types**
   ```bash
   cd paperstack
   npm run type-check
   ```

4. **Update Mock Data**
   - Update `complete-mock-setup.ts`
   - Use new table names (pr_activities, jc_activities)
   - Test activity creation

5. **Update Application Code**
   - Update imports
   - Fix type errors
   - Update API routes

---

## Backup Location

Old migrations backed up to:
```
ps-database/supabase/backup_migrations/
```

27 old migration files preserved for reference.

---

## Template Naming Convention

**Internal Names** (in database):
- `quick_review_1_round_3_reviewers_10_tokens_v1`
- `thorough_review_2_rounds_4_reviewers_20_tokens_v1`

**User-Facing Display** (extracted from name):
- "Quick Review (v1)"
- "Thorough Review (v1)"

**Adding New Templates**:
- PR templates: Create migration like `00000000000029_pr_template_{name}_v1.sql`
- JC templates: Create migration like `00000000000048_jc_template_{name}_v1.sql`
- Follow pattern from migrations 27-28 (PR) or 47 (JC)
- Just INSERT data (no schema changes)

**Reviewer Lock-In Mechanism (PR Activities Only)**:
- Reviewers join during "posted" stage
- First review submission automatically sets status to `locked_in`
- Activity auto-progresses to `review_1` as soon as FIRST review submitted
- Locked-in reviewers cannot leave (penalties for missing deadlines in future)
- Authors can cancel if zero reviews submitted

**Token Distribution (Top-Heavy Approach)**:
- 10% reserved for insurance (conflict resolution, platform services)
- Remaining distributed by rank with diminishing returns
- Quick Review (3 reviewers, 10 tokens): 4, 3, 2 tokens + 1 insurance
- Thorough Review (4 reviewers, 20 tokens): 7, 5, 4, 2 tokens + 2 insurance
- Insurance tokens sent to super admin pool

**Template Display Names**:
- Templates have `user_facing_name` for UI display
- Example: internal `quick_review_1_round_3_reviewers_10_tokens_v1` → display "Quick Review"
- Manual control in frontend which templates shown to users

**JC vs PR Distinctions**:
- JC uses `jc_participants` table (NOT `jc_reviewers`) - more accurate naming
- JC creator CAN participate and submit reviews (tracked with `is_creator = true`)
- JC has NO lock-in mechanism (free to join/leave, though leave not yet implemented)
- JC uses same award structure with tokens=0 (recognition/ranking only)
- JC has template system like PR, but all transitions are manual

**Future Admin Functionality** (NOT YET IMPLEMENTED):
- Transition_order field reserved for multiple exit paths (paused, cancelled, flagged states)
- Deadline enforcement with penalties (deadline_reached condition exists but unused)
- Reviewer removal after timeout (pr_reviewers has removed status but no background job)
- Activity cancellation/suspension (no cancelled_at field yet)

---

## Architectural Principles Followed

✅ **DB is Source of Truth** (DEVELOPMENT_PRINCIPLES.md)  
✅ **Clean boundaries** (activity types are first-class)  
✅ **Predictable workflows** (no cycles, no branching)  
✅ **Copy-paste over complexity** (explicit stage types)  
✅ **One concern per file** (findability)  
✅ **Logical dependencies** (Foundation → Core → Domains → Features)

