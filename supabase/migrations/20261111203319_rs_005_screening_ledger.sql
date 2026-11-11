alter table rs.votes add column after_unblind boolean not null default false;

create function rs.can_vote(p_review uuid, p_record bigint, p_stage text, p_uid uuid) returns boolean language sql stable set search_path = '' as $$
  select rs.has_cap(p_review, p_uid, 'screen_' || p_stage)
     and (not exists (select 1 from rs.assignments a where a.record_id = p_record and a.stage = p_stage)
          or exists (select 1 from rs.assignments a where a.record_id = p_record and a.stage = p_stage and a.user_id = p_uid))
$$;

create function rs.stage_status(r rs.records, p_stage text) returns text language sql immutable set search_path = '' as $$
  select case when p_stage = 'ta' then r.ta_status else r.ft_status end
$$;

-- Blinding rule, evaluated in the database for every read that could carry a peer decision.
create function rs.can_see_peer(p_review uuid, p_record bigint, p_stage text, p_uid uuid) returns boolean language plpgsql stable set search_path = '' as $$
declare v_screener boolean := rs.has_cap(p_review, p_uid, 'screen_' || p_stage); v_voted boolean; v_status text; v_reveal boolean;
begin
  if exists (select 1 from rs.unblind_events u where u.review_id = p_review and u.user_id = p_uid and u.stage = p_stage and (u.scope = 'review' or u.record_id = p_record)) then return true; end if;
  v_voted := exists (select 1 from rs.votes x where x.record_id = p_record and x.stage = p_stage and x.user_id = p_uid and x.is_current);
  if v_screener and not v_voted then return false; end if;
  select rs.stage_status(r, p_stage) into v_status from rs.records r where r.id = p_record;
  if rs.is_moderator(p_uid) then return (not v_screener) or v_status = 'conflict'; end if;
  if rs.has_cap(p_review, p_uid, 'adjudicate') then return v_status = 'conflict'; end if;
  select coalesce((r.policy ->> 'reveal_peer_votes_after_all_voted')::boolean, false) into v_reveal from rs.reviews r where r.id = p_review;
  return v_reveal and v_voted and v_status <> 'pending';
end $$;

-- Whether this person may see the split of team dispositions (advanced / excluded / conflict) at a stage.
create function rs.can_see_split(p_review uuid, p_stage text, p_uid uuid) returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from rs.unblind_events u where u.review_id = p_review and u.user_id = p_uid and u.stage = p_stage and u.scope = 'review')
      or (not rs.has_cap(p_review, p_uid, 'screen_' || p_stage) and (rs.is_moderator(p_uid) or rs.has_cap(p_review, p_uid, 'adjudicate')))
$$;

create function rs.recompute(p_record bigint, p_stage text) returns void language plpgsql set search_path = '' as $$
declare r rs.records; v_req int; n int; n_inc int; n_exc int; n_maybe int; n_reasons int; v_reason bigint; v_status text;
begin
  select * into r from rs.records where id = p_record for update;
  select (rv.policy ->> 'reviewers_per_record')::int into v_req from rs.reviews rv where rv.id = r.review_id;
  select count(*), count(*) filter (where decision = 'include'), count(*) filter (where decision = 'exclude'), count(*) filter (where decision = 'maybe'),
         count(distinct primary_reason_id) filter (where decision = 'exclude'), min(primary_reason_id) filter (where decision = 'exclude')
    into n, n_inc, n_exc, n_maybe, n_reasons, v_reason
  from rs.votes where record_id = p_record and stage = p_stage and is_current;
  if p_stage = 'ta' then
    if r.ta_final_basis = 'moderator_adjudication' then return; end if;
    v_status := case when n < v_req then 'pending' when n_exc = n then 'excluded' when n_exc > 0 then 'conflict' else 'advanced' end;
    update rs.records set ta_status = v_status, ta_uncertain = (v_status = 'advanced' and n_maybe > 0),
      ta_final_basis = case when v_status in ('advanced','excluded') then 'reviewer_agreement' end,
      ft_status = case when v_status = 'advanced' and ft_status = 'not_started' then 'pending'
                       when v_status <> 'advanced' and ft_status = 'pending' and not exists (select 1 from rs.votes x where x.record_id = p_record and x.stage = 'ft' and x.is_current) then 'not_started'
                       else ft_status end
    where id = p_record;
  else
    if r.ft_final_basis = 'moderator_adjudication' or r.ft_status = 'not_retrieved' then return; end if;
    v_status := case when n < v_req then 'pending' when n_inc = n then 'included' when n_exc = n and n_reasons = 1 then 'excluded' else 'conflict' end;
    update rs.records set ft_status = v_status, ft_primary_reason_id = case when v_status = 'excluded' then v_reason end,
      ft_final_basis = case when v_status in ('included','excluded') then 'reviewer_agreement' end
    where id = p_record;
  end if;
end $$;

create function rs.check_vote(p_review uuid, p_record bigint, p_stage text, p_decision text, p_reason_ids bigint[], p_primary bigint, p_uid uuid) returns rs.records
language plpgsql stable set search_path = '' as $$
declare r rs.records; rv rs.reviews; v_bad int;
begin
  if p_stage not in ('ta','ft') or p_decision not in ('include','exclude','maybe') then perform rs.fail('bad_vote', 'Stage must be ta or ft; decision must be include, exclude or maybe'); end if;
  select * into rv from rs.reviews where id = p_review;
  if rv.status <> 'active' or rv.active_protocol_version_id is null then perform rs.fail('review_not_active', 'Screening needs an activated review with an approved protocol'); end if;
  select * into r from rs.records where id = p_record and review_id = p_review;
  if not found then perform rs.fail('record_not_in_review', 'That record does not belong to this review'); end if;
  if r.merged_into is not null then perform rs.fail('record_merged', format('This record was merged as a duplicate. Screen record %s instead.', r.merged_into)); end if;
  if not rs.can_vote(p_review, p_record, p_stage, p_uid) then
    raise exception 'You do not hold the screening right for this stage, or the record is assigned to other reviewers' using errcode = '42501', detail = 'capability_required';
  end if;
  if p_stage = 'ta' and r.ta_final_basis = 'moderator_adjudication' then perform rs.fail('stage_finalised', 'The moderator already finalised this record at title/abstract'); end if;
  if p_stage = 'ft' then
    if r.ta_status <> 'advanced' then perform rs.fail('not_advanced', 'Full-text assessment is only for records advanced at title/abstract'); end if;
    if r.ft_final_basis = 'moderator_adjudication' then perform rs.fail('stage_finalised', 'The moderator already finalised this record at full text'); end if;
    if r.ft_status = 'not_retrieved' then perform rs.fail('not_retrieved', 'This report is marked as not retrieved. A missing PDF is a retrieval failure, not an exclusion.'); end if;
  end if;
  select count(*) into v_bad from unnest(coalesce(p_reason_ids, '{}') || case when p_primary is null then '{}'::bigint[] else array[p_primary] end) x
   where not exists (select 1 from rs.reason_labels l where l.id = x and l.review_id = p_review and l.status = 'active' and l.stage in (p_stage, 'both'));
  if v_bad > 0 then perform rs.fail('bad_reason', 'Every reason must be an active reason label of this review for this stage'); end if;
  if p_decision = 'exclude' then
    if p_stage = 'ft' and p_primary is null then perform rs.fail('primary_reason_required', 'A full-text exclusion needs one primary approved reason'); end if;
    if p_stage = 'ta' and coalesce((rv.policy ->> 'ta_exclude_reason_required')::boolean, false) and p_primary is null and coalesce(array_length(p_reason_ids, 1), 0) = 0 then
      perform rs.fail('reason_required', 'This review requires a reason for title/abstract exclusions');
    end if;
  elsif p_primary is not null or coalesce(array_length(p_reason_ids, 1), 0) > 0 then
    perform rs.fail('reason_not_allowed', 'Exclusion reasons apply only to an Exclude decision');
  end if;
  return r;
end $$;

create function public.rs_propose_vote(p_review uuid, p_record bigint, p_stage text, p_decision text, p_reason_ids bigint[] default '{}', p_primary_reason bigint default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); r rs.records; rv rs.reviews; v_reasons bigint[]; v_label text;
begin
  r := rs.check_vote(p_review, p_record, p_stage, p_decision, p_reason_ids, p_primary_reason, v);
  select * into rv from rs.reviews where id = p_review;
  v_reasons := (select coalesce(array_agg(distinct x order by x), '{}') from unnest(coalesce(p_reason_ids, '{}') || case when p_primary_reason is null then '{}'::bigint[] else array[p_primary_reason] end) x);
  select string_agg(l.label, '; ' order by (l.id = p_primary_reason) desc, l.id) into v_label from rs.reason_labels l where l.id = any(v_reasons);
  return rs.new_confirmation(p_review, 'vote',
    jsonb_build_object('review_id', p_review, 'record_id', p_record, 'stage', p_stage, 'decision', p_decision, 'reason_ids', to_jsonb(v_reasons), 'primary_reason_id', p_primary_reason,
      'note', p_note, 'protocol_version_id', rv.active_protocol_version_id, 'record_revision', r.revision),
    format('%s · record #%s · %s · %s%s — "%s"', rv.code, r.seq, case p_stage when 'ta' then 'Title/abstract' else 'Full text' end, upper(p_decision),
      case when v_label is not null then ' — ' || v_label else '' end, left(coalesce(r.title, '(no title)'), 90)));
end $$;

create function rs.apply_vote(p jsonb, p_uid uuid, p_conf uuid) returns jsonb language plpgsql set search_path = '' as $$
declare v_review uuid := (p ->> 'review_id')::uuid; v_record bigint := (p ->> 'record_id')::bigint; v_stage text := p ->> 'stage'; r rs.records; rv rs.reviews;
  v_reasons bigint[] := (select coalesce(array_agg(x::bigint), '{}') from jsonb_array_elements_text(coalesce(p -> 'reason_ids', '[]')) x);
  v_primary bigint := (p ->> 'primary_reason_id')::bigint; v_id bigint; v_ai boolean; v_unb boolean;
begin
  perform rs.require_member(v_review);
  r := rs.check_vote(v_review, v_record, v_stage, p ->> 'decision', v_reasons, v_primary, p_uid);
  select * into rv from rs.reviews where id = v_review;
  if r.revision <> (p ->> 'record_revision')::int then perform rs.fail('record_changed', 'The record changed after this vote was prepared. Nothing was saved; open the record again.'); end if;
  if rv.active_protocol_version_id is distinct from (p ->> 'protocol_version_id')::bigint then perform rs.fail('protocol_changed', 'The approved protocol changed after this vote was prepared. Nothing was saved.'); end if;
  v_ai := exists (select 1 from rs.ai_annotations a where a.record_id = v_record and a.stage = v_stage and not a.stale
                  and (a.created_by = p_uid or rv.policy ->> 'ai_visibility' = 'always'));
  v_unb := exists (select 1 from rs.unblind_events u where u.review_id = v_review and u.user_id = p_uid and u.stage = v_stage and (u.scope = 'review' or u.record_id = v_record));
  update rs.votes set is_current = false where record_id = v_record and stage = v_stage and user_id = p_uid and is_current;
  insert into rs.votes (review_id, record_id, stage, user_id, decision, reason_ids, primary_reason_id, note, protocol_version_id, record_revision, channel, ai_assisted, confirmation_id, after_unblind)
  values (v_review, v_record, v_stage, p_uid, p ->> 'decision', v_reasons, v_primary, p ->> 'note', rv.active_protocol_version_id, r.revision, rs.channel(), v_ai, p_conf, v_unb)
  returning id into v_id;
  perform rs.recompute(v_record, v_stage);
  perform rs.audit(v_review, 'vote_saved', 'record', v_record::text, jsonb_build_object('stage', v_stage, 'vote_id', v_id, 'ai_assisted', v_ai));
  return jsonb_build_object('vote_id', v_id, 'record_id', v_record, 'stage', v_stage, 'your_decision', p ->> 'decision', 'ai_assisted', v_ai, 'saved_at', now());
end $$;

create function public.rs_ai_annotate(p_review uuid, p_record bigint, p_stage text, p_recommendation text, p_reason_label_id bigint default null,
  p_new_reason_label text default null, p_criterion_id bigint default null, p_evidence jsonb default '[]', p_rationale text default null, p_model text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); r rs.records; rv rs.reviews; v_label bigint := p_reason_label_id; v_made jsonb; l rs.reason_labels; v_ev jsonb; v_hay text; v_id bigint;
begin
  if not rs.has_cap(p_review, v, 'screen_' || coalesce(p_stage, '')) then
    raise exception 'AI annotations run under the screening right of the signed-in reviewer' using errcode = '42501', detail = 'capability_required';
  end if;
  if p_recommendation not in ('include','exclude','needs_information') then perform rs.fail('bad_recommendation', 'Recommendation must be include, exclude or needs_information'); end if;
  select * into rv from rs.reviews where id = p_review;
  if rv.status <> 'active' then perform rs.fail('review_not_active', 'The review is not active'); end if;
  select * into r from rs.records where id = p_record and review_id = p_review and merged_into is null;
  if not found then perform rs.fail('record_not_in_review', 'That record is not a current record of this review'); end if;
  if v_label is null and coalesce(btrim(p_new_reason_label), '') <> '' then
    v_made := rs.make_reason_label(p_review, p_stage, p_new_reason_label, p_criterion_id, v);
    v_label := (v_made ->> 'reason_id')::bigint;
  end if;
  if p_recommendation = 'exclude' and v_label is null then
    perform rs.fail('reason_required', 'An AI exclusion recommendation needs a reason label that maps to an active criterion. If the rule is not in the protocol, propose a criterion instead.');
  end if;
  if v_label is not null then
    select * into l from rs.reason_labels where id = v_label and review_id = p_review and status = 'active';
    if not found then perform rs.fail('bad_reason', 'Unknown reason label for this review'); end if;
  end if;
  v_hay := lower(regexp_replace(coalesce(r.title, '') || ' ' || coalesce(r.abstract, ''), '\s+', ' ', 'g'));
  select coalesce(jsonb_agg(jsonb_build_object('excerpt', left(e ->> 'excerpt', 600), 'locator', e ->> 'locator',
      'found_in_record_text', case when p_stage = 'ta' then position(lower(regexp_replace(btrim(coalesce(e ->> 'excerpt', '')), '\s+', ' ', 'g')) in v_hay) > 0 end)), '[]')
    into v_ev from jsonb_array_elements(coalesce(p_evidence, '[]')) e where coalesce(btrim(e ->> 'excerpt'), '') <> '';
  if p_recommendation = 'exclude' and jsonb_array_length(v_ev) = 0 then perform rs.fail('evidence_required', 'An AI exclusion recommendation needs at least one short excerpt from the source as evidence'); end if;
  insert into rs.ai_annotations (review_id, record_id, stage, recommendation, reason_label_id, criterion_version_id, protocol_version_id, evidence, rationale, model, created_by, channel)
  values (p_review, p_record, p_stage, p_recommendation, v_label, l.criterion_version_id, rv.active_protocol_version_id, v_ev, p_rationale, p_model, v, rs.channel()) returning id into v_id;
  perform rs.audit(p_review, 'ai_annotation_created', 'record', p_record::text, jsonb_build_object('annotation_id', v_id, 'stage', p_stage));
  return jsonb_build_object('status', 'ai_annotation_saved', 'saved', true, 'annotation_id', v_id, 'record_id', p_record,
    'display', case p_recommendation when 'exclude' then 'AI recommends exclusion — ' || l.label when 'include' then 'AI recommends inclusion' else 'AI needs more information' end,
    'evidence', v_ev, 'reason_label', v_made,
    'is_a_vote', false, 'note', 'This is an AI suggestion only. It is not a human vote and never counts as a reviewer.');
end $$;

create function public.rs_queue(p_review uuid, p_stage text default 'ta', p_filter text default 'todo', p_limit int default 50, p_offset int default 0, p_search text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_split boolean := rs.can_see_split(p_review, p_stage, v); v_items jsonb; v_tot jsonb;
begin
  if p_stage not in ('ta','ft') then perform rs.fail('bad_stage', 'Stage must be ta or ft'); end if;
  if p_filter = 'conflicts' and not v_split and not (rs.is_moderator(v) or rs.has_cap(p_review, v, 'adjudicate')) then
    raise exception 'Conflicts are visible to adjudicators and the moderator' using errcode = '42501', detail = 'capability_required';
  end if;
  with base as (
    select r.*, (select x.decision from rs.votes x where x.record_id = r.id and x.stage = p_stage and x.user_id = v and x.is_current) as my_decision,
           rs.can_vote(p_review, r.id, p_stage, v) as can_vote
    from rs.records r where r.review_id = p_review and r.merged_into is null and (p_stage = 'ta' or r.ta_status = 'advanced')),
  filtered as (
    select * from base b where (p_search is null or b.title ilike '%' || p_search || '%' or b.abstract ilike '%' || p_search || '%')
      and case p_filter when 'todo' then b.can_vote and b.my_decision is null and not (p_stage = 'ft' and b.ft_status = 'not_retrieved')
                        when 'voted' then b.my_decision is not null
                        when 'conflicts' then rs.stage_status(b::rs.records, p_stage) = 'conflict' and rs.can_see_peer(p_review, b.id, p_stage, v)
                        else true end)
  select (select coalesce(jsonb_agg(jsonb_build_object('record_id', f.id, 'seq', f.seq, 'title', f.title, 'first_author', f.authors[1], 'year', f.year, 'journal', f.journal,
            'your_decision', f.my_decision, 'you_can_vote', f.can_vote, 'has_abstract', coalesce(f.abstract, '') <> '',
            'retrieval', case when p_stage = 'ft' and f.ft_status = 'not_retrieved' then 'not_retrieved' end,
            'team_status', case when v_split or rs.can_see_peer(p_review, f.id, p_stage, v) then rs.stage_status(f::rs.records, p_stage) end) order by f.seq), '[]')
          from (select * from filtered order by seq limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) f),
         (select jsonb_build_object('in_this_filter', (select count(*) from filtered), 'records_at_stage', count(*), 'you_voted', count(*) filter (where my_decision is not null),
            'you_still_to_vote', count(*) filter (where can_vote and my_decision is null)) from base)
    into v_items, v_tot;
  return jsonb_build_object('review_id', p_review, 'stage', p_stage, 'filter', p_filter, 'items', v_items, 'totals', v_tot,
    'stage_meaning', case p_stage when 'ta' then 'Include at title/abstract means: advance to full-text assessment. It is not final study inclusion.' else 'Full-text decisions determine report eligibility. An exclusion needs one primary approved reason.' end,
    'retrieved_at', now());
end $$;

create function public.rs_get_record(p_review uuid, p_record bigint, p_stage text default 'ta') returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); r rs.records; rv rs.reviews; v_peer boolean; v_mine jsonb; v_ai text;
begin
  if p_stage not in ('ta','ft') then perform rs.fail('bad_stage', 'Stage must be ta or ft'); end if;
  select * into r from rs.records where id = p_record and review_id = p_review;
  if not found then perform rs.fail('record_not_in_review', 'That record does not belong to this review'); end if;
  select * into rv from rs.reviews where id = p_review;
  v_peer := rs.can_see_peer(p_review, p_record, p_stage, v);
  select jsonb_build_object('vote_id', x.id, 'decision', x.decision, 'reason_ids', x.reason_ids, 'primary_reason_id', x.primary_reason_id, 'note', x.note, 'saved_at', x.created_at,
      'protocol_version_id', x.protocol_version_id, 'ai_assisted', x.ai_assisted) into v_mine
    from rs.votes x where x.record_id = p_record and x.stage = p_stage and x.user_id = v and x.is_current;
  v_ai := rv.policy ->> 'ai_visibility';
  return jsonb_build_object(
    'review_id', p_review, 'review_code', rv.code, 'stage', p_stage, 'protocol_version_id', rv.active_protocol_version_id,
    'record', jsonb_build_object('record_id', r.id, 'seq', r.seq, 'revision', r.revision, 'title', r.title, 'authors', r.authors, 'year', r.year, 'journal', r.journal, 'doi', r.doi, 'pmid', r.pmid,
      'abstract', r.abstract, 'ref_type', r.ref_type, 'merged_into', r.merged_into),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('database_name', s.database_name, 'preset', s.preset, 'batch_id', o.batch_id, 'source_record_id', o.src_record_id,
        'via_merged_record', case when o.record_id <> r.id then o.record_id end, 'export_overlap', o.is_export_overlap) order by o.id), '[]')
      from rs.source_occurrences o join rs.sources s on s.id = o.source_id where o.record_id = r.id or o.record_id in (select m.id from rs.records m where m.merged_into = r.id)),
    'companions', (select coalesce(jsonb_agg(case when k.record_a = r.id then k.record_b else k.record_a end), '[]') from rs.record_links k where r.id in (k.record_a, k.record_b)),
    'you_can_vote', rs.can_vote(p_review, p_record, p_stage, v),
    'your_vote', v_mine,
    'ai_annotations', (select coalesce(jsonb_agg(jsonb_build_object('annotation_id', a.id, 'recommendation', a.recommendation,
        'display', case a.recommendation when 'exclude' then 'AI recommends exclusion — ' || coalesce(l.label, '') when 'include' then 'AI recommends inclusion' else 'AI needs more information' end,
        'reason_id', a.reason_label_id, 'criterion_version_id', a.criterion_version_id, 'evidence', a.evidence, 'rationale', a.rationale, 'model', a.model, 'stale', a.stale,
        'requested_by_you', a.created_by = v, 'created_at', a.created_at) order by a.id desc), '[]')
      from rs.ai_annotations a left join rs.reason_labels l on l.id = a.reason_label_id
      where a.record_id = p_record and a.stage = p_stage
        and (a.created_by = v or v_ai = 'always' or (v_ai = 'after_own_vote' and v_mine is not null) or v_peer)),
    'ai_visibility_rule', v_ai,
    'peer_votes', case when v_peer then (select coalesce(jsonb_agg(jsonb_build_object('reviewer', coalesce(p.display_name, p.email), 'decision', x.decision, 'reason_ids', x.reason_ids,
          'primary_reason_id', x.primary_reason_id, 'note', x.note, 'saved_at', x.created_at, 'ai_assisted', x.ai_assisted) order by x.id), '[]')
        from rs.votes x left join rs.profiles p on p.user_id = x.user_id where x.record_id = p_record and x.stage = p_stage and x.is_current and x.user_id <> v)
      else jsonb_build_object('hidden', true, 'why', 'Peer decisions are blinded for you on this record.') end,
    'team_status', case when v_peer or rs.can_see_split(p_review, p_stage, v) then rs.stage_status(r, p_stage) end,
    'retrieved_at', now());
end $$;

create function public.rs_mark_retrieval(p_review uuid, p_record bigint, p_not_retrieved boolean, p_note text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'screen_ft'); r rs.records;
begin
  select * into r from rs.records where id = p_record and review_id = p_review and merged_into is null for update;
  if not found or r.ta_status <> 'advanced' then perform rs.fail('not_advanced', 'Only reports advanced at title/abstract can have a retrieval status'); end if;
  if p_not_retrieved then
    if exists (select 1 from rs.votes x where x.record_id = p_record and x.stage = 'ft' and x.is_current) then perform rs.fail('has_votes', 'This report already has full-text votes'); end if;
    update rs.records set ft_status = 'not_retrieved' where id = p_record;
  else
    update rs.records set ft_status = 'pending' where id = p_record and ft_status = 'not_retrieved';
  end if;
  perform rs.audit(p_review, 'retrieval_status_set', 'record', p_record::text, jsonb_build_object('not_retrieved', p_not_retrieved, 'note', p_note));
  return jsonb_build_object('status', 'saved', 'saved', true, 'record_id', p_record, 'retrieval', case when p_not_retrieved then 'not_retrieved' else 'pending' end,
    'note', 'Not retrieved is a retrieval failure. It is reported separately and is never counted as a clinical exclusion.');
end $$;

create function public.rs_recommend_adjudication(p_review uuid, p_record bigint, p_stage text, p_resolution text, p_primary_reason bigint default null, p_rationale text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'adjudicate'); r rs.records; v_id bigint; v_payload jsonb; v_ap bigint;
begin
  select * into r from rs.records where id = p_record and review_id = p_review and merged_into is null;
  if not found then perform rs.fail('record_not_in_review', 'That record does not belong to this review'); end if;
  if rs.stage_status(r, p_stage) <> 'conflict' or not rs.can_see_peer(p_review, p_record, p_stage, v) then
    perform rs.fail('not_adjudicable', 'This record is not an open conflict that you may adjudicate (if you screen it yourself, save your own vote first)');
  end if;
  if (p_stage = 'ta' and p_resolution not in ('advance','exclude')) or (p_stage = 'ft' and p_resolution not in ('include','exclude')) then perform rs.fail('bad_resolution', 'Resolution must be advance/exclude at title/abstract, or include/exclude at full text'); end if;
  if p_stage = 'ft' and p_resolution = 'exclude' and p_primary_reason is null then perform rs.fail('primary_reason_required', 'A full-text exclusion needs one primary approved reason'); end if;
  if p_primary_reason is not null and not exists (select 1 from rs.reason_labels l where l.id = p_primary_reason and l.review_id = p_review and l.status = 'active') then perform rs.fail('bad_reason', 'Unknown reason label'); end if;
  update rs.adjudications set status = 'superseded' where record_id = p_record and stage = p_stage and status = 'recommended';
  update rs.approvals a set status = 'superseded' where a.review_id = p_review and a.kind = 'adjudication' and a.status = 'pending' and (a.payload ->> 'record_id')::bigint = p_record and a.payload ->> 'stage' = p_stage;
  insert into rs.adjudications (review_id, record_id, stage, recommended_by, resolution, primary_reason_id, rationale) values (p_review, p_record, p_stage, v, p_resolution, p_primary_reason, p_rationale) returning id into v_id;
  v_payload := jsonb_build_object('adjudication_id', v_id, 'record_id', p_record, 'record_seq', r.seq, 'stage', p_stage, 'resolution', p_resolution, 'primary_reason_id', p_primary_reason, 'rationale', p_rationale);
  insert into rs.approvals (review_id, kind, title, payload, payload_hash, evidence, requested_by, requested_channel)
  values (p_review, 'adjudication', format('Adjudication of record #%s (%s): recommend %s', r.seq, p_stage, p_resolution), v_payload, rs.hash(v_payload),
    jsonb_build_object('title', r.title, 'original_votes', (select jsonb_agg(jsonb_build_object('reviewer', coalesce(p.display_name, p.email), 'decision', x.decision, 'primary_reason_id', x.primary_reason_id, 'reason_ids', x.reason_ids, 'note', x.note) order by x.id)
        from rs.votes x left join rs.profiles p on p.user_id = x.user_id where x.record_id = p_record and x.stage = p_stage and x.is_current),
      'note', 'Original votes are preserved. Approval records the final team disposition; it does not count as another independent reviewer vote.'), v, rs.channel())
  returning id into v_ap;
  update rs.adjudications set approval_id = v_ap where id = v_id;
  perform rs.audit(p_review, 'adjudication_recommended', 'record', p_record::text, jsonb_build_object('stage', p_stage, 'approval_id', v_ap));
  return jsonb_build_object('status', 'awaiting_moderator_approval', 'saved', true, 'adjudication_id', v_id, 'approval_id', v_ap);
end $$;

create function public.rs_propose_unblind(p_review uuid, p_stage text, p_scope text, p_record bigint default null, p_reason text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator();
begin
  if p_stage not in ('ta','ft') or p_scope not in ('record','review') or (p_scope = 'record' and p_record is null) or coalesce(btrim(p_reason), '') = '' then
    perform rs.fail('bad_unblind', 'Unblinding needs a stage, a scope (record or review), the record when scoped to one, and a written reason');
  end if;
  return rs.new_confirmation(p_review, 'unblind', jsonb_build_object('review_id', p_review, 'stage', p_stage, 'scope', p_scope, 'record_id', p_record, 'reason', p_reason),
    format('Unblind peer votes for yourself at %s (%s%s). This is audited; your later votes on affected records are flagged as made after unblinding. Reason: %s', p_stage, p_scope, case when p_record is not null then ' ' || p_record else '' end, p_reason));
end $$;

create function public.rs_propose_workspace_setting(p_confirmation_channel text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator();
begin
  if p_confirmation_channel not in ('app_or_browser','browser_only') then perform rs.fail('bad_setting', 'Value must be app_or_browser or browser_only'); end if;
  return rs.new_confirmation(null, 'workspace_setting', jsonb_build_object('confirmation_channel', p_confirmation_channel), format('Set where human confirmations are accepted to: %s', p_confirmation_channel));
end $$;

create function public.rs_overview(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_mod boolean := rs.is_moderator(v); v_adj boolean; s text; v_stages jsonb := '{}'; v_split boolean; j jsonb;
begin
  v_adj := v_mod or rs.has_cap(p_review, v, 'adjudicate');
  foreach s in array array['ta','ft'] loop
    v_split := rs.can_see_split(p_review, s, v);
    select jsonb_build_object(
      'unit', case s when 'ta' then 'records (after duplicate removal)' else 'reports advanced at title/abstract' end,
      'denominator', count(*),
      'you', jsonb_build_object('has_screening_right', rs.has_cap(p_review, v, 'screen_' || s),
        'voted', count(*) filter (where exists (select 1 from rs.votes x where x.record_id = r.id and x.stage = s and x.user_id = v and x.is_current)),
        'still_to_vote', count(*) filter (where rs.can_vote(p_review, r.id, s, v) and not exists (select 1 from rs.votes x where x.record_id = r.id and x.stage = s and x.user_id = v and x.is_current))),
      'team_submissions', jsonb_build_object('personal_votes_saved', (select count(*) from rs.votes x where x.review_id = p_review and x.stage = s and x.is_current),
        'votes_needed', count(*) * (select (rv.policy ->> 'reviewers_per_record')::int from rs.reviews rv where rv.id = p_review),
        'by_member', case when v_mod then (select coalesce(jsonb_agg(jsonb_build_object('member', coalesce(p.display_name, p.email), 'votes', n) order by n desc), '[]')
            from (select x.user_id, count(*) n from rs.votes x where x.review_id = p_review and x.stage = s and x.is_current group by x.user_id) q left join rs.profiles p on p.user_id = q.user_id) end),
      'final_team_dispositions', case when v_split then
          case s when 'ta' then jsonb_build_object('advanced', count(*) filter (where r.ta_status = 'advanced'), 'of_which_uncertain', count(*) filter (where r.ta_status = 'advanced' and r.ta_uncertain),
                 'excluded', count(*) filter (where r.ta_status = 'excluded'), 'awaiting_votes', count(*) filter (where r.ta_status = 'pending'), 'in_conflict', count(*) filter (where r.ta_status = 'conflict'))
               else jsonb_build_object('included', count(*) filter (where r.ft_status = 'included'), 'excluded', count(*) filter (where r.ft_status = 'excluded'),
                 'not_retrieved', count(*) filter (where r.ft_status = 'not_retrieved'), 'awaiting_votes', count(*) filter (where r.ft_status = 'pending'), 'in_conflict', count(*) filter (where r.ft_status = 'conflict')) end
        else jsonb_build_object('resolved', count(*) filter (where rs.stage_status(r, s) in ('advanced','excluded','included')),
               'unresolved', count(*) filter (where rs.stage_status(r, s) in ('pending','conflict')),
               'split_hidden', 'The split by decision is blinded for you while you screen this stage.') end,
      'unresolved_conflicts', case when v_adj then count(*) filter (where rs.stage_status(r, s) = 'conflict') end)
    into j from rs.records r where r.review_id = p_review and r.merged_into is null and (s = 'ta' or r.ta_status = 'advanced');
    v_stages := v_stages || jsonb_build_object(s, j);
  end loop;
  return rs.review_header(p_review, v) || jsonb_build_object(
    'stages', v_stages,
    'imports', jsonb_build_object('source_occurrences', (select count(*) from rs.source_occurrences o where o.review_id = p_review and not o.is_export_overlap),
      'records_after_duplicate_removal', (select count(*) from rs.records r where r.review_id = p_review and r.merged_into is null),
      'duplicates_removed', (select count(*) from rs.records r where r.review_id = p_review and r.merged_into is not null),
      'duplicate_pairs_awaiting_review', (select count(*) from rs.dedup_queue q where q.review_id = p_review and q.status = 'open')),
    'tasks', jsonb_build_object('your_pending_confirmations', (select count(*) from rs.confirmations c where c.user_id = v and c.review_id = p_review and c.used_at is null and c.cancelled_at is null and c.expires_at > now()),
      'moderator_approvals_pending', case when v_mod then (select count(*) from rs.approvals a where a.review_id = p_review and a.status = 'pending') end,
      'your_requests_pending', (select count(*) from rs.approvals a where a.review_id = p_review and a.status = 'pending' and a.requested_by = v),
      'open_tasks', (select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'kind', t.kind, 'title', t.title) order by t.id), '[]') from rs.tasks t where t.review_id = p_review and t.status = 'open')),
    'analysis_release', jsonb_build_object('status', 'not_available', 'note', 'R analyses are not part of this release of Review Studio.'),
    'note', 'One member reaching 100% of personal votes does not mean team screening is complete.');
end $$;

create function public.rs_prisma(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_ta boolean := rs.can_see_split(p_review, 'ta', v); v_ft boolean := rs.can_see_split(p_review, 'ft', v);
  n_occ bigint; n_overlap bigint; n_canon bigint; n_merged bigint; n_events bigint; n_auto bigint; n_manual bigint;
  ta_adv bigint; ta_exc bigint; ta_pend bigint; ta_conf bigint; ft_inc bigint; ft_exc bigint; ft_nr bigint; ft_pend bigint; ft_conf bigint; n_reason bigint; v_checks jsonb; v_reasons jsonb;
begin
  select count(*) filter (where not is_export_overlap), count(*) filter (where is_export_overlap) into n_occ, n_overlap from rs.source_occurrences where review_id = p_review;
  select count(*) filter (where merged_into is null), count(*) filter (where merged_into is not null),
         count(*) filter (where merged_into is null and ta_status = 'advanced'), count(*) filter (where merged_into is null and ta_status = 'excluded'),
         count(*) filter (where merged_into is null and ta_status = 'pending'), count(*) filter (where merged_into is null and ta_status = 'conflict'),
         count(*) filter (where merged_into is null and ta_status = 'advanced' and ft_status = 'included'), count(*) filter (where merged_into is null and ta_status = 'advanced' and ft_status = 'excluded'),
         count(*) filter (where merged_into is null and ta_status = 'advanced' and ft_status = 'not_retrieved'), count(*) filter (where merged_into is null and ta_status = 'advanced' and ft_status in ('pending','not_started')),
         count(*) filter (where merged_into is null and ta_status = 'advanced' and ft_status = 'conflict')
    into n_canon, n_merged, ta_adv, ta_exc, ta_pend, ta_conf, ft_inc, ft_exc, ft_nr, ft_pend, ft_conf from rs.records where review_id = p_review;
  select count(*), count(*) filter (where kind = 'auto_merge'), count(*) filter (where kind = 'manual_merge') into n_events, n_auto, n_manual
    from rs.dedup_events where review_id = p_review and undone_at is null and kind in ('auto_merge','manual_merge');
  select coalesce(jsonb_agg(jsonb_build_object('reason_id', l.id, 'code', l.code, 'label', l.label, 'reports', q.n) order by q.n desc, l.code), '[]'), coalesce(sum(q.n), 0) into v_reasons, n_reason
    from (select ft_primary_reason_id rid, count(*) n from rs.records where review_id = p_review and merged_into is null and ta_status = 'advanced' and ft_status = 'excluded' group by 1) q
    left join rs.reason_labels l on l.id = q.rid;
  v_checks := jsonb_build_array(
    jsonb_build_object('check', 'Source occurrences minus duplicates removed equals records screened', 'left', n_occ - n_merged, 'right', n_canon, 'ok', n_occ - n_merged = n_canon),
    jsonb_build_object('check', 'Each removed duplicate has exactly one active merge event (counted once)', 'left', n_merged, 'right', n_events, 'ok', n_merged = n_events),
    jsonb_build_object('check', 'Title/abstract dispositions add up to records screened', 'left', ta_adv + ta_exc + ta_pend + ta_conf, 'right', n_canon, 'ok', ta_adv + ta_exc + ta_pend + ta_conf = n_canon),
    jsonb_build_object('check', 'Full-text dispositions add up to reports sought', 'left', ft_inc + ft_exc + ft_nr + ft_pend + ft_conf, 'right', ta_adv, 'ok', ft_inc + ft_exc + ft_nr + ft_pend + ft_conf = ta_adv),
    jsonb_build_object('check', 'Full-text exclusion reasons add up to reports excluded (one primary reason each)', 'left', n_reason, 'right', ft_exc, 'ok', n_reason = ft_exc));
  return jsonb_build_object('review_id', p_review, 'template', 'PRISMA 2020 flow diagram — new review, databases and registers (draft ledger view)',
    'identification', jsonb_build_object(
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source_id', s.id, 'database_name', s.database_name, 'preset', s.preset,
          'records_identified', (select count(*) from rs.source_occurrences o where o.source_id = s.id and not o.is_export_overlap),
          'export_overlap_linked', (select count(*) from rs.source_occurrences o where o.source_id = s.id and o.is_export_overlap),
          'origin_status', (select coalesce(jsonb_agg(distinct b.origin_status), '[]') from rs.import_batches b where b.source_id = s.id and b.status = 'committed'),
          'source_reported_hits', (select sum(q.reported_hits) from rs.search_runs q where q.source_id = s.id),
          'exported_count', (select sum(q.exported_count) from rs.search_runs q where q.source_id = s.id)) order by s.id), '[]') from rs.sources s where s.review_id = p_review),
      'records_identified_total', n_occ, 'export_overlap_reconciled', n_overlap,
      'duplicates_removed', jsonb_build_object('total', n_merged, 'automatic_rule_based', n_auto, 'manual', n_manual,
        'counting_rule', 'A cluster of k occurrences of one record removes k−1. A repeated file or a repeated run is never counted again.'),
      'duplicate_pairs_awaiting_review', (select count(*) from rs.dedup_queue q where q.review_id = p_review and q.status = 'open')),
    'screening', jsonb_build_object('records_screened', n_canon,
      'title_abstract', case when v_ta then jsonb_build_object('excluded', ta_exc, 'advanced_to_full_text', ta_adv, 'awaiting_votes', ta_pend, 'in_conflict', ta_conf)
                        else jsonb_build_object('resolved', ta_adv + ta_exc, 'unresolved', ta_pend + ta_conf, 'split_hidden', 'Blinded for you while you screen this stage.') end,
      'counting_rule', 'AI suggestions, Maybe votes, missing votes and conflicts are never counted as exclusions.'),
    'full_text', case when v_ta and v_ft then jsonb_build_object('reports_sought', ta_adv, 'reports_not_retrieved', ft_nr, 'reports_assessed', ft_inc + ft_exc,
        'reports_excluded', ft_exc, 'excluded_by_primary_reason', v_reasons, 'awaiting_votes', ft_pend, 'in_conflict', ft_conf, 'reports_included', ft_inc)
      else jsonb_build_object('split_hidden', 'Blinded for you while you screen.') end,
    'is_draft', (ta_pend + ta_conf + ft_pend + ft_conf) > 0 or exists (select 1 from rs.dedup_queue q where q.review_id = p_review and q.status = 'open'),
    'validation', v_checks,
    'retrieved_at', now());
end $$;

create function public.rs_export(p_review uuid, p_kind text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_rows jsonb; rv rs.reviews;
begin
  select * into rv from rs.reviews where id = p_review;
  if p_kind = 'references' then
    select coalesce(jsonb_agg(jsonb_build_object('record_id', r.id, 'seq', r.seq, 'canonical_record_id', coalesce(r.merged_into, r.id), 'is_duplicate_removed', r.merged_into is not null,
        'title', r.title, 'authors', array_to_string(r.authors, '; '), 'year', r.year, 'journal', r.journal, 'doi', r.doi, 'pmid', r.pmid, 'ref_type', r.ref_type, 'abstract', r.abstract,
        'sources', (select string_agg(distinct s.database_name, '; ') from rs.source_occurrences o join rs.sources s on s.id = o.source_id where o.record_id = r.id),
        'source_record_ids', (select string_agg(o.src_record_id, '; ') from rs.source_occurrences o where o.record_id = r.id),
        'import_batches', (select string_agg(distinct o.batch_id::text, '; ') from rs.source_occurrences o where o.record_id = r.id)) order by r.seq), '[]')
      into v_rows from rs.records r where r.review_id = p_review;
  elsif p_kind = 'my_votes' then
    select coalesce(jsonb_agg(jsonb_build_object('vote_id', x.id, 'record_id', x.record_id, 'seq', r.seq, 'stage', x.stage, 'decision', x.decision, 'is_current', x.is_current,
        'primary_reason', (select l.label from rs.reason_labels l where l.id = x.primary_reason_id), 'reasons', (select string_agg(l.label, '; ') from rs.reason_labels l where l.id = any(x.reason_ids)),
        'note', x.note, 'protocol_version_id', x.protocol_version_id, 'ai_assisted', x.ai_assisted, 'after_unblind', x.after_unblind, 'channel', x.channel, 'saved_at', x.created_at) order by x.id), '[]')
      into v_rows from rs.votes x join rs.records r on r.id = x.record_id where x.review_id = p_review and x.user_id = v;
  elsif p_kind = 'team_votes' then
    if not (rs.can_see_split(p_review, 'ta', v) and rs.can_see_split(p_review, 'ft', v)) then
      raise exception 'Team votes can be exported only by the moderator or an adjudicator who is not blinded at either stage' using errcode = '42501', detail = 'blinded';
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('vote_id', x.id, 'record_id', x.record_id, 'seq', r.seq, 'stage', x.stage, 'reviewer', coalesce(p.display_name, p.email), 'decision', x.decision, 'is_current', x.is_current,
        'primary_reason', (select l.label from rs.reason_labels l where l.id = x.primary_reason_id), 'reasons', (select string_agg(l.label, '; ') from rs.reason_labels l where l.id = any(x.reason_ids)),
        'note', x.note, 'protocol_version_id', x.protocol_version_id, 'ai_assisted', x.ai_assisted, 'after_unblind', x.after_unblind, 'origin', x.origin, 'channel', x.channel, 'saved_at', x.created_at,
        'team_status', rs.stage_status(r, x.stage), 'final_basis', case x.stage when 'ta' then r.ta_final_basis else r.ft_final_basis end) order by x.id), '[]')
      into v_rows from rs.votes x join rs.records r on r.id = x.record_id left join rs.profiles p on p.user_id = x.user_id where x.review_id = p_review;
    perform rs.audit(p_review, 'team_votes_exported', 'review', p_review::text, '{}');
  elsif p_kind = 'criteria' then
    select coalesce(jsonb_agg(jsonb_build_object('criterion_id', c.id, 'code', c.code, 'kind', c.kind, 'stage', c.stage, 'criterion_status', c.status, 'criterion_version_id', cv.id, 'version', cv.version,
        'version_status', cv.status, 'text', cv.text, 'rationale', cv.rationale, 'activated_at', cv.activated_at) order by c.code, cv.version), '[]')
      into v_rows from rs.criteria c join rs.criterion_versions cv on cv.criterion_id = c.id where c.review_id = p_review;
  elsif p_kind = 'duplicates' then
    select coalesce(jsonb_agg(jsonb_build_object('event_id', e.id, 'kind', e.kind, 'rule', e.rule, 'kept_record_id', e.kept_record_id, 'other_record_id', e.merged_record_id, 'run_id', e.run_id, 'at', e.at, 'undone_at', e.undone_at) order by e.id), '[]')
      into v_rows from rs.dedup_events e where e.review_id = p_review;
  elsif p_kind = 'ledger' then
    v_rows := jsonb_build_array(public.rs_prisma(p_review));
  else perform rs.fail('bad_kind', 'Export kind must be references, my_votes, team_votes, criteria, duplicates or ledger');
  end if;
  return jsonb_build_object('manifest', jsonb_build_object('schema_version', (select w.schema_version from rs.workspace w), 'review_id', p_review, 'review_code', rv.code, 'review_title', rv.title,
      'is_synthetic', rv.is_synthetic, 'kind', p_kind, 'protocol_version_id', rv.active_protocol_version_id, 'generated_at', now(), 'row_count', jsonb_array_length(v_rows)), 'rows', v_rows);
end $$;

-- ---------- dispatchers ----------
create function rs.apply_approval(a rs.approvals, p_decision text, p_reason text, p_uid uuid) returns jsonb language plpgsql set search_path = '' as $$
declare p jsonb := a.payload; v_user uuid; c text; v_cv bigint; v_votes int; adj rs.adjudications; v_out jsonb := '{}';
begin
  if p_decision = 'approve' then
    if a.kind = 'membership' then
      v_user := (p ->> 'user_id')::uuid;
      insert into rs.memberships (review_id, user_id) values (a.review_id, v_user) on conflict (review_id, user_id) do update set status = 'active';
      for c in select jsonb_array_elements_text(coalesce(p -> 'capabilities', '[]')) loop
        insert into rs.grants (review_id, user_id, capability, granted_by) values (a.review_id, v_user, c, p_uid) on conflict do nothing;
      end loop;
      update rs.invitations set status = 'approved' where id = (p ->> 'invitation_id')::bigint;
    elsif a.kind = 'criterion_activation' then
      v_cv := (p ->> 'criterion_version_id')::bigint;
      update rs.criteria set status = 'active' where id = (p ->> 'criterion_id')::bigint and review_id = a.review_id;
      update rs.criterion_versions set status = 'active', activated_by = p_uid, activated_at = now(),
        protocol_version_id = (select r.active_protocol_version_id from rs.reviews r where r.id = a.review_id) where id = v_cv;
      select count(*) into v_votes from rs.votes x where x.review_id = a.review_id and x.is_current;
      update rs.ai_annotations set stale = true where review_id = a.review_id and not stale;
      insert into rs.tasks (review_id, kind, title, details, created_by)
      values (a.review_id, 'reassess_after_amendment', format('Protocol amendment: criterion %s activated — reassess affected decisions', p ->> 'code'),
        jsonb_build_object('criterion_id', p ->> 'criterion_id', 'activated_at', now(), 'votes_saved_before_amendment', v_votes, 'ai_feedback_marked_stale', true), p_uid);
      v_out := jsonb_build_object('amendment_recorded', true, 'votes_saved_before_amendment', v_votes);
    elsif a.kind = 'dedup_policy' then
      update rs.dedup_policies set status = 'superseded' where review_id = a.review_id and status = 'approved';
      update rs.dedup_policies set status = 'approved', approved_by = p_uid, approved_at = now() where id = (p ->> 'dedup_policy_id')::bigint;
      update rs.dedup_runs set status = 'stale' where review_id = a.review_id and status = 'dry_run';
    elsif a.kind = 'adjudication' then
      select * into adj from rs.adjudications where id = (p ->> 'adjudication_id')::bigint for update;
      if adj.status <> 'recommended' then perform rs.fail('adjudication_changed', 'This recommendation was superseded'); end if;
      if adj.stage = 'ta' then
        update rs.records set ta_status = case adj.resolution when 'advance' then 'advanced' else 'excluded' end, ta_uncertain = false, ta_final_basis = 'moderator_adjudication',
          ft_status = case when adj.resolution = 'advance' and ft_status = 'not_started' then 'pending' else ft_status end where id = adj.record_id;
      else
        update rs.records set ft_status = case adj.resolution when 'include' then 'included' else 'excluded' end, ft_primary_reason_id = case when adj.resolution = 'exclude' then adj.primary_reason_id end,
          ft_final_basis = 'moderator_adjudication' where id = adj.record_id;
      end if;
      update rs.adjudications set status = 'approved', decided_at = now() where id = adj.id;
    else perform rs.fail('unknown_approval_kind', format('No handler for approval kind %s', a.kind));
    end if;
  else
    if a.kind = 'membership' then update rs.invitations set status = 'declined' where id = (p ->> 'invitation_id')::bigint;
    elsif a.kind = 'criterion_activation' and p_decision = 'decline' then
      update rs.criteria set status = 'declined' where id = (p ->> 'criterion_id')::bigint;
      update rs.criterion_versions set status = 'declined' where id = (p ->> 'criterion_version_id')::bigint;
    elsif a.kind = 'dedup_policy' and p_decision = 'decline' then update rs.dedup_policies set status = 'declined' where id = (p ->> 'dedup_policy_id')::bigint;
    elsif a.kind = 'adjudication' then update rs.adjudications set status = 'declined', decided_at = now() where id = (p ->> 'adjudication_id')::bigint;
    end if;
  end if;
  update rs.approvals set status = case p_decision when 'approve' then 'approved' when 'decline' then 'declined' else 'changes_requested' end, decided_by = p_uid, decided_at = now(), decision_reason = p_reason where id = a.id;
  perform rs.audit(a.review_id, 'approval_' || p_decision, 'approval', a.id::text, jsonb_build_object('kind', a.kind));
  return jsonb_build_object('approval_id', a.id, 'kind', a.kind, 'decision', p_decision) || v_out;
end $$;

create function rs.apply_confirmation(p_action text, p jsonb, p_review uuid, p_uid uuid, p_conf uuid) returns jsonb language plpgsql set search_path = '' as $$
declare r rs.reviews; pv rs.protocol_versions; a rs.approvals; c text; x jsonb; v_token text; v_id bigint; v_user uuid; v_crit bigint; v_n int := 0;
begin
  if p_action = 'vote' then return rs.apply_vote(p, p_uid, p_conf); end if;
  if p_action = 'approval_decision' then
    perform rs.require_moderator();
    select * into a from rs.approvals where id = (p ->> 'approval_id')::bigint for update;
    if a.status <> 'pending' then perform rs.fail('not_pending', format('This request is already %s', a.status)); end if;
    if a.payload_hash <> p ->> 'approval_payload_hash' then perform rs.fail('approval_changed', 'The request changed after you reviewed it. Nothing was decided; review it again.'); end if;
    return rs.apply_approval(a, p ->> 'decision', p ->> 'reason', p_uid);
  end if;
  perform rs.require_moderator();
  if p_action = 'activate_review' then
    select * into r from rs.reviews where id = p_review for update;
    if r.status <> 'draft' or r.revision <> (p ->> 'revision')::int then perform rs.fail('review_changed', 'The draft changed after activation was prepared. Nothing was activated.'); end if;
    select * into pv from rs.protocol_versions where id = (p ->> 'protocol_version_id')::bigint and review_id = p_review;
    if pv.content_sha256 <> p ->> 'protocol_sha256' or r.policy <> p -> 'policy' or r.registration <> p -> 'registration' then perform rs.fail('review_changed', 'The draft content changed after activation was prepared.'); end if;
    update rs.protocol_versions set status = 'approved', approved_by = p_uid, approved_at = now() where id = pv.id;
    update rs.criteria set status = 'active' where review_id = p_review and status = 'proposed';
    update rs.criterion_versions set status = 'active', activated_by = p_uid, activated_at = now() where review_id = p_review and status = 'draft';
    update rs.reviews set status = 'active', active_protocol_version_id = pv.id, activated_at = now(), revision = revision + 1 where id = p_review;
    for x in select * from jsonb_array_elements(coalesce(r.handoff -> 'reasons', '[]')) loop
      select cr.id into v_crit from rs.criteria cr where cr.review_id = p_review and cr.code = x ->> 'criterion_code';
      if v_crit is not null then perform rs.make_reason_label(p_review, coalesce(x ->> 'stage', 'both'), x ->> 'label', v_crit, p_uid); v_n := v_n + 1; end if;
    end loop;
    perform rs.audit(p_review, 'review_activated', 'review', p_review::text, jsonb_build_object('protocol_version_id', pv.id, 'protocol_sha256', pv.content_sha256));
    return jsonb_build_object('review_id', p_review, 'status', 'active', 'protocol_version_id', pv.id, 'reason_labels_created', v_n);
  elsif p_action = 'create_invitation' then
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into rs.invitations (review_id, email_hint, token_hash, capabilities, created_by, expires_at)
    values (p_review, p ->> 'email_hint', encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), (select coalesce(array_agg(y), '{}') from jsonb_array_elements_text(p -> 'capabilities') y), p_uid, now() + interval '14 days')
    returning id into v_id;
    perform rs.audit(p_review, 'invitation_created', 'invitation', v_id::text, jsonb_build_object('email_hint', p ->> 'email_hint'));
    return jsonb_build_object('invitation_id', v_id, 'invite_token', v_token, 'expires_in_days', 14,
      'note', 'Send this one-time code privately to your colleague. It is shown only now. Access still needs your approval after they accept.');
  elsif p_action = 'grant_change' then
    v_user := (p ->> 'user_id')::uuid;
    for c in select jsonb_array_elements_text(p -> 'grant') loop
      insert into rs.grants (review_id, user_id, capability, granted_by) values (p_review, v_user, c, p_uid) on conflict do nothing;
    end loop;
    update rs.grants set revoked_at = now(), revoked_by = p_uid where review_id = p_review and user_id = v_user and revoked_at is null
      and (capability in (select jsonb_array_elements_text(p -> 'revoke')) or (p ->> 'remove_member')::boolean);
    if (p ->> 'remove_member')::boolean then
      if rs.is_moderator(v_user) then perform rs.fail('moderator_protected', 'The principal moderator cannot be removed'); end if;
      update rs.memberships set status = 'revoked' where review_id = p_review and user_id = v_user;
    end if;
    perform rs.audit(p_review, 'rights_changed', 'user', v_user::text, p - 'review_id');
    return jsonb_build_object('user_id', v_user, 'capabilities', (select coalesce(jsonb_agg(g.capability order by g.capability), '[]') from rs.grants g where g.review_id = p_review and g.user_id = v_user and g.revoked_at is null));
  elsif p_action = 'unblind' then
    insert into rs.unblind_events (review_id, user_id, scope, record_id, stage, reason) values (p_review, p_uid, p ->> 'scope', (p ->> 'record_id')::bigint, p ->> 'stage', p ->> 'reason') returning id into v_id;
    perform rs.audit(p_review, 'unblinded', 'review', p_review::text, p - 'review_id');
    return jsonb_build_object('unblind_event_id', v_id, 'independence_note', 'Your votes saved after this point on affected records are flagged as made after unblinding.');
  elsif p_action = 'workspace_setting' then
    if rs.channel() <> 'browser' then perform rs.fail('human_channel_required', 'This setting can be changed only from a directly signed-in browser session'); end if;
    update rs.workspace set confirmation_channel = p ->> 'confirmation_channel';
    perform rs.audit(null, 'workspace_setting_changed', 'workspace', 'confirmation_channel', p);
    return p;
  end if;
  perform rs.fail('unknown_action', format('No handler for action %s', p_action));
  return null;
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'rs\_%' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
