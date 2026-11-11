create function rs.norm_doi(p text) returns text language sql immutable set search_path = '' as $$
  select case when d like '10.%' then d end
  from (select rtrim(regexp_replace(lower(btrim(coalesce(p, ''))), '^(https?://(dx\.)?doi\.org/|doi:\s*)', ''), '. ') as d) s
$$;
create function rs.is_notice(p text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(lower(p) ~ '^\s*(erratum|correction|corrigendum|retraction|retracted|withdrawn|expression of concern|reply|comment on|author response)', false)
$$;
create function rs.is_conf(p text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(upper(p) in ('CONF','CPAPER','ABST','CONFERENCE ABSTRACT','CONFERENCE PAPER'), false)
$$;

-- ---------- sources and search history ----------
create function public.rs_add_source(p_review uuid, p_preset text, p_database_name text, p_platform text default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); v_id bigint;
begin
  if p_preset not in ('pubmed','embase','central','scopus','wos','registry','lilacs','other','unknown') then perform rs.fail('bad_preset', 'Unknown source preset'); end if;
  insert into rs.sources (review_id, preset, database_name, platform, notes, created_by)
  values (p_review, p_preset, coalesce(nullif(btrim(p_database_name), ''), p_preset), p_platform, p_notes, v) returning id into v_id;
  perform rs.audit(p_review, 'source_added', 'source', v_id::text, jsonb_build_object('preset', p_preset));
  return jsonb_build_object('status', 'saved', 'saved', true, 'source_id', v_id,
    'note', 'A source preset records where a search was run. It does not mean Review Studio ran the search or has API access to that database.');
end $$;

create function public.rs_add_search_run(p_review uuid, p_source bigint, p_run_date date, p_syntax text, p_limits text default null,
  p_reported_hits int default null, p_exported_count int default null, p_executed_by_label text default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); v_id bigint;
begin
  if not exists (select 1 from rs.sources s where s.id = p_source and s.review_id = p_review) then perform rs.fail('not_found', 'Source not found in this review'); end if;
  insert into rs.search_runs (review_id, source_id, run_date, syntax, limits, reported_hits, exported_count, executed_by_label, notes, created_by)
  values (p_review, p_source, p_run_date, p_syntax, p_limits, p_reported_hits, p_exported_count, p_executed_by_label, p_notes, v) returning id into v_id;
  perform rs.audit(p_review, 'search_run_recorded', 'search_run', v_id::text, jsonb_build_object('source_id', p_source, 'method', 'manual_external'));
  return jsonb_build_object('status', 'saved', 'saved', true, 'search_run_id', v_id, 'method', 'manual_external');
end $$;

create function public.rs_list_sources(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  return jsonb_build_object('review_id', p_review,
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source_id', s.id, 'preset', s.preset, 'database_name', s.database_name, 'platform', s.platform, 'notes', s.notes,
        'occurrences', (select count(*) from rs.source_occurrences o where o.source_id = s.id and not o.is_export_overlap),
        'export_overlaps', (select count(*) from rs.source_occurrences o where o.source_id = s.id and o.is_export_overlap),
        'search_runs', (select coalesce(jsonb_agg(jsonb_build_object('search_run_id', q.id, 'run_date', q.run_date, 'syntax', q.syntax, 'limits', q.limits,
            'reported_hits', q.reported_hits, 'exported_count', q.exported_count, 'executed_by', q.executed_by_label, 'method', q.method,
            'imported_count', (select count(*) from rs.source_occurrences o where o.search_run_id = q.id and not o.is_export_overlap)) order by q.id), '[]') from rs.search_runs q where q.source_id = s.id)) order by s.id), '[]')
      from rs.sources s where s.review_id = p_review),
    'batches', (select coalesce(jsonb_agg(jsonb_build_object('batch_id', b.id, 'filename', b.filename, 'sha256', b.sha256, 'format', b.format, 'parser_version', b.parser_version,
        'exporting_software', b.exporting_software, 'status', b.status, 'origin_status', b.origin_status, 'source_id', b.source_id, 'search_run_id', b.search_run_id,
        'parsed', b.n_parsed, 'accepted', b.n_accepted, 'rejected', b.n_rejected, 'export_overlaps', b.n_overlap, 'suggestion', b.suggestion,
        'created_at', b.created_at, 'committed_at', b.committed_at) order by b.id desc), '[]') from rs.import_batches b where b.review_id = p_review and b.status <> 'discarded'),
    'retrieved_at', now());
end $$;

-- ---------- import: begin -> add rows -> preview -> commit ----------
create function public.rs_import_begin(p_review uuid, p_meta jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); v_sha text := lower(p_meta ->> 'sha256'); v_existing bigint; v_id bigint;
begin
  if (select status from rs.reviews where id = p_review) <> 'active' then perform rs.fail('review_not_active', 'Imports need an activated review'); end if;
  if coalesce(v_sha, '') !~ '^[0-9a-f]{64}$' then perform rs.fail('bad_checksum', 'A SHA-256 checksum of the original file is required'); end if;
  select id into v_existing from rs.import_batches where review_id = p_review and sha256 = v_sha and status = 'committed';
  if v_existing is not null then
    return jsonb_build_object('status', 'duplicate_file', 'saved', false, 'existing_batch_id', v_existing,
      'message', 'This exact file was already imported into this review. Nothing was added, and no duplicates are counted for a repeated file.');
  end if;
  delete from rs.import_batches where review_id = p_review and sha256 = v_sha and status = 'preview';
  insert into rs.import_batches (review_id, filename, sha256, byte_size, format, parser_version, exporting_software, suggestion, storage_path, created_by)
  values (p_review, coalesce(p_meta ->> 'filename', 'unnamed'), v_sha, coalesce((p_meta ->> 'byte_size')::int, 0), coalesce(p_meta ->> 'format', 'ris'),
    coalesce(p_meta ->> 'parser_version', 'unknown'), p_meta ->> 'exporting_software', coalesce(p_meta -> 'suggestion', '{}'), p_meta ->> 'storage_path', v)
  returning id into v_id;
  return jsonb_build_object('status', 'preview_started', 'saved', false, 'batch_id', v_id);
end $$;

create function public.rs_import_add_rows(p_batch bigint, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare b rs.import_batches; v uuid; v_n int;
begin
  select * into b from rs.import_batches where id = p_batch;
  if not found then perform rs.fail('not_found', 'Import batch not found'); end if;
  v := rs.require_cap(b.review_id, 'import');
  if b.status <> 'preview' or b.created_by <> v then perform rs.fail('not_preview', 'Rows can be added only to your own preview batch'); end if;
  insert into rs.import_rows (batch_id, row_no, status, reject_reason, raw, parsed)
  select p_batch, (x ->> 'row_no')::int, case when x ->> 'status' = 'rejected' then 'rejected' else 'accepted' end, x ->> 'reject_reason', x ->> 'raw', coalesce(x -> 'parsed', '{}')
  from jsonb_array_elements(p_rows) x on conflict (batch_id, row_no) do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status', 'rows_staged', 'saved', false, 'rows', v_n);
end $$;

create function rs.import_overlap_count(p_batch bigint, p_source bigint) returns int language sql stable set search_path = '' as $$
  select count(*)::int from rs.import_rows r
  where r.batch_id = p_batch and r.status = 'accepted' and coalesce(r.parsed ->> 'src_record_id', '') <> ''
    and exists (select 1 from rs.source_occurrences o where o.source_id = p_source and o.src_record_id = r.parsed ->> 'src_record_id')
$$;

create function public.rs_import_preview(p_batch bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare b rs.import_batches; v uuid; v_acc int; v_rej int; v_sug text; v_match jsonb; v_status text := 'unknown'; v_conflicts jsonb := '[]';
begin
  select * into b from rs.import_batches where id = p_batch;
  if not found then perform rs.fail('not_found', 'Import batch not found'); end if;
  v := rs.require_cap(b.review_id, 'import');
  select count(*) filter (where status = 'accepted'), count(*) filter (where status = 'rejected') into v_acc, v_rej from rs.import_rows where batch_id = p_batch;
  v_sug := nullif(b.suggestion ->> 'preset', '');
  if v_sug is not null then
    v_status := 'suggested';
    select coalesce(jsonb_agg(jsonb_build_object('source_id', s.id, 'database_name', s.database_name, 'platform', s.platform,
        'search_runs', (select coalesce(jsonb_agg(jsonb_build_object('search_run_id', q.id, 'run_date', q.run_date, 'exported_count', q.exported_count, 'reported_hits', q.reported_hits,
          'export_count_matches_file', q.exported_count is not null and q.exported_count = v_acc,
          'file_overlap_with_earlier_imports', rs.import_overlap_count(p_batch, s.id)) order by q.id), '[]') from rs.search_runs q where q.source_id = s.id))), '[]')
      into v_match from rs.sources s where s.review_id = b.review_id and s.preset = v_sug;
    if v_match = '[]'::jsonb then
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object('kind', 'no_matching_search_history', 'message', format('The file looks like %s, but the search history of this review has no %s source.', v_sug, v_sug)));
      v_status := 'conflict';
    end if;
  end if;
  update rs.import_batches set n_parsed = v_acc + v_rej, n_accepted = v_acc, n_rejected = v_rej, origin_status = v_status where id = p_batch;
  return jsonb_build_object('status', 'preview', 'saved', false, 'batch_id', p_batch, 'review_id', b.review_id, 'filename', b.filename, 'sha256', b.sha256,
    'format', b.format, 'parser_version', b.parser_version, 'exporting_software', b.exporting_software,
    'counts', jsonb_build_object('parsed', v_acc + v_rej, 'accepted', v_acc, 'rejected', v_rej),
    'field_coverage', (select jsonb_build_object('title', count(*) filter (where coalesce(parsed ->> 'title', '') <> ''), 'abstract', count(*) filter (where coalesce(parsed ->> 'abstract', '') <> ''),
        'doi', count(*) filter (where coalesce(parsed ->> 'doi', '') <> ''), 'pmid', count(*) filter (where coalesce(parsed ->> 'pmid', '') <> ''),
        'year', count(*) filter (where coalesce(parsed ->> 'year', '') <> ''), 'source_record_id', count(*) filter (where coalesce(parsed ->> 'src_record_id', '') <> ''))
      from rs.import_rows where batch_id = p_batch and status = 'accepted'),
    'origin', jsonb_build_object('status', v_status, 'suggestion', b.suggestion, 'matching_sources', coalesce(v_match, '[]'), 'conflicts', v_conflicts,
      'note', 'The suggestion comes from the filename and file metadata. It is not a verified origin until a person confirms it.'),
    'sample', (select coalesce(jsonb_agg(parsed order by row_no), '[]') from (select row_no, parsed from rs.import_rows where batch_id = p_batch and status = 'accepted' order by row_no limit 5) s),
    'rejected_rows', (select coalesce(jsonb_agg(jsonb_build_object('row_no', row_no, 'reason', reject_reason, 'raw', left(raw, 300)) order by row_no), '[]') from (select * from rs.import_rows where batch_id = p_batch and status = 'rejected' order by row_no limit 25) s));
end $$;

create function public.rs_import_commit(p_batch bigint, p_source bigint, p_search_run bigint default null, p_origin_confirmed boolean default false, p_ack_overlap boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b rs.import_batches; s rs.sources; v uuid; v_sug text; v_overlap int; v_seq int; v_new int; v_origin text; r record; v_rec bigint;
begin
  select * into b from rs.import_batches where id = p_batch for update;
  if not found then perform rs.fail('not_found', 'Import batch not found'); end if;
  v := rs.require_cap(b.review_id, 'import');
  if b.status = 'committed' then
    return jsonb_build_object('status', 'already_committed', 'saved', true, 'batch_id', b.id, 'accepted', b.n_accepted, 'export_overlaps', b.n_overlap);
  end if;
  if b.status <> 'preview' then perform rs.fail('not_preview', 'This batch is not awaiting commit'); end if;
  select * into s from rs.sources where id = p_source and review_id = b.review_id;
  if not found then perform rs.fail('source_required', 'Choose a source from this review (or an explicit Unknown source) before committing'); end if;
  if p_search_run is not null and not exists (select 1 from rs.search_runs q where q.id = p_search_run and q.source_id = p_source) then
    perform rs.fail('bad_search_run', 'That search run does not belong to the chosen source');
  end if;
  v_sug := nullif(b.suggestion ->> 'preset', '');
  if s.preset = 'unknown' then v_origin := 'unknown';
  elsif coalesce(p_origin_confirmed, false) then v_origin := 'confirmed';
  elsif v_sug is not null and v_sug <> s.preset then
    perform rs.fail('origin_conflict', format('The file looks like %s but you chose a %s source. Confirm the origin explicitly, or choose the Unknown source.', v_sug, s.preset));
  else v_origin := 'suggested';
  end if;
  perform pg_advisory_xact_lock(hashtext('rs_import_' || b.review_id::text));
  v_overlap := rs.import_overlap_count(p_batch, p_source);
  if v_overlap > 0 and not coalesce(p_ack_overlap, false) then
    perform rs.fail('overlap_needs_reconciliation', format('%s rows carry a source record ID already imported from this same source (overlapping export files). Confirm to link them to the existing records; they are reported as export overlap, not as duplicates removed.', v_overlap));
  end if;
  select coalesce(max(seq), 0) into v_seq from rs.records where review_id = b.review_id;
  v_new := 0;
  for r in select * from rs.import_rows where batch_id = p_batch and status = 'accepted' order by row_no loop
    v_rec := null;
    if coalesce(r.parsed ->> 'src_record_id', '') <> '' then
      select o.record_id into v_rec from rs.source_occurrences o where o.source_id = p_source and o.src_record_id = r.parsed ->> 'src_record_id' order by o.id limit 1;
    end if;
    if v_rec is not null then
      insert into rs.source_occurrences (review_id, batch_id, row_no, source_id, search_run_id, src_record_id, record_id, is_export_overlap, raw)
      values (b.review_id, p_batch, r.row_no, p_source, p_search_run, r.parsed ->> 'src_record_id', v_rec, true, r.parsed);
    else
      v_seq := v_seq + 1; v_new := v_new + 1;
      insert into rs.records (review_id, seq, title, authors, year, journal, doi, pmid, abstract, ref_type, norm_title, norm_doi, first_author)
      values (b.review_id, v_seq, r.parsed ->> 'title',
        coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(r.parsed -> 'authors', '[]')) a), '{}'),
        case when r.parsed ->> 'year' ~ '^\d{4}$' then (r.parsed ->> 'year')::int end,
        r.parsed ->> 'journal', nullif(r.parsed ->> 'doi', ''), nullif(regexp_replace(coalesce(r.parsed ->> 'pmid', ''), '\D', '', 'g'), ''), r.parsed ->> 'abstract', r.parsed ->> 'ref_type',
        rs.norm_label(r.parsed ->> 'title'), rs.norm_doi(r.parsed ->> 'doi'),
        rs.norm_label(split_part(coalesce(r.parsed -> 'authors' ->> 0, ''), ',', 1)))
      returning id into v_rec;
      insert into rs.source_occurrences (review_id, batch_id, row_no, source_id, search_run_id, src_record_id, record_id, raw)
      values (b.review_id, p_batch, r.row_no, p_source, p_search_run, nullif(r.parsed ->> 'src_record_id', ''), v_rec, r.parsed);
    end if;
  end loop;
  update rs.import_batches set status = 'committed', source_id = p_source, search_run_id = p_search_run, origin_status = v_origin, n_overlap = v_overlap, committed_by = v, committed_at = now() where id = p_batch;
  perform rs.audit(b.review_id, 'import_committed', 'import_batch', p_batch::text, jsonb_build_object('source_id', p_source, 'new_records', v_new, 'export_overlaps', v_overlap, 'origin_status', v_origin, 'sha256', b.sha256));
  return jsonb_build_object('status', 'committed', 'saved', true, 'batch_id', p_batch, 'source_id', p_source, 'origin_status', v_origin,
    'new_records', v_new, 'export_overlaps_linked', v_overlap, 'rejected_rows', b.n_rejected);
end $$;

create function public.rs_import_discard(p_batch bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare b rs.import_batches; v uuid;
begin
  select * into b from rs.import_batches where id = p_batch;
  if not found then perform rs.fail('not_found', 'Import batch not found'); end if;
  v := rs.require_cap(b.review_id, 'import');
  if b.status <> 'preview' then perform rs.fail('not_preview', 'Only a preview batch can be discarded'); end if;
  update rs.import_batches set status = 'discarded' where id = p_batch;
  delete from rs.import_rows where batch_id = p_batch;
  return jsonb_build_object('status', 'discarded', 'saved', true);
end $$;

-- ---------- duplicates ----------
create table rs.dd_pairs (token uuid not null, a bigint not null, b bigint not null, rule text not null, auto_ok boolean not null default false, reason text, primary key (token, a, b));
create table rs.dd_comp (token uuid not null, record_id bigint not null, comp bigint not null, primary key (token, record_id));
alter table rs.dd_pairs enable row level security;
alter table rs.dd_comp enable row level security;

create function rs.default_dedup_rules() returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'auto_merge', jsonb_build_array(
      'Same DOI plus corroboration (identical normalised title, or same first author and year), with no contradiction',
      'Same PMID plus the same corroboration, with no contradiction'),
    'exact_bibliographic_without_shared_identifier', false,
    'year_tolerance', 1,
    'sent_to_review', jsonb_build_array('title match without a shared identifier','conflicting identifiers','year mismatch','correction, retraction or comment','conference abstract versus full report','identifier without corroboration','records that already have screening activity','inconsistent cluster'),
    'keep_rule', 'Keep the record with an abstract (longest), then with DOI, then with PMID, then the earliest imported')
$$;

create function rs.dedup_compute(p_review uuid, p_rules jsonb, p_token uuid) returns void language plpgsql set search_path = '' as $$
declare v_tol int := coalesce((p_rules ->> 'year_tolerance')::int, 1);
  v_rule_c boolean := coalesce((p_rules ->> 'exact_bibliographic_without_shared_identifier')::boolean, false); v_changed int;
begin
  insert into rs.dd_pairs (token, a, b, rule)
  select p_token, x.a, x.b, min(x.rule) from (
    select a.id a, b.id b, '1_same_doi' rule from rs.records a join rs.records b on b.review_id = a.review_id and b.norm_doi = a.norm_doi and b.id > a.id and b.merged_into is null
      where a.review_id = p_review and a.merged_into is null and a.norm_doi is not null
    union all
    select a.id, b.id, '2_same_pmid' from rs.records a join rs.records b on b.review_id = a.review_id and b.pmid = a.pmid and b.id > a.id and b.merged_into is null
      where a.review_id = p_review and a.merged_into is null and a.pmid is not null
    union all
    select a.id, b.id, '3_exact_title' from rs.records a join rs.records b on b.review_id = a.review_id and b.norm_title = a.norm_title and b.id > a.id and b.merged_into is null
      where a.review_id = p_review and a.merged_into is null and length(a.norm_title) >= 25) x
  group by x.a, x.b;

  update rs.dd_pairs p set reason = case
      when exists (select 1 from rs.dedup_queue q where q.review_id = p_review and q.record_a = p.a and q.record_b = p.b and q.status in ('kept_separate','companion')) then 'previously_kept_separate'
      when exists (select 1 from rs.votes v where v.record_id in (p.a, p.b) and v.is_current) then 'has_screening_activity'
      when (a.pmid is not null and b.pmid is not null and a.pmid <> b.pmid) or (a.norm_doi is not null and b.norm_doi is not null and a.norm_doi <> b.norm_doi) then 'conflicting_identifiers'
      when a.year is not null and b.year is not null and abs(a.year - b.year) > v_tol then 'year_mismatch'
      when rs.is_notice(a.title) or rs.is_notice(b.title) then 'correction_retraction_or_comment'
      when rs.is_conf(a.ref_type) <> rs.is_conf(b.ref_type) then 'conference_vs_full_report'
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

  -- A cluster merges only if every member is mutually consistent; otherwise the whole cluster goes to human review.
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

create function rs.dedup_materialize(p_review uuid, p_policy rs.dedup_policies, p_uid uuid, p_token uuid) returns bigint language plpgsql set search_path = '' as $$
declare v_run bigint; v_hash text;
begin
  perform rs.dedup_compute(p_review, p_policy.rules, p_token);
  insert into rs.dedup_runs (review_id, policy_id, status, created_by) values (p_review, p_policy.id, 'dry_run', p_uid) returning id into v_run;
  insert into rs.dedup_proposals (run_id, cluster_no, record_id, role, rule, record_revision)
  select v_run, dense_rank() over (order by c.comp), r.id,
    case when row_number() over (partition by c.comp order by (coalesce(r.abstract, '') <> '') desc, length(coalesce(r.abstract, '')) desc, (r.norm_doi is not null) desc, (r.pmid is not null) desc, r.id) = 1 then 'keep' else 'merge' end,
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

create function rs.merge_record(p_review uuid, p_keep bigint, p_merged bigint, p_kind text, p_rule text, p_run bigint, p_actor uuid) returns bigint language plpgsql set search_path = '' as $$
declare v_children bigint[]; v_event bigint;
begin
  select coalesce(array_agg(id), '{}') into v_children from rs.records where merged_into = p_merged;
  update rs.records set merged_into = p_keep, revision = revision + 1 where id = p_merged or merged_into = p_merged;
  insert into rs.dedup_events (review_id, run_id, kind, kept_record_id, merged_record_id, rule, evidence, actor)
  values (p_review, p_run, p_kind, p_keep, p_merged, p_rule, jsonb_build_object('repointed_children', to_jsonb(v_children)), p_actor) returning id into v_event;
  return v_event;
end $$;

create function public.rs_propose_dedup_policy(p_review uuid, p_exact_bibliographic boolean default false) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); v_ver int; v_id bigint; v_rules jsonb; v_payload jsonb; v_ap bigint;
begin
  select coalesce(max(version), 0) + 1 into v_ver from rs.dedup_policies where review_id = p_review;
  v_rules := rs.default_dedup_rules() || jsonb_build_object('exact_bibliographic_without_shared_identifier', coalesce(p_exact_bibliographic, false));
  insert into rs.dedup_policies (review_id, version, rules, created_by) values (p_review, v_ver, v_rules, v) returning id into v_id;
  v_payload := jsonb_build_object('dedup_policy_id', v_id, 'version', v_ver, 'rules', v_rules);
  insert into rs.approvals (review_id, kind, title, payload, payload_hash, impact, requested_by, requested_channel)
  values (p_review, 'dedup_policy', format('Duplicate-handling policy v%s', v_ver), v_payload, rs.hash(v_payload),
    jsonb_build_object('note', 'Automatic merges are reversible. Similarity scores are not used; anything short of the deterministic rules goes to human review.'), v, rs.channel())
  returning id into v_ap;
  return jsonb_build_object('status', 'awaiting_moderator_approval', 'saved', true, 'dedup_policy_id', v_id, 'version', v_ver, 'approval_id', v_ap, 'rules', v_rules);
end $$;

create function public.rs_dedup_dry_run(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_cap(p_review, 'import'); pol rs.dedup_policies; v_tok uuid := gen_random_uuid(); v_run bigint;
begin
  select * into pol from rs.dedup_policies where review_id = p_review and status = 'approved' order by version desc limit 1;
  if not found then perform rs.fail('no_approved_policy', 'Duplicate handling needs a policy version approved by the moderator first'); end if;
  perform pg_advisory_xact_lock(hashtext('rs_import_' || p_review::text));
  v_run := rs.dedup_materialize(p_review, pol, v, v_tok);
  delete from rs.dd_pairs where token = v_tok; delete from rs.dd_comp where token = v_tok;
  return (select jsonb_build_object('status', 'dry_run', 'saved', false, 'run_id', v_run, 'changed_anything', false) || summary from rs.dedup_runs where id = v_run);
end $$;

create function public.rs_dedup_apply(p_run bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare run rs.dedup_runs; pol rs.dedup_policies; v uuid; v_tok uuid := gen_random_uuid(); v_new bigint; v_new_hash text; d record; v_merged int := 0; v_queued int;
begin
  select * into run from rs.dedup_runs where id = p_run for update;
  if not found then perform rs.fail('not_found', 'Dry run not found'); end if;
  v := rs.require_cap(run.review_id, 'import');
  if run.status = 'applied' then return jsonb_build_object('status', 'already_applied', 'saved', true, 'run_id', p_run, 'removed_now', 0, 'note', 'This run was applied before. Nothing was counted again.'); end if;
  if run.status <> 'dry_run' then perform rs.fail('stale_run', 'This dry run is stale. Run a new preview.'); end if;
  select * into pol from rs.dedup_policies where id = run.policy_id;
  if pol.status <> 'approved' then perform rs.fail('policy_not_approved', 'The policy behind this preview is no longer the approved one'); end if;
  perform pg_advisory_xact_lock(hashtext('rs_import_' || run.review_id::text));
  v_new := rs.dedup_materialize(run.review_id, pol, v, v_tok);
  select summary ->> 'merge_hash' into v_new_hash from rs.dedup_runs where id = v_new;
  if v_new_hash is distinct from run.summary ->> 'merge_hash' then
    update rs.dedup_runs set status = 'stale' where id = p_run;
    delete from rs.dd_pairs where token = v_tok; delete from rs.dd_comp where token = v_tok;
    return (select jsonb_build_object('status', 'stale', 'saved', false, 'run_id', v_new, 'message', 'Records changed since the preview. Nothing was merged. Review this new preview and apply it.') || summary from rs.dedup_runs where id = v_new);
  end if;
  for d in select m.record_id merged, k.record_id keep, m.rule from rs.dedup_proposals m join rs.dedup_proposals k on k.run_id = m.run_id and k.cluster_no = m.cluster_no and k.role = 'keep'
           where m.run_id = v_new and m.role = 'merge' order by m.record_id loop
    perform rs.merge_record(run.review_id, d.keep, d.merged, 'auto_merge', d.rule, p_run, v);
    v_merged := v_merged + 1;
  end loop;
  insert into rs.dedup_queue (review_id, record_a, record_b, reason)
  select run.review_id, p.a, p.b, p.reason from rs.dd_pairs p where p.token = v_tok and not p.auto_ok and p.reason <> 'previously_kept_separate'
  on conflict (review_id, record_a, record_b) do nothing;
  get diagnostics v_queued = row_count;
  delete from rs.dedup_proposals where run_id = p_run;
  update rs.dedup_proposals set run_id = p_run where run_id = v_new;
  delete from rs.dedup_runs where id = v_new;
  update rs.dedup_runs set status = 'applied', applied_at = now(), summary = summary || jsonb_build_object('removed', v_merged, 'queued_for_review', v_queued) where id = p_run;
  delete from rs.dd_pairs where token = v_tok; delete from rs.dd_comp where token = v_tok;
  perform rs.audit(run.review_id, 'dedup_applied', 'dedup_run', p_run::text, jsonb_build_object('removed', v_merged, 'queued_for_review', v_queued, 'policy_version', pol.version));
  return jsonb_build_object('status', 'applied', 'saved', true, 'run_id', p_run, 'removed_now', v_merged, 'queued_for_review', v_queued);
end $$;

create function public.rs_dedup_undo(p_event bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare e rs.dedup_events; v uuid; v_a bigint; v_b bigint;
begin
  select * into e from rs.dedup_events where id = p_event for update;
  if not found then perform rs.fail('not_found', 'Duplicate event not found'); end if;
  v := rs.require_cap(e.review_id, 'import');
  if e.kind not in ('auto_merge','manual_merge') or e.undone_at is not null then perform rs.fail('not_undoable', 'This event is not an active merge'); end if;
  if exists (select 1 from rs.votes x where x.record_id = e.kept_record_id and x.is_current) and not rs.is_moderator(v) then
    perform rs.fail('moderator_only', 'The kept record already has screening activity; only the moderator can undo this merge');
  end if;
  update rs.records set merged_into = null, revision = revision + 1 where id = e.merged_record_id and merged_into = e.kept_record_id;
  update rs.records set merged_into = e.merged_record_id, revision = revision + 1
   where merged_into = e.kept_record_id and id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.evidence -> 'repointed_children', '[]')) x);
  update rs.dedup_events set undone_at = now(), undone_by = v where id = p_event;
  v_a := least(e.kept_record_id, e.merged_record_id); v_b := greatest(e.kept_record_id, e.merged_record_id);
  insert into rs.dedup_queue (review_id, record_a, record_b, reason, status, decided_by, decided_at)
  values (e.review_id, v_a, v_b, 'undo_of_merge', 'kept_separate', v, now())
  on conflict (review_id, record_a, record_b) do update set status = 'kept_separate', decided_by = v, decided_at = now();
  perform rs.audit(e.review_id, 'dedup_undone', 'dedup_event', p_event::text, jsonb_build_object('kept', e.kept_record_id, 'restored', e.merged_record_id));
  return jsonb_build_object('status', 'undone', 'saved', true, 'restored_record_id', e.merged_record_id, 'note', 'The pair is now marked Keep separate so automation will not merge it again.');
end $$;

create function public.rs_dedup_resolve(p_queue bigint, p_action text, p_keep bigint default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare q rs.dedup_queue; v uuid; v_merged bigint; v_event bigint; ra rs.records; rb rs.records;
begin
  select * into q from rs.dedup_queue where id = p_queue for update;
  if not found then perform rs.fail('not_found', 'Queue item not found'); end if;
  v := rs.require_cap(q.review_id, 'import');
  if q.status <> 'open' then perform rs.fail('not_open', 'This pair was already resolved'); end if;
  select * into ra from rs.records where id = q.record_a; select * into rb from rs.records where id = q.record_b;
  if p_action = 'merge' then
    if ra.merged_into is not null or rb.merged_into is not null then perform rs.fail('already_merged', 'One of these records is already merged elsewhere'); end if;
    if p_keep is null or p_keep not in (q.record_a, q.record_b) then perform rs.fail('keep_required', 'Choose which of the two records to keep'); end if;
    v_merged := case when p_keep = q.record_a then q.record_b else q.record_a end;
    if exists (select 1 from rs.votes x where x.record_id = v_merged and x.is_current) and not rs.is_moderator(v) then
      perform rs.fail('moderator_only', 'The record to be merged already has screening activity; only the moderator can merge it');
    end if;
    v_event := rs.merge_record(q.review_id, p_keep, v_merged, 'manual_merge', q.reason, null, v);
    update rs.dedup_queue set status = 'merged', decided_by = v, decided_at = now() where id = p_queue;
  elsif p_action = 'keep_separate' then
    update rs.dedup_queue set status = 'kept_separate', decided_by = v, decided_at = now() where id = p_queue;
    insert into rs.dedup_events (review_id, kind, kept_record_id, merged_record_id, rule, actor) values (q.review_id, 'keep_separate', q.record_a, q.record_b, q.reason, v) returning id into v_event;
  elsif p_action = 'link_companion' then
    update rs.dedup_queue set status = 'companion', decided_by = v, decided_at = now() where id = p_queue;
    insert into rs.record_links (review_id, record_a, record_b, kind, created_by) values (q.review_id, q.record_a, q.record_b, 'companion', v);
    insert into rs.dedup_events (review_id, kind, kept_record_id, merged_record_id, rule, actor) values (q.review_id, 'link_companion', q.record_a, q.record_b, q.reason, v) returning id into v_event;
  else perform rs.fail('bad_action', 'Action must be merge, keep_separate or link_companion');
  end if;
  perform rs.audit(q.review_id, 'dedup_resolved', 'dedup_queue', p_queue::text, jsonb_build_object('action', p_action, 'event_id', v_event));
  return jsonb_build_object('status', 'saved', 'saved', true, 'action', p_action, 'event_id', v_event);
end $$;

create function public.rs_dedup_status(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  return jsonb_build_object('review_id', p_review,
    'policy', (select jsonb_build_object('dedup_policy_id', d.id, 'version', d.version, 'status', d.status, 'rules', d.rules, 'approved_at', d.approved_at) from rs.dedup_policies d where d.review_id = p_review order by d.version desc limit 1),
    'counts', jsonb_build_object(
      'canonical_records', (select count(*) from rs.records r where r.review_id = p_review and r.merged_into is null),
      'duplicates_removed', (select count(*) from rs.records r where r.review_id = p_review and r.merged_into is not null),
      'active_merge_events', (select count(*) from rs.dedup_events e where e.review_id = p_review and e.undone_at is null and e.kind in ('auto_merge','manual_merge')),
      'open_pairs_for_review', (select count(*) from rs.dedup_queue q where q.review_id = p_review and q.status = 'open')),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('run_id', x.id, 'status', x.status, 'created_at', x.created_at, 'applied_at', x.applied_at, 'summary', x.summary - 'sample_clusters') order by x.id desc), '[]') from (select * from rs.dedup_runs where review_id = p_review order by id desc limit 10) x),
    'queue', (select coalesce(jsonb_agg(jsonb_build_object('queue_id', q.id, 'reason', q.reason,
        'a', jsonb_build_object('record_id', a.id, 'seq', a.seq, 'title', a.title, 'authors', a.authors[1:3], 'year', a.year, 'journal', a.journal, 'doi', a.doi, 'pmid', a.pmid, 'ref_type', a.ref_type, 'has_abstract', coalesce(a.abstract, '') <> ''),
        'b', jsonb_build_object('record_id', b.id, 'seq', b.seq, 'title', b.title, 'authors', b.authors[1:3], 'year', b.year, 'journal', b.journal, 'doi', b.doi, 'pmid', b.pmid, 'ref_type', b.ref_type, 'has_abstract', coalesce(b.abstract, '') <> '')) order by q.id), '[]')
      from (select * from rs.dedup_queue where review_id = p_review and status = 'open' order by id limit 100) q join rs.records a on a.id = q.record_a join rs.records b on b.id = q.record_b),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('event_id', e.id, 'kind', e.kind, 'rule', e.rule, 'kept_record_id', e.kept_record_id, 'merged_record_id', e.merged_record_id,
        'kept_title', left(k.title, 120), 'at', e.at, 'undone', e.undone_at is not null) order by e.id desc), '[]')
      from (select * from rs.dedup_events where review_id = p_review order by id desc limit 100) e join rs.records k on k.id = e.kept_record_id),
    'retrieved_at', now());
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'rs\_%' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
