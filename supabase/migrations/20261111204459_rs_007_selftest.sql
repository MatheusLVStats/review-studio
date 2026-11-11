-- Self-test: builds clearly synthetic users and reviews inside a sub-transaction, checks behaviour, then rolls everything back.
create function rs.t_as(p_uid uuid, p_client text default null) returns void language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true); return;
  end if;
  v := jsonb_build_object('sub', p_uid, 'role', 'authenticated');
  if p_client is not null then v := v || jsonb_build_object('client_id', p_client); end if;
  perform set_config('request.jwt.claims', v::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;

create function rs.t_fail(p_sql text) returns text language plpgsql set search_path = '' as $$
declare v_detail text; v_state text;
begin
  begin execute p_sql;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail, v_state = returned_sqlstate;
    return coalesce(nullif(v_detail, ''), v_state);
  end;
  return 'NO_ERROR';
end $$;

create function rs.t_fail_as(p_role text, p_sql text) returns text language plpgsql set search_path = '' as $$
declare v_detail text; v_state text; v_res text := 'NO_ERROR';
begin
  execute format('set local role %I', p_role);
  begin execute p_sql;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail, v_state = returned_sqlstate;
    v_res := coalesce(nullif(v_detail, ''), v_state);
  end;
  execute 'reset role';
  return v_res;
end $$;

create function rs.t_confirm(p jsonb) returns jsonb language sql set search_path = '' as $$
  select public.rs_confirm((p ->> 'confirmation_id')::uuid, p ->> 'payload_hash')
$$;
create function rs.t_vote(p_review uuid, p_record bigint, p_stage text, p_decision text, p_primary bigint default null) returns jsonb language sql set search_path = '' as $$
  select rs.t_confirm(public.rs_propose_vote(p_review, p_record, p_stage, p_decision, '{}', p_primary, null))
$$;
create function rs.t_row(i int, src text, title text, doi text, pmid text, yr int, author text, ref text default 'JOUR', abstract text default null) returns jsonb language sql set search_path = '' as $$
  select jsonb_build_object('row_no', i, 'status', 'accepted', 'raw', 'synthetic', 'parsed', jsonb_build_object('src_record_id', src, 'title', title, 'doi', doi, 'pmid', pmid,
    'year', yr::text, 'authors', jsonb_build_array(author), 'ref_type', ref, 'abstract', abstract, 'journal', 'Synthetic Journal'))
$$;
create function rs.t_rec(p_review uuid, p_src text) returns bigint language sql set search_path = '' as $$
  select o.record_id from rs.source_occurrences o where o.review_id = p_review and o.src_record_id = p_src and not o.is_export_overlap order by o.id limit 1
$$;
create function rs.t_r(p_name text, p_ok boolean, p_got text default null) returns jsonb language sql set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('test', p_name, 'ok', coalesce(p_ok, false), 'got', p_got))
$$;
create function rs.t_import(p_review uuid, p_source bigint, p_sha text, p_preset text, p_rows jsonb, p_ack boolean default false) returns jsonb language plpgsql set search_path = '' as $$
declare j jsonb; bt bigint;
begin
  j := public.rs_import_begin(p_review, jsonb_build_object('filename', 'synthetic-' || p_preset || '.ris', 'sha256', p_sha, 'byte_size', 100, 'format', 'ris', 'parser_version', 'selftest', 'suggestion', jsonb_build_object('preset', p_preset)));
  if j ->> 'status' = 'duplicate_file' then return j; end if;
  bt := (j ->> 'batch_id')::bigint;
  perform public.rs_import_add_rows(bt, p_rows);
  perform public.rs_import_preview(bt);
  return public.rs_import_commit(bt, p_source, null, false, p_ack);
end $$;

create function rs.selftest() returns jsonb language plpgsql set search_path = '' as $$
declare res jsonb := '[]'; v_out text; v_err text; v_ctx text; v_last bigint; v_called boolean;
  m uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  rv uuid; rv2 uuid; j jsonb; t jsonb; tok text; ap bigint; sp bigint; se bigint; sc bigint; run bigint; ev bigint; q bigint;
  crit bigint; pcrit bigint; lab1 bigint; lab2 bigint; x text; n int;
  p2 bigint; p4 bigint; p6 bigint; p7 bigint; p8 bigint; e7 bigint; h jsonb;
begin
  select last_value, is_called into v_last, v_called from rs.review_code_seq;
  begin
    perform set_config('rs.infra_override', 'on', true);
    insert into auth.users (id, email, aud, role) values (m, 'selftest-moderator@synthetic.invalid', 'authenticated', 'authenticated'),
      (a, 'selftest-reviewer-a@synthetic.invalid', 'authenticated', 'authenticated'), (b, 'selftest-reviewer-b@synthetic.invalid', 'authenticated', 'authenticated'),
      (c, 'selftest-outsider@synthetic.invalid', 'authenticated', 'authenticated');
    update rs.workspace set principal_moderator = m, confirmation_channel = 'app_or_browser';
    perform set_config('rs.infra_override', 'off', true);

    -- 1 authentication and direct access
    perform rs.t_as(null);
    res := res || rs.t_r('01 unauthenticated call is refused', rs.t_fail('select public.rs_whoami()') = 'not_authenticated');
    perform rs.t_as(a);
    x := rs.t_fail_as('authenticated', 'select count(*) from rs.reviews');
    res := res || rs.t_r('02 signed-in user cannot read tables directly', x = '42501', x);
    x := rs.t_fail_as('anon', 'select public.rs_whoami()');
    res := res || rs.t_r('03 anonymous role cannot call the API', x = '42501', x);
    x := rs.t_fail_as('authenticated', 'select rs.apply_vote(''{}''::jsonb, null, null)');
    res := res || rs.t_r('04 internal save-vote function is unreachable from the API role', x = '42501', x);

    -- 2 review draft, registration honesty, activation by confirmation
    h := jsonb_build_object('protocol', jsonb_build_object('label', 'v1.0', 'source_ref', 'synthetic', 'content', jsonb_build_object('question', 'SYNTHETIC')),
      'criteria', jsonb_build_array(jsonb_build_object('code', 'I1', 'kind', 'include', 'text', 'Adults having an ophthalmic regional block'), jsonb_build_object('code', 'E1', 'kind', 'exclude', 'text', 'Hyaluronidase in all arms')),
      'reasons', jsonb_build_array(jsonb_build_object('label', 'Hyaluronidase in all arms', 'criterion_code', 'E1'), jsonb_build_object('label', 'Wrong population', 'criterion_code', 'I1')),
      'registration', jsonb_build_object('status', 'submitted', 'registry', 'PROSPERO', 'submitted_on', '2026-10-21'),
      'sources', jsonb_build_array(jsonb_build_object('preset', 'pubmed', 'database_name', 'MEDLINE'), jsonb_build_object('preset', 'embase', 'database_name', 'Embase'), jsonb_build_object('preset', 'central', 'database_name', 'CENTRAL')));
    res := res || rs.t_r('05 a member cannot create a review', rs.t_fail(format('select public.rs_create_review_draft(''X'', %L::jsonb, true)', h)) = 'moderator_only');
    perform rs.t_as(m);
    res := res || rs.t_r('06 registration cannot be recorded as confirmed without ID, date and evidence',
      rs.t_fail(format('select public.rs_create_review_draft(''X'', %L::jsonb, true)', h || jsonb_build_object('registration', jsonb_build_object('status', 'confirmed')))) = 'registration_evidence_required');
    j := public.rs_create_review_draft('SYNTHETIC review one', h, true); rv := (j ->> 'review_id')::uuid;
    j := public.rs_create_review_draft('SYNTHETIC review two', h, true); rv2 := (j ->> 'review_id')::uuid;
    res := res || rs.t_r('07 draft is not active and registration stays "submitted"', j ->> 'status' = 'draft' and j -> 'registration' ->> 'status' = 'submitted');
    t := public.rs_propose_activation(rv);
    res := res || rs.t_r('08 preparing activation saves nothing', (select status from rs.reviews where id = rv) = 'draft' and t ->> 'saved' = 'false');
    perform rs.t_as(a);
    res := res || rs.t_r('09 another person cannot confirm the moderator''s request', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash')) = 'confirmation_not_found');
    perform rs.t_as(m);
    res := res || rs.t_r('10 a confirmation with different content is refused', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', 'deadbeef')) = 'payload_mismatch');
    j := rs.t_confirm(t);
    res := res || rs.t_r('11 confirmed activation makes the review active with labels', (select status from rs.reviews where id = rv) = 'active' and (j -> 'result' ->> 'reason_labels_created')::int = 2);
    j := rs.t_confirm(t);
    res := res || rs.t_r('12 repeating the same confirmation does not run twice', j ->> 'replayed' = 'true');
    perform rs.t_confirm(public.rs_propose_activation(rv2));
    select id into crit from rs.criteria where review_id = rv and code = 'E1';
    select id into lab1 from rs.reason_labels where review_id = rv and norm_label = 'hyaluronidase in all arms';
    select id into lab2 from rs.reason_labels where review_id = rv and norm_label = 'wrong population';

    -- 3 invitations, membership, rights
    perform rs.t_as(a);
    res := res || rs.t_r('13 a non-member is denied (same error as an unknown review)', rs.t_fail(format('select public.rs_get_review(%L)', rv)) = 'forbidden' and rs.t_fail(format('select public.rs_get_review(%L)', gen_random_uuid())) = 'forbidden');
    perform rs.t_as(m);
    j := rs.t_confirm(public.rs_propose_invitation(rv, 'selftest-reviewer-a@synthetic.invalid', array['screen_ta','screen_ft']));
    tok := j -> 'result' ->> 'invite_token';
    res := res || rs.t_r('14 the one-time invitation code is not kept in readable form', not exists (select 1 from rs.confirmations where result::text like '%' || tok || '%') and not exists (select 1 from rs.invitations where token_hash = tok));
    perform rs.t_as(a);
    j := public.rs_redeem_invitation(tok); ap := (j ->> 'approval_id')::bigint;
    res := res || rs.t_r('15 accepting an invitation gives no access before moderator approval', rs.t_fail(format('select public.rs_get_review(%L)', rv)) = 'forbidden');
    res := res || rs.t_r('16 a member cannot approve their own membership', rs.t_fail(format('select public.rs_propose_approval_decision(%s, ''approve'')', ap)) = 'moderator_only');
    perform rs.t_as(c);
    res := res || rs.t_r('17 a used invitation code cannot be reused by someone else', rs.t_fail(format('select public.rs_redeem_invitation(%L)', tok)) = 'invitation_invalid');
    perform rs.t_as(m);
    perform rs.t_confirm(public.rs_propose_approval_decision(ap, 'approve'));
    j := rs.t_confirm(public.rs_propose_invitation(rv, 'selftest-reviewer-b@synthetic.invalid', array['screen_ta','screen_ft']));
    perform rs.t_as(b);
    j := public.rs_redeem_invitation(j -> 'result' ->> 'invite_token');
    perform rs.t_as(m);
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    perform rs.t_as(a);
    j := public.rs_get_review(rv);
    res := res || rs.t_r('18 approved member has exactly the granted rights', j -> 'your_capabilities' = '["screen_ft","screen_ta"]'::jsonb and j ->> 'your_role' = 'member', j ->> 'your_capabilities');
    res := res || rs.t_r('19 a member cannot change rights', rs.t_fail(format('select public.rs_propose_grant_change(%L, %L, array[''import''], ''{}'')', rv, a)) = 'moderator_only');
    res := res || rs.t_r('20 a member cannot import', rs.t_fail(format('select public.rs_import_begin(%L, ''{"sha256":"%s"}'')', rv, repeat('f', 64))) = 'capability_required');
    perform rs.t_as(m);
    res := res || rs.t_r('21 the moderator cannot be removed', rs.t_fail(format('select public.rs_propose_grant_change(%L, %L, ''{}'', ''{}'', true)', rv, m)) = 'moderator_protected');
    res := res || rs.t_r('22 the principal moderator cannot be replaced by an update', rs.t_fail(format('update rs.workspace set principal_moderator = %L', a)) = '42501');

    -- 4 criteria and labels
    perform rs.t_as(a);
    j := public.rs_propose_criterion(rv, 'exclude', 'both', 'Sample size under 20 (SYNTHETIC new rule)'); pcrit := (j ->> 'criterion_id')::bigint;
    res := res || rs.t_r('23 a new criterion stays inactive until the moderator activates it', j ->> 'status' = 'proposed_inactive' and (select status from rs.criteria where id = pcrit) = 'proposed');
    res := res || rs.t_r('24 a reason label cannot point to an inactive (novel) criterion', rs.t_fail(format('select public.rs_create_reason_label(%L, ''ta'', ''Too small'', %s)', rv, pcrit)) = 'criterion_not_active');
    j := public.rs_create_reason_label(rv, 'both', '  hyaluronidase IN all arms ', crit);
    res := res || rs.t_r('25 an equivalent label reuses the existing reason code', j ->> 'status' = 'reused_existing' and (j ->> 'reason_id')::bigint = lab1);

    -- 5 imports, provenance, duplicates
    perform rs.t_as(m);
    select id into sp from rs.sources where review_id = rv and preset = 'pubmed'; select id into se from rs.sources where review_id = rv and preset = 'embase'; select id into sc from rs.sources where review_id = rv and preset = 'central';
    j := rs.t_import(rv, sp, repeat('a', 64), 'pubmed', jsonb_build_array(
      rs.t_row(1, 'P1', 'Synthetic alpha hyaluronidase peribulbar block trial', '10.1000/a1', '111', 2020, 'Silva, A', 'JOUR', 'Synthetic abstract: adults received hyaluronidase in both arms.'),
      rs.t_row(2, 'P2', 'Synthetic beta sub tenon block onset time trial', '10.1000/a2', '112', 2019, 'Costa, B'),
      rs.t_row(3, 'P3', 'Synthetic gamma retrobulbar akinesia score trial', null, '113', 2018, 'Lima, C'),
      rs.t_row(4, 'P4', 'Synthetic delta ocular block dose comparison trial', '10.1000/a4', '114', 2021, 'Rocha, D'),
      rs.t_row(5, 'P5', 'Erratum: Synthetic epsilon block quality report', '10.1000/a5', null, 2021, 'Nunes, E'),
      rs.t_row(6, 'P6', 'Synthetic zeta regional eye anaesthesia cohort', '10.1000/a6', '116', 2017, 'Souza, F'),
      rs.t_row(7, 'P7', 'Synthetic eta lid akinesia after peribulbar injection', null, null, 2016, 'Melo, G'),
      rs.t_row(8, 'P8', 'Synthetic theta globe akinesia onset randomized study', '10.1000/a8', null, 2015, 'Dias, H')));
    res := res || rs.t_r('26 import commits 8 new records with a suggested (not verified) origin', (j ->> 'new_records')::int = 8 and j ->> 'origin_status' = 'suggested', j::text);
    j := rs.t_import(rv, sp, repeat('a', 64), 'pubmed', '[]');
    res := res || rs.t_r('27 the same file again is recognised and adds nothing', j ->> 'status' = 'duplicate_file' and (select count(*) from rs.records where review_id = rv) = 8);
    j := public.rs_import_begin(rv, jsonb_build_object('filename', 'x.ris', 'sha256', repeat('9', 64), 'suggestion', jsonb_build_object('preset', 'scopus')));
    perform public.rs_import_add_rows((j ->> 'batch_id')::bigint, jsonb_build_array(rs.t_row(1, 'S1', 'Synthetic scopus only record for origin conflict check', null, null, 2014, 'Zed, Z')));
    res := res || rs.t_r('28 a file that looks like another database needs explicit origin confirmation', rs.t_fail(format('select public.rs_import_commit(%s, %s)', j ->> 'batch_id', se)) = 'origin_conflict');
    perform public.rs_import_discard((j ->> 'batch_id')::bigint);
    perform rs.t_import(rv, se, repeat('b', 64), 'embase', jsonb_build_array(
      rs.t_row(1, 'E1', 'Synthetic alpha hyaluronidase peribulbar block trial', 'https://doi.org/10.1000/A1', null, 2020, 'Silva, A'),
      rs.t_row(2, 'E2', 'Completely different synthetic paper about the cornea', '10.1000/a2', null, 2019, 'Other, Z'),
      rs.t_row(3, 'E3', 'Synthetic gamma retrobulbar akinesia score trial', null, '113', 2018, 'Lima, C'),
      rs.t_row(4, 'E4', 'Synthetic delta ocular block dose comparison trial', '10.1000/a4', '999', 2021, 'Rocha, D'),
      rs.t_row(5, 'E5', 'Synthetic epsilon block quality report', '10.1000/a5', null, 2021, 'Nunes, E'),
      rs.t_row(6, 'E6', 'Synthetic zeta regional eye anaesthesia cohort', '10.1000/a6', null, 2017, 'Souza, F', 'CONF'),
      rs.t_row(7, 'E7', 'Synthetic eta lid akinesia after peribulbar injection', null, null, 2016, 'Melo, G')));
    perform rs.t_import(rv, sc, repeat('c', 64), 'central', jsonb_build_array(
      rs.t_row(1, 'C1', 'Synthetic alpha hyaluronidase peribulbar block trial', '10.1000/a1', null, 2020, 'Silva, A'),
      rs.t_row(2, 'C8', 'Synthetic theta globe akinesia onset randomized study', '10.1000/a8', null, 2015, 'Dias, H')));
    res := res || rs.t_r('29 duplicate handling refuses to run without an approved policy', rs.t_fail(format('select public.rs_dedup_dry_run(%L)', rv)) = 'no_approved_policy');
    j := public.rs_propose_dedup_policy(rv, false);
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    j := public.rs_dedup_dry_run(rv); run := (j ->> 'run_id')::bigint;
    select coalesce(sum(value::int), 0) into n from jsonb_each_text(j -> 'pairs_for_human_review');
    res := res || rs.t_r('30 dry run proposes 3 clusters / 4 removals / 5 pairs for review and changes nothing',
      (j ->> 'clusters')::int = 3 and (j ->> 'records_to_remove')::int = 4 and n = 5 and (select count(*) from rs.records where review_id = rv and merged_into is not null) = 0, (j - 'sample_clusters')::text);
    res := res || rs.t_r('31 uncertain pairs are classified, not merged', j -> 'pairs_for_human_review' = '{"conference_vs_full_report":1,"conflicting_identifiers":1,"correction_retraction_or_comment":1,"identifier_without_corroboration":1,"title_match_no_shared_identifier":1}'::jsonb, (j -> 'pairs_for_human_review')::text);
    j := public.rs_dedup_apply(run);
    res := res || rs.t_r('32 applying removes k-1 per cluster (4) and keeps raw source entries', (j ->> 'removed_now')::int = 4 and (select count(*) from rs.source_occurrences where review_id = rv) = 17, j::text);
    j := public.rs_dedup_apply(run);
    res := res || rs.t_r('33 applying the same run again counts nothing twice', j ->> 'status' = 'already_applied' and (select count(*) from rs.records where review_id = rv and merged_into is not null) = 4);
    j := public.rs_dedup_dry_run(rv);
    res := res || rs.t_r('34 a fresh run finds nothing more to remove', (j ->> 'records_to_remove')::int = 0, (j - 'sample_clusters')::text);
    res := res || rs.t_r('35 a record found in three databases keeps all three source histories',
      (select jsonb_array_length(public.rs_get_record(rv, rs.t_rec(rv, 'P1'), 'ta') -> 'sources')) = 3);
    select id into ev from rs.dedup_events where review_id = rv and merged_record_id = rs.t_rec(rv, 'C8');
    perform public.rs_dedup_undo(ev);
    j := public.rs_dedup_dry_run(rv);
    res := res || rs.t_r('36 undo restores the record and automation does not merge it again',
      (select merged_into is null from rs.records where id = rs.t_rec(rv, 'C8')) and (j ->> 'records_to_remove')::int = 0, (j - 'sample_clusters')::text);
    res := res || rs.t_r('37 overlapping export chunks must be reconciled explicitly',
      rs.t_fail(format('select rs.t_import(%L, %s, %L, ''pubmed'', %L::jsonb)', rv, sp, repeat('d', 64), jsonb_build_array(rs.t_row(1, 'P1', 'x', null, null, 2020, 'S'), rs.t_row(2, 'P9', 'Synthetic iota new record from second export chunk', null, null, 2022, 'Nine, N')))) = 'overlap_needs_reconciliation');
    j := rs.t_import(rv, sp, repeat('d', 64), 'pubmed', jsonb_build_array(rs.t_row(1, 'P1', 'x', null, null, 2020, 'S'), rs.t_row(2, 'P9', 'Synthetic iota new record from second export chunk', null, null, 2022, 'Nine, N')), true);
    res := res || rs.t_r('38 overlap rows link to existing records and are not counted as duplicates removed', (j ->> 'new_records')::int = 1 and (j ->> 'export_overlaps_linked')::int = 1, j::text);
    j := public.rs_prisma(rv);
    res := res || rs.t_r('39 ledger: 18 identified - 3 duplicates = 15 screened, all checks pass',
      (j -> 'identification' ->> 'records_identified_total')::int = 18 and (j -> 'identification' -> 'duplicates_removed' ->> 'total')::int = 3 and (j -> 'screening' ->> 'records_screened')::int = 15
      and not exists (select 1 from jsonb_array_elements(j -> 'validation') v where (v ->> 'ok')::boolean is not true), (j -> 'validation')::text);

    -- 6 votes, confirmation, blinding
    p2 := rs.t_rec(rv, 'P2'); p4 := rs.t_rec(rv, 'P4'); p6 := rs.t_rec(rv, 'P6'); p7 := rs.t_rec(rv, 'P7'); p8 := rs.t_rec(rv, 'P8'); e7 := rs.t_rec(rv, 'E7');
    perform rs.t_as(a, 'claude-synthetic-client');
    t := public.rs_propose_vote(rv, p7, 'ta', 'exclude', '{}', lab1, null);
    res := res || rs.t_r('40 a vote prepared through the model saves nothing by itself', (select count(*) from rs.votes where review_id = rv) = 0 and t ->> 'status' = 'awaiting_human_confirmation');
    perform rs.t_as(b);
    res := res || rs.t_r('41 a colleague cannot confirm someone else''s vote', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash')) = 'confirmation_not_found');
    perform rs.t_as(a);
    j := rs.t_confirm(t);
    res := res || rs.t_r('42 the reviewer''s own confirmation saves the vote under their identity', (select count(*) from rs.votes where record_id = p7 and user_id = a and is_current and decision = 'exclude') = 1);
    perform public.rs_ai_annotate(rv, p7, 'ta', 'exclude', lab1, null, null, '[{"excerpt":"this sentence is not in the record","locator":"abstract"}]'::jsonb, 'synthetic', 'synthetic-model');
    perform rs.t_as(b);
    j := public.rs_get_record(rv, p7, 'ta');
    res := res || rs.t_r('43 blinding: peer vote, team status and peer AI notes are hidden before own vote',
      j -> 'peer_votes' ->> 'hidden' = 'true' and j -> 'team_status' = 'null'::jsonb and jsonb_array_length(j -> 'ai_annotations') = 0, j::text);
    j := public.rs_queue(rv, 'ta', 'all');
    res := res || rs.t_r('44 blinding: the queue carries no team status for a screener', not exists (select 1 from jsonb_array_elements(j -> 'items') i where i -> 'team_status' <> 'null'::jsonb));
    res := res || rs.t_r('45 blinding: team votes export is refused to a screener', rs.t_fail(format('select public.rs_export(%L, ''team_votes'')', rv)) = 'blinded');
    res := res || rs.t_r('46 blinding: activity log shows no vote events of others', not exists (select 1 from jsonb_array_elements(public.rs_audit(rv, 500) -> 'events') e where e ->> 'action' like 'vote%'));
    j := public.rs_overview(rv);
    res := res || rs.t_r('47 blinding: overview hides the decision split and conflict count from a screener', j -> 'stages' -> 'ta' -> 'final_team_dispositions' ? 'split_hidden' and j -> 'stages' -> 'ta' -> 'unresolved_conflicts' = 'null'::jsonb);
    res := res || rs.t_r('48 my-votes export contains only my own votes', (select (public.rs_export(rv, 'my_votes') -> 'manifest' ->> 'row_count')::int) = 0);
    perform rs.t_vote(rv, p7, 'ta', 'include');
    j := public.rs_get_record(rv, p7, 'ta');
    res := res || rs.t_r('49 blinding holds after both voted (conflict is not revealed to reviewers)', j -> 'peer_votes' ->> 'hidden' = 'true' and j -> 'team_status' = 'null'::jsonb);
    perform rs.t_as(a); perform rs.t_vote(rv, p2, 'ta', 'include'); perform rs.t_vote(rv, p4, 'ta', 'include'); perform rs.t_vote(rv, p6, 'ta', 'exclude', lab2); perform rs.t_vote(rv, p8, 'ta', 'include');
    perform rs.t_as(b); perform rs.t_vote(rv, p2, 'ta', 'include'); perform rs.t_vote(rv, p4, 'ta', 'maybe'); perform rs.t_vote(rv, p6, 'ta', 'exclude', lab1);
    res := res || rs.t_r('50 policy: include+include advances; include+maybe advances as uncertain; exclude+exclude excludes; exclude vs include is a conflict; one vote stays pending',
      (select ta_status = 'advanced' and not ta_uncertain from rs.records where id = p2) and (select ta_status = 'advanced' and ta_uncertain from rs.records where id = p4)
      and (select ta_status = 'excluded' from rs.records where id = p6) and (select ta_status = 'conflict' from rs.records where id = p7) and (select ta_status = 'pending' from rs.records where id = p8));
    perform rs.t_as(a);
    perform rs.t_vote(rv, p8, 'ta', 'maybe');
    res := res || rs.t_r('51 changing a vote keeps the old one in history', (select count(*) from rs.votes where record_id = p8 and user_id = a) = 2 and (select count(*) from rs.votes where record_id = p8 and user_id = a and is_current) = 1);
    res := res || rs.t_r('52 saved votes cannot be edited or deleted, even by the database owner path',
      rs.t_fail(format('update rs.votes set decision = ''include'' where record_id = %s', p6)) = '42501' and rs.t_fail(format('delete from rs.votes where record_id = %s', p6)) = '42501');
    res := res || rs.t_r('53 an exclusion reason cannot ride on an Include vote', rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ta'', ''include'', ''{}'', %s)', rv, p8, lab1)) = 'reason_not_allowed');

    -- 7 AI labels
    res := res || rs.t_r('54 AI exclusion needs a reason label', rs.t_fail(format('select public.rs_ai_annotate(%L, %s, ''ta'', ''exclude'')', rv, p8)) = 'reason_required');
    res := res || rs.t_r('55 AI cannot create a label for a criterion that is not active', rs.t_fail(format('select public.rs_ai_annotate(%L, %s, ''ta'', ''exclude'', null, ''Too small sample'', %s, ''[{"excerpt":"x"}]'')', rv, p8, pcrit)) = 'criterion_not_active');
    j := public.rs_ai_annotate(rv, rs.t_rec(rv, 'P1'), 'ta', 'exclude', lab1, null, null, '[{"excerpt":"adults received HYALURONIDASE in both arms","locator":"abstract"},{"excerpt":"invented text","locator":"abstract"}]'::jsonb);
    res := res || rs.t_r('56 AI label shows as a recommendation, checks excerpts against the record, and is not a vote',
      j ->> 'display' = 'AI recommends exclusion — Hyaluronidase in all arms' and j -> 'evidence' -> 0 ->> 'found_in_record_text' = 'true' and j -> 'evidence' -> 1 ->> 'found_in_record_text' = 'false'
      and (select ta_status from rs.records where id = rs.t_rec(rv, 'P1')) = 'pending' and (select count(*) from rs.votes where record_id = rs.t_rec(rv, 'P1')) = 0, j::text);

    -- 8 adjudication and moderator approval
    res := res || rs.t_r('57 a reviewer without the adjudication right cannot recommend', rs.t_fail(format('select public.rs_recommend_adjudication(%L, %s, ''ta'', ''advance'')', rv, p7)) = 'capability_required');
    perform rs.t_as(m);
    j := public.rs_get_record(rv, p7, 'ta');
    res := res || rs.t_r('58 the non-screening moderator sees both original votes', jsonb_array_length(j -> 'peer_votes') = 2 and j ->> 'team_status' = 'conflict', j::text);
    j := public.rs_recommend_adjudication(rv, p7, 'ta', 'advance', null, 'synthetic rationale'); ap := (j ->> 'approval_id')::bigint;
    res := res || rs.t_r('59 a recommendation alone does not change the disposition', (select ta_status from rs.records where id = p7) = 'conflict');
    t := public.rs_propose_approval_decision(ap, 'approve');
    update rs.approvals set payload = payload || '{"resolution":"exclude"}', payload_hash = rs.hash(payload || '{"resolution":"exclude"}') where id = ap;
    res := res || rs.t_r('60 an approval prepared before the request changed is invalid', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash')) = 'approval_changed');
    update rs.approvals set payload = payload || '{"resolution":"advance"}', payload_hash = rs.hash(payload || '{"resolution":"advance"}') where id = ap;
    perform rs.t_confirm(public.rs_propose_approval_decision(ap, 'approve'));
    res := res || rs.t_r('61 moderator approval finalises; original votes are preserved; sign-off is not a vote',
      (select ta_status = 'advanced' and ta_final_basis = 'moderator_adjudication' from rs.records where id = p7) and (select count(*) from rs.votes where record_id = p7 and is_current) = 2);
    perform rs.t_as(a);
    res := res || rs.t_r('62 a finalised record cannot be re-voted', rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ta'', ''exclude'')', rv, p7)) = 'stage_finalised');

    -- 9 full text
    res := res || rs.t_r('63 full-text exclusion needs a primary reason', rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ft'', ''exclude'')', rv, p2)) = 'primary_reason_required');
    res := res || rs.t_r('64 full-text votes only on records advanced at title/abstract', rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ft'', ''include'')', rv, p6)) = 'not_advanced');
    perform rs.t_vote(rv, p2, 'ft', 'include'); perform rs.t_vote(rv, p4, 'ft', 'exclude', lab1); perform public.rs_mark_retrieval(rv, p7, true, 'synthetic: PDF not found');
    perform rs.t_as(b); perform rs.t_vote(rv, p2, 'ft', 'include'); perform rs.t_vote(rv, p4, 'ft', 'exclude', lab2);
    res := res || rs.t_r('65 two exclusions with different primary reasons need resolution; not-retrieved is not an exclusion',
      (select ft_status from rs.records where id = p4) = 'conflict' and (select ft_status from rs.records where id = p2) = 'included' and (select ft_status from rs.records where id = p7) = 'not_retrieved'
      and rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ft'', ''exclude'', ''{}'', %s)', rv, p7, lab1)) = 'not_retrieved');
    perform rs.t_as(m);
    j := public.rs_recommend_adjudication(rv, p4, 'ft', 'exclude', lab1, 'synthetic');
    perform rs.t_confirm(public.rs_propose_approval_decision((j ->> 'approval_id')::bigint, 'approve'));
    j := public.rs_prisma(rv);
    res := res || rs.t_r('66 ledger after screening: reason totals reconcile and every check passes',
      (j -> 'full_text' ->> 'reports_sought')::int = 3 and (j -> 'full_text' ->> 'reports_excluded')::int = 1 and (j -> 'full_text' ->> 'reports_not_retrieved')::int = 1 and (j -> 'full_text' ->> 'reports_included')::int = 1
      and (j -> 'full_text' -> 'excluded_by_primary_reason' -> 0 ->> 'reports')::int = 1 and not exists (select 1 from jsonb_array_elements(j -> 'validation') v where (v ->> 'ok')::boolean is not true), j::text);

    -- 10 reviews cannot mix; stale requests
    perform rs.t_as(a);
    res := res || rs.t_r('67 a member of one review cannot act in another', rs.t_fail(format('select public.rs_propose_vote(%L, %s, ''ta'', ''include'')', rv2, p8)) = 'forbidden');
    perform rs.t_as(m);
    res := res || rs.t_r('68 a record ID from one review is refused under another review ID', rs.t_fail(format('select public.rs_get_record(%L, %s)', rv2, p8)) = 'record_not_in_review');
    perform rs.t_as(a);
    t := public.rs_propose_vote(rv, e7, 'ta', 'include');
    perform rs.t_as(m);
    select id into q from rs.dedup_queue where review_id = rv and status = 'open' and record_a = least(p7, e7) and record_b = greatest(p7, e7);
    perform public.rs_dedup_resolve(q, 'merge', p7);
    perform rs.t_as(a);
    res := res || rs.t_r('69 a vote prepared before the record was merged is refused at confirmation', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash')) = 'record_merged');
    t := public.rs_propose_vote(rv, rs.t_rec(rv, 'P9'), 'ta', 'include');
    update rs.confirmations set expires_at = now() - interval '1 minute' where id = (t ->> 'confirmation_id')::uuid;
    res := res || rs.t_r('70 an expired confirmation saves nothing', rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash')) = 'confirmation_expired');

    -- 11 criterion activation is an amendment
    perform rs.t_as(m);
    select id into ap from rs.approvals where review_id = rv and kind = 'criterion_activation' and status = 'pending';
    j := rs.t_confirm(public.rs_propose_approval_decision(ap, 'approve'));
    res := res || rs.t_r('71 activating a criterion records an amendment task and marks AI feedback stale',
      (select status from rs.criteria where id = pcrit) = 'active' and exists (select 1 from rs.tasks where review_id = rv and kind = 'reassess_after_amendment') and not exists (select 1 from rs.ai_annotations where review_id = rv and not stale));

    -- 12 moderator who also screens; unblinding is deliberate and audited
    perform rs.t_confirm(public.rs_propose_grant_change(rv, m, array['screen_ta'], '{}'));
    j := public.rs_get_record(rv, p8, 'ta');
    res := res || rs.t_r('72 a moderator who also screens does not see peer votes through moderator rights', j -> 'peer_votes' ->> 'hidden' = 'true');
    perform rs.t_confirm(public.rs_propose_unblind(rv, 'ta', 'record', p8, 'synthetic reason'));
    j := public.rs_get_record(rv, p8, 'ta');
    perform rs.t_vote(rv, p8, 'ta', 'include');
    res := res || rs.t_r('73 unblinding is scoped, audited and flags later votes',
      jsonb_typeof(j -> 'peer_votes') = 'array' and exists (select 1 from rs.audit_log where review_id = rv and action = 'unblinded') and (select after_unblind from rs.votes where record_id = p8 and user_id = m and is_current)
      and (public.rs_get_record(rv, rs.t_rec(rv, 'P9'), 'ta') -> 'peer_votes' ->> 'hidden') = 'true');

    -- 13 strict confirmation channel
    update rs.workspace set confirmation_channel = 'browser_only';
    perform rs.t_as(a, 'claude-synthetic-client');
    t := public.rs_propose_vote(rv, rs.t_rec(rv, 'P9'), 'ta', 'include');
    x := rs.t_fail(format('select public.rs_confirm(%L, %L)', t ->> 'confirmation_id', t ->> 'payload_hash'));
    perform rs.t_as(a);
    j := rs.t_confirm(t);
    res := res || rs.t_r('74 strict mode: a connector token cannot confirm; a direct browser session can', x = 'human_channel_required' and j ->> 'saved' = 'true', x);

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
revoke all on function rs.selftest() from public, anon, authenticated;
