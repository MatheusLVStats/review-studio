-- NOT APPLIED YET (2026-11-11). Waiting for the project owner to approve the change in the Supabase connector.
-- When applied, move this file to supabase/migrations/ with its version prefix.
--
-- To add to the same migration before applying:
--  (b) in rs.dedup_compute, CTE "keyed": also return k = null when
--        'title' = any(v_f) and not ('doi' = any(v_f)) and length(r.norm_title) < 25
--      so a short generic title ("Editorial", "Reply") is never matched by the chosen-fields rule alone;
--  (c) in public.rs_dedup_apply: after the merges, set status = 'merged' on open rs.dedup_queue pairs whose two
--      records now point to the same kept record;
--  (d) in public.rs_dedup_status: also return 'approved_policy' (latest approved) next to 'policy' (latest of any status).
--
-- Self-test for the chosen-fields duplicate rules. Synthetic users and data in a sub-transaction that is rolled back.
create or replace function rs.selftest_dedup_rules() returns jsonb language plpgsql set search_path = '' as $$
declare res jsonb := '[]'; v_err text; v_ctx text; v_last bigint; v_called boolean;
  m uuid := gen_random_uuid(); c uuid := gen_random_uuid(); rv uuid; rv2 uuid; j jsonb; t jsonb; sp bigint; se bigint; s2 bigint; run bigint; x text; h jsonb;
begin
  select last_value, is_called into v_last, v_called from rs.review_code_seq;
  begin
    perform set_config('rs.infra_override', 'on', true);
    insert into auth.users (id, email, aud, role) values (m, 'selftest-moderator@synthetic.invalid', 'authenticated', 'authenticated'),
      (c, 'selftest-outsider@synthetic.invalid', 'authenticated', 'authenticated');
    update rs.workspace set principal_moderator = m, confirmation_channel = 'app_or_browser';
    perform set_config('rs.infra_override', 'off', true);
    perform rs.t_as(m);
    h := jsonb_build_object('protocol', jsonb_build_object('label', 'v1.0', 'source_ref', 'synthetic', 'content', jsonb_build_object('question', 'SYNTHETIC')),
      'criteria', jsonb_build_array(jsonb_build_object('code', 'I1', 'kind', 'include', 'text', 'Adults')),
      'reasons', jsonb_build_array(jsonb_build_object('label', 'Wrong population', 'criterion_code', 'I1')),
      'registration', jsonb_build_object('status', 'submitted', 'registry', 'PROSPERO', 'submitted_on', '2026-10-21'),
      'sources', jsonb_build_array(jsonb_build_object('preset', 'pubmed', 'database_name', 'MEDLINE'), jsonb_build_object('preset', 'embase', 'database_name', 'Embase')));
    j := public.rs_create_review_draft('SYNTHETIC review rules', h, true); rv := (j ->> 'review_id')::uuid;
    perform rs.t_confirm(public.rs_propose_activation(rv));
    j := public.rs_create_review_draft('SYNTHETIC review rules two', h, true); rv2 := (j ->> 'review_id')::uuid;
    perform rs.t_confirm(public.rs_propose_activation(rv2));
    select id into sp from rs.sources where review_id = rv and preset = 'pubmed'; select id into se from rs.sources where review_id = rv and preset = 'embase';
    select id into s2 from rs.sources where review_id = rv2 and preset = 'embase';
    perform rs.t_import(rv, sp, repeat('a', 64), 'pubmed', jsonb_build_array(
      rs.t_row(1, 'P1', 'Synthetic alpha trial of block onset time in adults', null, null, 2020, 'Silva, A', 'JOUR', 'Synthetic abstract that only the MEDLINE version carries.'),
      rs.t_row(2, 'P2', 'Synthetic beta trial of sedation depth during surgery', null, null, 2021, 'Costa, B'),
      rs.t_row(3, 'P3', 'Synthetic gamma cohort of flap survival after surgery', null, null, 2019, 'Lima, C')));
    perform rs.t_import(rv, se, repeat('b', 64), 'embase', jsonb_build_array(
      rs.t_row(1, 'E1', 'Synthetic alpha trial of block onset time in adults', null, null, 2020, 'Silva, A'),
      rs.t_row(2, 'E2', 'Synthetic beta trial of sedation depth during surgery', null, null, 2023, 'Costa, B'),
      rs.t_row(3, 'E3', 'Synthetic gamma cohort of flap survival after surgery', null, null, 2019, 'Souza, D')));

    res := res || rs.t_r('R01 fields without Title or DOI are refused', rs.t_fail(format('select public.rs_propose_dedup_rules(%L, %L::jsonb)', rv, '{"match_fields":["year","journal"]}')) = 'title_or_doi_required');
    res := res || rs.t_r('R02 an unknown field is refused', rs.t_fail(format('select public.rs_propose_dedup_rules(%L, %L::jsonb)', rv, '{"match_fields":["title","abstract"]}')) = 'bad_field');
    res := res || rs.t_r('R03 no rule at all is refused', rs.t_fail(format('select public.rs_propose_dedup_rules(%L, %L::jsonb)', rv, '{"match_fields":[],"identifier_rules":false}')) = 'no_rule');
    res := res || rs.t_r('R04 a database from another review cannot be the version to keep',
      rs.t_fail(format('select public.rs_propose_dedup_rules(%L, %L::jsonb)', rv, jsonb_build_object('match_fields', jsonb_build_array('title'), 'keep_source_id', s2))) = 'not_found');
    perform rs.t_as(c);
    x := rs.t_fail(format('select public.rs_propose_dedup_rules(%L, %L::jsonb)', rv, '{"match_fields":["title"]}'));
    res := res || rs.t_r('R05 a person outside the review cannot set rules', x = 'forbidden', x);
    perform rs.t_as(m);

    j := public.rs_propose_dedup_rules(rv, '{"match_fields":["title","pages"]}');
    res := res || rs.t_r('R06 saved rules do nothing until the moderator approves them', j ->> 'status' = 'awaiting_moderator_approval' and rs.t_fail(format('select public.rs_dedup_dry_run(%L)', rv)) = 'no_approved_policy');
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    j := public.rs_dedup_dry_run(rv);
    res := res || rs.t_r('R07 a record that lacks a chosen field (pages) is never matched on it; the pairs go to a person',
      (j ->> 'records_to_remove')::int = 0 and j -> 'pairs_for_human_review' = '{"title_match_no_shared_identifier":2,"year_mismatch":1}'::jsonb, (j - 'sample_clusters')::text);

    j := public.rs_propose_dedup_rules(rv, jsonb_build_object('match_fields', jsonb_build_array('title', 'year', 'authors'), 'keep_source_id', se));
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    j := public.rs_dedup_dry_run(rv); run := (j ->> 'run_id')::bigint;
    res := res || rs.t_r('R08 title + year + authors: only the pair where all three match is removed',
      (j ->> 'clusters')::int = 1 and (j ->> 'records_to_remove')::int = 1 and j -> 'pairs_for_human_review' = '{"title_match_no_shared_identifier":1,"year_mismatch":1}'::jsonb, (j - 'sample_clusters')::text);
    res := res || rs.t_r('R09 the version from the chosen database is kept, even when the other one has the abstract',
      (select d.role from rs.dedup_proposals d where d.run_id = run and d.record_id = rs.t_rec(rv, 'E1')) = 'keep'
      and (select d.role from rs.dedup_proposals d where d.run_id = run and d.record_id = rs.t_rec(rv, 'P1')) = 'merge');
    j := public.rs_dedup_apply(run);
    res := res || rs.t_r('R10 applying removes exactly one record, reversibly, and keeps both source entries',
      (j ->> 'removed_now')::int = 1 and (select merged_into from rs.records where id = rs.t_rec(rv, 'P1')) = rs.t_rec(rv, 'E1')
      and (select count(*) from rs.source_occurrences where review_id = rv) = 6, j::text);

    j := public.rs_propose_dedup_rules(rv, '{"match_fields":["title"]}');
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    j := public.rs_dedup_dry_run(rv); run := (j ->> 'run_id')::bigint;
    res := res || rs.t_r('R11 title only: the same-year pair is removed; the pair two years apart still goes to a person',
      (j ->> 'records_to_remove')::int = 1
      and exists (select 1 from rs.dedup_proposals d where d.run_id = run and d.record_id = rs.t_rec(rv, 'E3'))
      and not exists (select 1 from rs.dedup_proposals d where d.run_id = run and d.record_id in (rs.t_rec(rv, 'P2'), rs.t_rec(rv, 'E2'))), (j - 'sample_clusters')::text);

    raise exception using errcode = 'RSTST', message = 'done';
  exception
    when sqlstate 'RSTST' then v_err := null;
    when others then get stacked diagnostics v_err = message_text, v_ctx = pg_exception_context;
  end;
  perform setval('rs.review_code_seq', v_last, v_called);
  perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  return jsonb_build_object('total_run', jsonb_array_length(res),
    'passed', (select count(*) from jsonb_array_elements(res) e where (e ->> 'ok')::boolean),
    'failed', (select coalesce(jsonb_agg(e), '[]') from jsonb_array_elements(res) e where not (e ->> 'ok')::boolean),
    'stopped_by_error', v_err, 'error_context', left(v_ctx, 600),
    'left_no_data_behind', not exists (select 1 from auth.users where email like 'selftest-%@synthetic.invalid') and not exists (select 1 from rs.reviews where title like 'SYNTHETIC review%'));
end $$;
revoke all on function rs.selftest_dedup_rules() from public, anon, authenticated;
