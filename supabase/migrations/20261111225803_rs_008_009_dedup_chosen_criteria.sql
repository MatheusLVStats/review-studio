-- Duplicate rules the person chooses: which fields must match exactly, and which database's version to keep.
-- Every chosen field must match. Records with decisions, conflicting DOI/PMID, corrections and conference-vs-article pairs still go to a person.
--
-- This file is the final state of two migrations applied to the project on 2026-11-11:
--   20261111225513 rs_008_dedup_chosen_criteria  (its rs.dedup_compute had a malformed UNION branch and was never run)
--   20261111225803 rs_009_dedup_compute_fix      (replaced rs.dedup_compute; the version below)

create or replace function public.rs_propose_dedup_rules(p_review uuid, p_options jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); v_ver int; v_id bigint; v_rules jsonb; v_payload jsonb; v_ap bigint;
  v_f text[] := coalesce((select array_agg(distinct x) from jsonb_array_elements_text(coalesce(p_options -> 'match_fields', '[]')) x), '{}');
  v_ident boolean := coalesce((p_options ->> 'identifier_rules')::boolean, true); v_keep bigint := (p_options ->> 'keep_source_id')::bigint; v_auto jsonb := '[]'; v_keep_name text;
begin
  if exists (select 1 from unnest(v_f) x where x not in ('title','authors','year','journal','pages','doi','type')) then perform rs.fail('bad_field', 'Fields can be: title, authors, year, journal, pages, doi, type'); end if;
  if cardinality(v_f) > 0 and not ('title' = any(v_f) or 'doi' = any(v_f)) then
    perform rs.fail('title_or_doi_required', 'Choose Title or DOI among the fields that must match. Without one of them, different papers from the same year or journal would be removed as duplicates.');
  end if;
  if cardinality(v_f) = 0 and not v_ident then perform rs.fail('no_rule', 'Choose at least one rule'); end if;
  if v_keep is not null then
    select s.database_name into v_keep_name from rs.sources s where s.id = v_keep and s.review_id = p_review;
    if v_keep_name is null then perform rs.fail('not_found', 'That database is not part of this review'); end if;
  end if;
  if v_ident then v_auto := v_auto || (rs.default_dedup_rules() -> 'auto_merge'); end if;
  if cardinality(v_f) > 0 then v_auto := v_auto || jsonb_build_array('All of these match exactly: ' || array_to_string(v_f, ', ')); end if;
  select coalesce(max(version), 0) + 1 into v_ver from rs.dedup_policies where review_id = p_review;
  v_rules := rs.default_dedup_rules() || jsonb_build_object('auto_merge', v_auto, 'match_fields', to_jsonb(v_f), 'identifier_rules', v_ident, 'keep_source_id', v_keep,
    'keep_rule', case when v_keep_name is not null then 'Keep the version from ' || v_keep_name || ' when there is one; otherwise the record with an abstract, then DOI, then PMID' else rs.default_dedup_rules() ->> 'keep_rule' end);
  insert into rs.dedup_policies (review_id, version, rules, created_by) values (p_review, v_ver, v_rules, v) returning id into v_id;
  v_payload := jsonb_build_object('dedup_policy_id', v_id, 'version', v_ver, 'rules', v_rules);
  insert into rs.approvals (review_id, kind, title, payload, payload_hash, impact, requested_by, requested_channel)
  values (p_review, 'dedup_policy', format('Duplicate rules v%s', v_ver), v_payload, rs.hash(v_payload),
    jsonb_build_object('note', 'Removals are reversible. Similarity scores are not used; anything that does not match exactly goes to a person.'), v, rs.channel())
  returning id into v_ap;
  return jsonb_build_object('status', 'awaiting_moderator_approval', 'saved', true, 'dedup_policy_id', v_id, 'version', v_ver, 'approval_id', v_ap, 'rules', v_rules);
end $$;
revoke all on function public.rs_propose_dedup_rules(uuid, jsonb) from public, anon;
grant execute on function public.rs_propose_dedup_rules(uuid, jsonb) to authenticated;

create or replace function rs.dedup_compute(p_review uuid, p_rules jsonb, p_token uuid) returns void language plpgsql set search_path = '' as $$
declare v_tol int := coalesce((p_rules ->> 'year_tolerance')::int, 1);
  v_rule_c boolean := coalesce((p_rules ->> 'exact_bibliographic_without_shared_identifier')::boolean, false);
  v_ident boolean := coalesce((p_rules ->> 'identifier_rules')::boolean, true);
  v_f text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_rules -> 'match_fields', '[]')) x), '{}'); v_changed int;
begin
  insert into rs.dd_pairs (token, a, b, rule)
  select p_token, x.a, x.b, min(x.rule) from (
    select a.id a, b.id b, '1_same_doi' rule from rs.records a join rs.records b on b.review_id = a.review_id and b.norm_doi = a.norm_doi and b.id > a.id and b.merged_into is null
      where v_ident and a.review_id = p_review and a.merged_into is null and a.norm_doi is not null
    union all
    select a.id, b.id, '2_same_pmid' from rs.records a join rs.records b on b.review_id = a.review_id and b.pmid = a.pmid and b.id > a.id and b.merged_into is null
      where v_ident and a.review_id = p_review and a.merged_into is null and a.pmid is not null
    union all
    select a.id, b.id, '3_exact_title' from rs.records a join rs.records b on b.review_id = a.review_id and b.norm_title = a.norm_title and b.id > a.id and b.merged_into is null
      where a.review_id = p_review and a.merged_into is null and length(a.norm_title) >= 25
    ) x
  group by x.a, x.b;

  if cardinality(v_f) > 0 then
    insert into rs.dd_pairs (token, a, b, rule)
    with keyed as (
      select r.id, case when ('title' = any(v_f) and r.norm_title = '') or ('doi' = any(v_f) and r.norm_doi is null) or ('year' = any(v_f) and r.year is null)
          or ('authors' = any(v_f) and cardinality(r.authors) = 0) or ('journal' = any(v_f) and rs.norm_label(r.journal) = '')
          or ('type' = any(v_f) and coalesce(r.ref_type, '') = '') or ('pages' = any(v_f) and pg.pages is null) then null
        else concat_ws('|', case when 'title' = any(v_f) then r.norm_title end, case when 'doi' = any(v_f) then r.norm_doi end, case when 'year' = any(v_f) then r.year::text end,
          case when 'authors' = any(v_f) then rs.norm_label(array_to_string(r.authors, ' ')) end, case when 'journal' = any(v_f) then rs.norm_label(r.journal) end,
          case when 'type' = any(v_f) then upper(r.ref_type) end, case when 'pages' = any(v_f) then pg.pages end) end as k
      from rs.records r left join lateral (select nullif(rs.norm_label(o.raw ->> 'pages'), '') pages from rs.source_occurrences o where o.record_id = r.id order by o.id limit 1) pg on true
      where r.review_id = p_review and r.merged_into is null)
    select p_token, a.id, b.id, '0_chosen_fields' from keyed a join keyed b on b.k = a.k and b.id > a.id where a.k is not null
    on conflict (token, a, b) do update set rule = '0_chosen_fields';
  end if;

  update rs.dd_pairs p set reason = case
      when exists (select 1 from rs.dedup_queue q where q.review_id = p_review and q.record_a = p.a and q.record_b = p.b and q.status in ('kept_separate','companion')) then 'previously_kept_separate'
      when exists (select 1 from rs.votes v where v.record_id in (p.a, p.b) and v.is_current) then 'has_screening_activity'
      when (a.pmid is not null and b.pmid is not null and a.pmid <> b.pmid) or (a.norm_doi is not null and b.norm_doi is not null and a.norm_doi <> b.norm_doi) then 'conflicting_identifiers'
      when a.year is not null and b.year is not null and abs(a.year - b.year) > v_tol then 'year_mismatch'
      when rs.is_notice(a.title) or rs.is_notice(b.title) then 'correction_retraction_or_comment'
      when rs.is_conf(a.ref_type) <> rs.is_conf(b.ref_type) then 'conference_vs_full_report'
      when p.rule = '0_chosen_fields' then null
      when p.rule in ('1_same_doi','2_same_pmid') and not ((a.norm_title <> '' and a.norm_title = b.norm_title)
           or (a.first_author <> '' and a.first_author = b.first_author and a.year is not null and a.year = b.year)) then 'identifier_without_corroboration'
      when p.rule = '3_exact_title' and not (v_rule_c and a.first_author <> '' and a.first_author = b.first_author and a.year is not null and a.year = b.year
           and rs.norm_label(a.journal) <> '' and rs.norm_label(a.journal) = rs.norm_label(b.journal)) then 'title_match_no_shared_identifier'
      else null end
  from rs.records a, rs.records b where p.token = p_token and a.id = p.a and b.id = p.b;
  update rs.dd_pairs set auto_ok = (reason is null) where token = p_token;

  insert into rs.dd_comp (token, record_id, comp)
  select p_token, x, x from (select a x from rs.dd_pairs where token = p_token and auto_ok union select b from rs.dd_pairs where token = p_token and auto_ok) s;
  loop
    update rs.dd_comp c set comp = m.mn from (
      select c1.record_id, min(least(c1.comp, c2.comp)) mn
      from rs.dd_pairs p join rs.dd_comp c1 on c1.token = p_token and c1.record_id in (p.a, p.b) join rs.dd_comp c2 on c2.token = p_token and c2.record_id in (p.a, p.b)
      where p.token = p_token and p.auto_ok group by c1.record_id) m
    where c.token = p_token and c.record_id = m.record_id and m.mn < c.comp;
    get diagnostics v_changed = row_count;
    exit when v_changed = 0;
  end loop;

  with bad as (
    select c.comp from rs.dd_comp c join rs.records r on r.id = c.record_id where c.token = p_token group by c.comp
    having count(distinct r.norm_doi) > 1 or count(distinct r.pmid) > 1 or max(r.year) - min(r.year) > v_tol
    union
    select c1.comp from rs.dd_pairs p join rs.dd_comp c1 on c1.token = p_token and c1.record_id = p.a join rs.dd_comp c2 on c2.token = p_token and c2.record_id = p.b
    where p.token = p_token and not p.auto_ok and c1.comp = c2.comp
    union
    select c1.comp from rs.dedup_queue q join rs.dd_comp c1 on c1.token = p_token and c1.record_id = q.record_a join rs.dd_comp c2 on c2.token = p_token and c2.record_id = q.record_b
    where q.review_id = p_review and q.status in ('kept_separate','companion') and c1.comp = c2.comp),
  upd as (update rs.dd_pairs p set auto_ok = false, reason = 'inconsistent_cluster' from rs.dd_comp c
          where p.token = p_token and p.auto_ok and c.token = p_token and c.record_id = p.a and c.comp in (select comp from bad) returning 1)
  delete from rs.dd_comp c where c.token = p_token and c.comp in (select comp from bad);
end $$;

create or replace function rs.dedup_materialize(p_review uuid, p_policy rs.dedup_policies, p_uid uuid, p_token uuid) returns bigint language plpgsql set search_path = '' as $$
declare v_run bigint; v_hash text; v_keep bigint := (p_policy.rules ->> 'keep_source_id')::bigint;
begin
  perform rs.dedup_compute(p_review, p_policy.rules, p_token);
  insert into rs.dedup_runs (review_id, policy_id, status, created_by) values (p_review, p_policy.id, 'dry_run', p_uid) returning id into v_run;
  insert into rs.dedup_proposals (run_id, cluster_no, record_id, role, rule, record_revision)
  select v_run, dense_rank() over (order by c.comp), r.id,
    case when row_number() over (partition by c.comp order by
        (v_keep is not null and exists (select 1 from rs.source_occurrences o where o.record_id = r.id and o.source_id = v_keep)) desc,
        (coalesce(r.abstract, '') <> '') desc, length(coalesce(r.abstract, '')) desc, (r.norm_doi is not null) desc, (r.pmid is not null) desc, r.id) = 1 then 'keep' else 'merge' end,
    coalesce((select substr(min(p.rule), 3) from rs.dd_pairs p where p.token = p_token and p.auto_ok and r.id in (p.a, p.b)), 'same_doi'), r.revision
  from rs.dd_comp c join rs.records r on r.id = c.record_id where c.token = p_token;
  select md5(coalesce(string_agg(cluster_no || ':' || record_id || ':' || role, ',' order by record_id), '')) into v_hash from rs.dedup_proposals where run_id = v_run;
  update rs.dedup_runs set summary = jsonb_build_object(
    'policy_version', p_policy.version, 'merge_hash', v_hash,
    'clusters', (select count(distinct cluster_no) from rs.dedup_proposals where run_id = v_run),
    'records_to_remove', (select count(*) from rs.dedup_proposals where run_id = v_run and role = 'merge'),
    'pairs_for_human_review', (select coalesce(jsonb_object_agg(reason, n), '{}') from (select reason, count(*) n from rs.dd_pairs p where p.token = p_token and not p.auto_ok and reason <> 'previously_kept_separate'
        and not exists (select 1 from rs.dedup_queue q where q.review_id = p_review and q.record_a = p.a and q.record_b = p.b) group by reason) s),
    'sample_clusters', (select coalesce(jsonb_agg(x), '[]') from (select jsonb_build_object('cluster', d.cluster_no, 'rule', min(d.rule),
        'records', jsonb_agg(jsonb_build_object('record_id', r.id, 'seq', r.seq, 'role', d.role, 'title', left(r.title, 140), 'year', r.year, 'doi', r.doi, 'pmid', r.pmid,
          'sources', (select coalesce(jsonb_agg(distinct s.database_name), '[]') from rs.source_occurrences o join rs.sources s on s.id = o.source_id where o.record_id = r.id)) order by d.role, r.id)) x
      from rs.dedup_proposals d join rs.records r on r.id = d.record_id where d.run_id = v_run and d.cluster_no <= 15 group by d.cluster_no order by d.cluster_no) s))
  where id = v_run;
  return v_run;
end $$;
