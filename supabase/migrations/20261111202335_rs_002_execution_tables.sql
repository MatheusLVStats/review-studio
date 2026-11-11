create table rs.sources (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  preset text not null check (preset in ('pubmed','embase','central','scopus','wos','registry','lilacs','other','unknown')),
  database_name text not null,
  platform text,
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index sources_review_idx on rs.sources (review_id);

create table rs.search_runs (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  source_id bigint not null references rs.sources(id),
  run_date date,
  syntax text,
  limits text,
  reported_hits int,
  exported_count int,
  executed_by_label text,
  method text not null default 'manual_external' check (method in ('manual_external','app_executed')),
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index search_runs_review_idx on rs.search_runs (review_id);
create index search_runs_source_idx on rs.search_runs (source_id);

create table rs.import_batches (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  source_id bigint references rs.sources(id),
  search_run_id bigint references rs.search_runs(id),
  filename text not null,
  sha256 text not null,
  byte_size int not null,
  format text not null,
  parser_version text not null,
  exporting_software text,
  suggestion jsonb not null default '{}',
  origin_status text not null default 'unknown' check (origin_status in ('unknown','suggested','confirmed','conflict')),
  status text not null default 'preview' check (status in ('preview','committed','discarded')),
  n_parsed int not null default 0,
  n_accepted int not null default 0,
  n_rejected int not null default 0,
  n_overlap int not null default 0,
  storage_path text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  committed_by uuid references auth.users(id),
  committed_at timestamptz
);
create unique index import_batches_committed_file_uq on rs.import_batches (review_id, sha256) where status = 'committed';
create index import_batches_review_idx on rs.import_batches (review_id);

create table rs.import_rows (
  batch_id bigint not null references rs.import_batches(id) on delete cascade,
  row_no int not null,
  status text not null check (status in ('accepted','rejected')),
  reject_reason text,
  raw text,
  parsed jsonb not null default '{}',
  primary key (batch_id, row_no)
);

create table rs.records (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  seq int not null,
  title text,
  authors text[] not null default '{}',
  year int,
  journal text,
  doi text,
  pmid text,
  abstract text,
  ref_type text,
  norm_title text,
  norm_doi text,
  first_author text,
  merged_into bigint references rs.records(id),
  ta_status text not null default 'pending' check (ta_status in ('pending','advanced','excluded','conflict')),
  ta_uncertain boolean not null default false,
  ta_final_basis text,
  ft_status text not null default 'not_started' check (ft_status in ('not_started','pending','not_retrieved','included','excluded','conflict')),
  ft_primary_reason_id bigint references rs.reason_labels(id),
  ft_final_basis text,
  revision int not null default 1,
  created_at timestamptz not null default now(),
  unique (review_id, seq)
);
create index records_canonical_idx on rs.records (review_id, id) where merged_into is null;
create index records_doi_idx on rs.records (review_id, norm_doi) where norm_doi is not null;
create index records_pmid_idx on rs.records (review_id, pmid) where pmid is not null;
create index records_title_idx on rs.records (review_id, norm_title);
create index records_merged_idx on rs.records (merged_into) where merged_into is not null;

create table rs.source_occurrences (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  batch_id bigint not null references rs.import_batches(id),
  row_no int not null,
  source_id bigint not null references rs.sources(id),
  search_run_id bigint references rs.search_runs(id),
  src_record_id text,
  record_id bigint not null references rs.records(id),
  is_export_overlap boolean not null default false,
  raw jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (batch_id, row_no)
);
create index occ_review_source_idx on rs.source_occurrences (review_id, source_id);
create index occ_record_idx on rs.source_occurrences (record_id);
create index occ_srcid_idx on rs.source_occurrences (source_id, src_record_id) where src_record_id is not null;

create table rs.dedup_policies (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  version int not null,
  rules jsonb not null,
  status text not null default 'proposed' check (status in ('proposed','approved','superseded','declined')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  unique (review_id, version)
);
create table rs.dedup_runs (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  policy_id bigint not null references rs.dedup_policies(id),
  status text not null check (status in ('dry_run','applied','stale')),
  summary jsonb not null default '{}',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
create index dedup_runs_review_idx on rs.dedup_runs (review_id);
create table rs.dedup_proposals (
  run_id bigint not null references rs.dedup_runs(id) on delete cascade,
  cluster_no int not null,
  record_id bigint not null references rs.records(id),
  role text not null check (role in ('keep','merge')),
  rule text not null,
  record_revision int not null,
  primary key (run_id, record_id)
);
create table rs.dedup_events (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  run_id bigint references rs.dedup_runs(id),
  kind text not null check (kind in ('auto_merge','manual_merge','keep_separate','link_companion')),
  kept_record_id bigint not null references rs.records(id),
  merged_record_id bigint not null references rs.records(id),
  rule text,
  evidence jsonb not null default '{}',
  actor uuid references auth.users(id),
  at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references auth.users(id)
);
create index dedup_events_review_idx on rs.dedup_events (review_id);
create unique index dedup_events_active_merge_uq on rs.dedup_events (merged_record_id) where undone_at is null and kind in ('auto_merge','manual_merge');
create table rs.dedup_queue (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_a bigint not null references rs.records(id),
  record_b bigint not null references rs.records(id),
  reason text not null,
  evidence jsonb not null default '{}',
  status text not null default 'open' check (status in ('open','merged','kept_separate','companion')),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (record_a < record_b),
  unique (review_id, record_a, record_b)
);
create table rs.record_links (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_a bigint not null references rs.records(id),
  record_b bigint not null references rs.records(id),
  kind text not null default 'companion',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index record_links_review_idx on rs.record_links (review_id);

create table rs.assignments (
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_id bigint not null references rs.records(id) on delete cascade,
  stage text not null check (stage in ('ta','ft')),
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (record_id, stage, user_id)
);
create index assignments_user_idx on rs.assignments (review_id, user_id, stage);

create table rs.votes (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_id bigint not null references rs.records(id),
  stage text not null check (stage in ('ta','ft')),
  user_id uuid not null references auth.users(id),
  decision text not null check (decision in ('include','exclude','maybe')),
  reason_ids bigint[] not null default '{}',
  primary_reason_id bigint references rs.reason_labels(id),
  note text,
  protocol_version_id bigint references rs.protocol_versions(id),
  record_revision int,
  is_current boolean not null default true,
  channel text,
  ai_assisted boolean not null default false,
  confirmation_id uuid references rs.confirmations(id),
  origin text not null default 'human_confirmed' check (origin in ('human_confirmed','imported_history')),
  created_at timestamptz not null default now()
);
create unique index votes_current_uq on rs.votes (record_id, stage, user_id) where is_current;
create index votes_review_stage_idx on rs.votes (review_id, stage) where is_current;
create index votes_user_idx on rs.votes (user_id, review_id);

create function rs.tg_votes_history() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Votes are never deleted; history is preserved' using errcode = '42501'; end if;
  if (to_jsonb(new) - 'is_current') is distinct from (to_jsonb(old) - 'is_current') or (new.is_current and not old.is_current) then
    raise exception 'A saved vote cannot be edited; a new vote supersedes it' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger votes_history before update or delete on rs.votes for each row execute function rs.tg_votes_history();

create table rs.ai_annotations (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_id bigint not null references rs.records(id),
  stage text not null check (stage in ('ta','ft')),
  recommendation text not null check (recommendation in ('include','exclude','needs_information')),
  reason_label_id bigint references rs.reason_labels(id),
  criterion_version_id bigint references rs.criterion_versions(id),
  protocol_version_id bigint references rs.protocol_versions(id),
  evidence jsonb not null default '[]',
  rationale text,
  model text,
  created_by uuid not null references auth.users(id),
  channel text,
  stale boolean not null default false,
  created_at timestamptz not null default now()
);
create index ai_annotations_record_idx on rs.ai_annotations (record_id, stage);
create index ai_annotations_review_idx on rs.ai_annotations (review_id);

create table rs.adjudications (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  record_id bigint not null references rs.records(id),
  stage text not null check (stage in ('ta','ft')),
  recommended_by uuid not null references auth.users(id),
  resolution text not null check (resolution in ('advance','include','exclude')),
  primary_reason_id bigint references rs.reason_labels(id),
  rationale text,
  status text not null default 'recommended' check (status in ('recommended','approved','declined','superseded')),
  approval_id bigint references rs.approvals(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index adjudications_record_idx on rs.adjudications (record_id, stage);
create index adjudications_review_idx on rs.adjudications (review_id);

create table rs.unblind_events (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  scope text not null check (scope in ('record','review')),
  record_id bigint references rs.records(id),
  stage text not null check (stage in ('ta','ft')),
  reason text not null,
  at timestamptz not null default now()
);
create index unblind_review_user_idx on rs.unblind_events (review_id, user_id);

create table rs.tasks (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  kind text not null,
  status text not null default 'open' check (status in ('open','done','dismissed')),
  title text not null,
  details jsonb not null default '{}',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index tasks_review_idx on rs.tasks (review_id, status);

do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'rs' and c.relkind = 'r' loop
    execute format('alter table rs.%I enable row level security', t.relname);
  end loop;
end $$;

insert into storage.buckets (id, name, public) values ('rs-private', 'rs-private', false) on conflict (id) do nothing;
