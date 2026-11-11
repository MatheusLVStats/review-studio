create or replace function public.rs_queue(p_review uuid, p_stage text default 'ta', p_filter text default 'todo', p_limit int default 50, p_offset int default 0, p_search text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_split boolean := rs.can_see_split(p_review, p_stage, v); v_items jsonb; v_tot jsonb;
begin
  if p_stage not in ('ta','ft') then perform rs.fail('bad_stage', 'Stage must be ta or ft'); end if;
  if p_filter = 'conflicts' and not (rs.is_moderator(v) or rs.has_cap(p_review, v, 'adjudicate')) then
    raise exception 'Conflicts are visible to adjudicators and the moderator' using errcode = '42501', detail = 'capability_required';
  end if;
  with base as (
    select r.id, r.seq, r.title, r.authors, r.year, r.journal, r.abstract, r.ft_status,
           case when p_stage = 'ta' then r.ta_status else r.ft_status end as st,
           (select x.decision from rs.votes x where x.record_id = r.id and x.stage = p_stage and x.user_id = v and x.is_current) as my_decision,
           rs.can_vote(p_review, r.id, p_stage, v) as can_vote
    from rs.records r where r.review_id = p_review and r.merged_into is null and (p_stage = 'ta' or r.ta_status = 'advanced')),
  filtered as (
    select * from base b where (p_search is null or b.title ilike '%' || p_search || '%' or b.abstract ilike '%' || p_search || '%')
      and case p_filter when 'todo' then b.can_vote and b.my_decision is null and not (p_stage = 'ft' and b.ft_status = 'not_retrieved')
                        when 'voted' then b.my_decision is not null
                        when 'conflicts' then b.st = 'conflict' and rs.can_see_peer(p_review, b.id, p_stage, v)
                        else true end)
  select (select coalesce(jsonb_agg(jsonb_build_object('record_id', f.id, 'seq', f.seq, 'title', f.title, 'first_author', f.authors[1], 'year', f.year, 'journal', f.journal,
            'your_decision', f.my_decision, 'you_can_vote', f.can_vote, 'has_abstract', coalesce(f.abstract, '') <> '',
            'retrieval', case when p_stage = 'ft' and f.ft_status = 'not_retrieved' then 'not_retrieved' end,
            'team_status', case when v_split or rs.can_see_peer(p_review, f.id, p_stage, v) then f.st end) order by f.seq), '[]')
          from (select * from filtered order by seq limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) f),
         (select jsonb_build_object('in_this_filter', (select count(*) from filtered), 'records_at_stage', count(*), 'you_voted', count(*) filter (where my_decision is not null),
            'you_still_to_vote', count(*) filter (where can_vote and my_decision is null)) from base)
    into v_items, v_tot;
  return jsonb_build_object('review_id', p_review, 'stage', p_stage, 'filter', p_filter, 'items', v_items, 'totals', v_tot,
    'stage_meaning', case p_stage when 'ta' then 'Include at title/abstract means: advance to full-text assessment. It is not final study inclusion.' else 'Full-text decisions determine report eligibility. An exclusion needs one primary approved reason.' end,
    'retrieved_at', now());
end $$;
