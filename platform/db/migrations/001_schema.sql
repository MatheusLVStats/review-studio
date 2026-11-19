-- Review platform v1 schema. See docs/spec/platform-spec.md.
-- Rules that protect blinding and history live here so that they hold for any client.

create schema if not exists rp;
set search_path = rp, public;

create table users (
  id bigint generated always as identity primary key,
  email text not null unique check (email = lower(email) and position('@' in email) > 1),
  display_name text not null,
  password_hash text not null,
  created_at timestamptz not null default now()
);

create table sessions (
  token_sha256 text primary key,
  user_id bigint not null references users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table reviews (
  id bigint generated always as identity primary key,
  title text not null check (length(trim(title)) > 0),
  description text,
  created_by bigint not null references users(id),
  created_at timestamptz not null default now(),
  blind_mode boolean not null default true,
  ta_conflict_rule text not null default 'exclude_vs_other' check (ta_conflict_rule in ('exclude_vs_other')),
  reviewers_per_publication int not null default 2 check (reviewers_per_publication between 1 and 5),
  require_reason_ta_exclude boolean not null default false,
  require_reason_ft_exclude boolean not null default true
);

create table members (
  review_id bigint not null references reviews(id),
  user_id bigint not null references users(id),
  role text not null check (role in ('owner','lead','reviewer','viewer')),
  added_by bigint references users(id),
  added_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (review_id, user_id)
);
create unique index one_owner on members(review_id) where role = 'owner' and removed_at is null;

create table stage_state (
  review_id bigint not null references reviews(id),
  stage text not null check (stage in ('ta','ft')),
  reconciliation_open boolean not null default false,
  opened_by bigint references users(id),
  opened_at timestamptz,
  primary key (review_id, stage)
);

create table import_batches (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  filename text not null,
  format text not null check (format in ('ris','bibtex','csv')),
  file_sha256 text not null,
  file_bytes bytea not null,
  uploaded_by bigint not null references users(id),
  uploaded_at timestamptz not null default now(),
  n_entries int not null, n_ok int not null, n_warnings int not null, n_failed int not null,
  unique (review_id, file_sha256)
);

create table source_records (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  batch_id bigint not null references import_batches(id),
  ordinal int not null,
  raw_text text not null,
  fields jsonb not null,
  warnings text[] not null default '{}',
  unique (batch_id, ordinal)
);

create table publications (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  title text, abstract text, year int, doi_norm text, pmid text, journal text,
  authors text[] not null default '{}',
  kind text not null default 'journal' check (kind in ('journal','conference','registry','other')),
  merged_into bigint references publications(id),
  created_at timestamptz not null default now(),
  unique (review_id, id)
);
create index on publications(review_id, doi_norm);
create index on publications(review_id, pmid);

create table publication_sources (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  publication_id bigint not null references publications(id),
  source_record_id bigint not null references source_records(id),
  linked_at timestamptz not null default now(),
  linked_by bigint references users(id),
  link_reason text not null check (link_reason in ('import','merge','split')),
  unlinked_at timestamptz, unlinked_by bigint references users(id), unlink_reason text
);
create unique index one_current_link on publication_sources(source_record_id) where unlinked_at is null;

create table dedup_candidates (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  publication_a bigint not null references publications(id),
  publication_b bigint not null references publications(id),
  rule text not null, score numeric not null,
  blockers text[] not null default '{}',
  status text not null default 'open' check (status in ('open','merged','rejected','linked_as_study')),
  decided_by bigint references users(id), decided_at timestamptz,
  check (publication_a < publication_b),
  unique (review_id, publication_a, publication_b)
);

create table studies (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  label text not null,
  created_by bigint not null references users(id),
  created_at timestamptz not null default now()
);
create table study_publications (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  study_id bigint not null references studies(id),
  publication_id bigint not null references publications(id),
  role text not null check (role in ('primary','secondary')),
  linked_by bigint not null references users(id), linked_at timestamptz not null default now(),
  unlinked_at timestamptz, unlinked_by bigint references users(id)
);
create unique index one_current_study on study_publications(publication_id) where unlinked_at is null;

create table reason_labels (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  stage text not null check (stage in ('ta','ft','both')),
  label text not null,
  active boolean not null default true
);

create table assignments (
  review_id bigint not null references reviews(id),
  stage text not null check (stage in ('ta','ft')),
  publication_id bigint not null references publications(id),
  user_id bigint not null references users(id),
  assigned_by bigint not null references users(id),
  assigned_at timestamptz not null default now(),
  primary key (review_id, stage, publication_id, user_id)
);

create table votes (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  stage text not null check (stage in ('ta','ft')),
  publication_id bigint not null references publications(id),
  user_id bigint not null references users(id),
  decision text not null check (decision in ('include','exclude','maybe')),
  reason_id bigint references reason_labels(id),
  note text,
  created_at timestamptz not null default now(),
  supersedes_id bigint references votes(id),
  after_reveal boolean not null default false
);
create index on votes(review_id, stage, publication_id, user_id, id desc);

create table resolutions (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  stage text not null check (stage in ('ta','ft')),
  publication_id bigint not null references publications(id),
  decision text not null check (decision in ('include','exclude')),
  reason_id bigint references reason_labels(id),
  note text,
  resolved_by bigint not null references users(id),
  created_at timestamptz not null default now(),
  supersedes_id bigint references resolutions(id)
);

create table fulltext_files (
  id bigint generated always as identity primary key,
  review_id bigint not null references reviews(id),
  publication_id bigint not null references publications(id),
  sha256 text not null, filename text not null, bytes bigint not null,
  uploaded_by bigint not null references users(id),
  uploaded_at timestamptz not null default now()
);
create table retrieval (
  review_id bigint not null references reviews(id),
  publication_id bigint not null references publications(id),
  status text not null check (status in ('pending','retrieved','not_retrieved')),
  note text, updated_by bigint not null references users(id), updated_at timestamptz not null default now(),
  primary key (review_id, publication_id)
);

create table audit_log (
  id bigint generated always as identity primary key,
  review_id bigint references reviews(id),
  actor_id bigint references users(id),
  action text not null,
  entity text not null,
  entity_id bigint,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Append-only tables -------------------------------------------------------
create function forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end $$;
create trigger source_records_append_only before update or delete on source_records for each row execute function forbid_change();
create trigger votes_append_only before update or delete on votes for each row execute function forbid_change();
create trigger resolutions_append_only before update or delete on resolutions for each row execute function forbid_change();
create trigger audit_append_only before update or delete on audit_log for each row execute function forbid_change();

-- Derived views ------------------------------------------------------------
create view current_votes as
  select distinct on (review_id, stage, publication_id, user_id) *
  from votes order by review_id, stage, publication_id, user_id, id desc;

create view first_votes as
  select distinct on (review_id, stage, publication_id, user_id) *
  from votes order by review_id, stage, publication_id, user_id, id asc;

create view current_resolutions as
  select distinct on (review_id, stage, publication_id) *
  from resolutions order by review_id, stage, publication_id, id desc;

-- Status from the current votes of the assigned reviewers (spec §8).
create function pub_status(p_review bigint, p_pub bigint, p_stage text, out status text, out uncertain boolean)
language sql stable as $$
  with a as (select user_id from rp.assignments where review_id = p_review and publication_id = p_pub and stage = p_stage),
  v as (select cv.* from rp.current_votes cv join a using (user_id)
        where cv.review_id = p_review and cv.publication_id = p_pub and cv.stage = p_stage),
  c as (select (select count(*) from a) n_req, count(*) n,
               count(*) filter (where decision = 'include') n_inc,
               count(*) filter (where decision = 'exclude') n_exc,
               count(*) filter (where decision = 'maybe') n_may,
               count(distinct reason_id) filter (where decision = 'exclude') n_reasons,
               count(*) filter (where decision = 'exclude' and reason_id is null) n_exc_noreason
        from v)
  select case
           when n_req = 0 then 'unassigned'
           when n < n_req then 'pending'
           when n_exc = n then case when p_stage = 'ft' and (n_reasons > 1 or (n_reasons = 1 and n_exc_noreason > 0)) then 'conflict' else 'excluded' end
           when n_exc > 0 then 'conflict'
           when p_stage = 'ft' and n_may > 0 then 'conflict'
           else 'included' end,
         (p_stage = 'ta' and n_req > 0 and n = n_req and n_exc = 0 and n_may > 0)
  from c
$$;

create function final_decision(p_review bigint, p_pub bigint, p_stage text) returns text language sql stable as $$
  select coalesce(
    (select decision from rp.current_resolutions where review_id = p_review and publication_id = p_pub and stage = p_stage),
    (select case s.status when 'included' then 'include' when 'excluded' then 'exclude' end from rp.pub_status(p_review, p_pub, p_stage) s))
$$;

create function member_role(p_review bigint, p_user bigint) returns text language sql stable as $$
  select role from rp.members where review_id = p_review and user_id = p_user and removed_at is null
$$;

create function is_assigned(p_review bigint, p_pub bigint, p_stage text, p_user bigint) returns boolean language sql stable as $$
  select exists (select 1 from rp.assignments where review_id = p_review and publication_id = p_pub and stage = p_stage and user_id = p_user)
$$;

create function is_assigned_in_stage(p_review bigint, p_stage text, p_user bigint) returns boolean language sql stable as $$
  select exists (select 1 from rp.assignments where review_id = p_review and stage = p_stage and user_id = p_user)
$$;

create function all_voted(p_review bigint, p_pub bigint, p_stage text) returns boolean language sql stable as $$
  select exists (select 1 from rp.assignments where review_id = p_review and publication_id = p_pub and stage = p_stage)
     and not exists (
       select 1 from rp.assignments a
       where a.review_id = p_review and a.publication_id = p_pub and a.stage = p_stage
         and not exists (select 1 from rp.votes v where v.review_id = p_review and v.publication_id = p_pub and v.stage = p_stage and v.user_id = a.user_id))
$$;

-- The blinding rule (spec §7). Every response that could carry another reviewer's decision calls this.
create function can_see_others(p_review bigint, p_pub bigint, p_stage text, p_user bigint) returns boolean language sql stable as $$
  select case
    when rp.member_role(p_review, p_user) is null then false
    when not (select blind_mode from rp.reviews where id = p_review) then true
    else coalesce((select reconciliation_open from rp.stage_state where review_id = p_review and stage = p_stage), false)
         and rp.all_voted(p_review, p_pub, p_stage)
         and (rp.is_assigned(p_review, p_pub, p_stage, p_user) or rp.member_role(p_review, p_user) in ('owner','lead'))
  end
$$;

-- Votes are locked once the publication is revealed during reconciliation (spec §7).
create function votes_locked(p_review bigint, p_pub bigint, p_stage text) returns boolean language sql stable as $$
  select coalesce((select reconciliation_open from rp.stage_state where review_id = p_review and stage = p_stage), false)
     and rp.all_voted(p_review, p_pub, p_stage)
$$;

-- Team-level counts are computed only over publications for which can_see_others is true for the
-- requester (see the API's progress endpoint), so there is no separate aggregate rule to get wrong.
