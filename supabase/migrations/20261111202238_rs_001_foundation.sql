-- Review Studio foundation. All tables live in the private schema rs (no grants to API roles).
-- The only API surface is SECURITY DEFINER functions public.rs_* that check auth.uid() first.
create schema if not exists rs;
revoke all on schema rs from public, anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;

create sequence rs.review_code_seq;

create table rs.workspace (
  id boolean primary key default true check (id),
  principal_moderator uuid references auth.users(id),
  confirmation_channel text not null default 'app_or_browser' check (confirmation_channel in ('app_or_browser','browser_only')),
  schema_version text not null default '0.1.0',
  created_at timestamptz not null default now()
);
insert into rs.workspace default values;

create function rs.tg_protect_moderator() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'The workspace row cannot be deleted'; end if;
  if old.principal_moderator is not null and new.principal_moderator is distinct from old.principal_moderator
     and coalesce(current_setting('rs.infra_override', true), '') <> 'on' then
    raise exception 'The principal moderator cannot be changed through app operations' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger protect_moderator before update or delete on rs.workspace for each row execute function rs.tg_protect_moderator();

create table rs.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  locale text not null default 'en' check (locale in ('en','pt-BR')),
  created_at timestamptz not null default now()
);

create table rs.reviews (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null,
  status text not null default 'draft' check (status in ('draft','active','archived')),
  is_synthetic boolean not null default false,
  policy jsonb not null,
  policy_version int not null default 1,
  active_protocol_version_id bigint,
  registration jsonb not null default '{"status":"none"}',
  handoff jsonb not null default '{}',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  revision int not null default 1
);

create table rs.protocol_versions (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  label text not null,
  status text not null default 'draft' check (status in ('draft','approved','superseded')),
  content jsonb not null default '{}',
  source_ref text,
  content_sha256 text not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  unique (review_id, label)
);
alter table rs.reviews add constraint reviews_active_protocol_fk foreign key (active_protocol_version_id) references rs.protocol_versions(id);

create table rs.criteria (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  code text not null,
  kind text not null check (kind in ('include','exclude')),
  stage text not null default 'both' check (stage in ('ta','ft','both')),
  status text not null default 'proposed' check (status in ('proposed','active','retired','declined')),
  created_by uuid not null references auth.users(id),
  created_channel text,
  created_at timestamptz not null default now(),
  unique (review_id, code)
);
create table rs.criterion_versions (
  id bigint generated always as identity primary key,
  criterion_id bigint not null references rs.criteria(id) on delete cascade,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  version int not null,
  text text not null,
  rationale text,
  examples text,
  priority int not null default 100,
  status text not null default 'draft' check (status in ('draft','active','superseded','declined')),
  protocol_version_id bigint references rs.protocol_versions(id),
  activated_by uuid references auth.users(id),
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  unique (criterion_id, version)
);
create index criterion_versions_review_idx on rs.criterion_versions (review_id);

create table rs.reason_labels (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  code text not null,
  label text not null,
  norm_label text not null,
  stage text not null check (stage in ('ta','ft','both')),
  criterion_id bigint not null references rs.criteria(id),
  criterion_version_id bigint not null references rs.criterion_versions(id),
  status text not null default 'active' check (status in ('active','merged','retired')),
  merged_into bigint references rs.reason_labels(id),
  created_by uuid not null references auth.users(id),
  created_channel text,
  created_at timestamptz not null default now(),
  unique (review_id, code),
  unique (review_id, norm_label)
);
create index reason_labels_criterion_idx on rs.reason_labels (criterion_id);

create table rs.memberships (
  review_id uuid not null references rs.reviews(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'active' check (status in ('active','revoked')),
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);
create index memberships_user_idx on rs.memberships (user_id);

create table rs.grants (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  capability text not null check (capability in ('viewer','screen_ta','screen_ft','import','extract','check','bias','adjudicate','run_analysis')),
  granted_by uuid not null references auth.users(id),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id)
);
create unique index grants_active_uq on rs.grants (review_id, user_id, capability) where revoked_at is null;
create index grants_user_idx on rs.grants (user_id);

create table rs.invitations (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  email_hint text,
  token_hash text not null unique,
  capabilities text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','redeemed','approved','declined','revoked')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  redeemed_by uuid references auth.users(id),
  redeemed_at timestamptz
);
create index invitations_review_idx on rs.invitations (review_id);

create table rs.approvals (
  id bigint generated always as identity primary key,
  review_id uuid not null references rs.reviews(id) on delete cascade,
  kind text not null,
  title text not null,
  payload jsonb not null,
  payload_hash text not null,
  impact jsonb not null default '{}',
  evidence jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','changes_requested','declined','withdrawn','superseded')),
  requested_by uuid not null references auth.users(id),
  requested_channel text,
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_reason text
);
create index approvals_review_status_idx on rs.approvals (review_id, status);

create table rs.confirmations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  review_id uuid references rs.reviews(id) on delete cascade,
  action text not null,
  payload jsonb not null,
  payload_hash text not null,
  summary text not null,
  created_channel text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_channel text,
  cancelled_at timestamptz,
  result jsonb
);
create index confirmations_user_open_idx on rs.confirmations (user_id, review_id) where used_at is null and cancelled_at is null;

create table rs.audit_log (
  id bigint generated always as identity primary key,
  review_id uuid,
  actor uuid,
  channel text,
  action text not null,
  target_type text,
  target_id text,
  details jsonb not null default '{}',
  sensitive boolean not null default false,
  at timestamptz not null default now()
);
create index audit_review_idx on rs.audit_log (review_id, id desc);

create function rs.tg_append_only() returns trigger language plpgsql set search_path = '' as $$
begin raise exception '% is append-only', tg_table_name using errcode = '42501'; end $$;
create trigger audit_append_only before update or delete on rs.audit_log for each row execute function rs.tg_append_only();

-- ---------- helpers (private) ----------
create function rs.fail(p_code text, p_msg text) returns void language plpgsql set search_path = '' as $$
begin raise exception '%', p_msg using errcode = 'P0001', detail = p_code; end $$;

create function rs.uid() returns uuid language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Sign in to Review Studio first' using errcode = '28000', detail = 'not_authenticated'; end if;
  return v;
end $$;

create function rs.channel() returns text language sql stable set search_path = '' as $$
  select case when nullif(auth.jwt() ->> 'client_id', '') is not null then 'mcp:' || (auth.jwt() ->> 'client_id') else 'browser' end
$$;

create function rs.hash(p jsonb) returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(p::text, 'UTF8')), 'hex')
$$;

create function rs.is_moderator(p_uid uuid) returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from rs.workspace w where w.principal_moderator = p_uid)
$$;

create function rs.require_moderator() returns uuid language plpgsql stable set search_path = '' as $$
declare v uuid := rs.uid();
begin
  if not rs.is_moderator(v) then
    raise exception 'Only the principal moderator can do this' using errcode = '42501', detail = 'moderator_only';
  end if;
  return v;
end $$;

-- Same error for "no such review" and "not a member": existence is not leaked.
create function rs.require_member(p_review uuid) returns uuid language plpgsql stable set search_path = '' as $$
declare v uuid := rs.uid();
begin
  if exists (select 1 from rs.reviews r where r.id = p_review)
     and (rs.is_moderator(v) or exists (select 1 from rs.memberships m where m.review_id = p_review and m.user_id = v and m.status = 'active')) then
    return v;
  end if;
  raise exception 'You do not have access to this review' using errcode = '42501', detail = 'forbidden';
end $$;

create function rs.has_cap(p_review uuid, p_uid uuid, p_cap text) returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1 from rs.grants g join rs.memberships m on m.review_id = g.review_id and m.user_id = g.user_id
    where g.review_id = p_review and g.user_id = p_uid and g.capability = p_cap and g.revoked_at is null and m.status = 'active')
  or (p_cap in ('viewer','import','adjudicate') and rs.is_moderator(p_uid))
$$;

create function rs.require_cap(p_review uuid, p_cap text) returns uuid language plpgsql stable set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  if not rs.has_cap(p_review, v, p_cap) then
    raise exception 'This needs the "%" right, which only the moderator can grant', p_cap using errcode = '42501', detail = 'capability_required';
  end if;
  return v;
end $$;

create function rs.audit(p_review uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb default '{}', p_sensitive boolean default false)
returns void language sql set search_path = '' as $$
  insert into rs.audit_log (review_id, actor, channel, action, target_type, target_id, details, sensitive)
  values (p_review, auth.uid(), rs.channel(), p_action, p_target_type, p_target_id, coalesce(p_details, '{}'), p_sensitive)
$$;

create function rs.default_policy() returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'reviewers_per_record', 2,
    'ta_rule', jsonb_build_object('all_include','advance','include_or_maybe','advance_uncertain','all_exclude','exclude','exclude_vs_other','conflict'),
    'ta_exclude_reason_required', false,
    'ft_exclude_primary_reason_required', true,
    'blinding', 'strict',
    'reveal_peer_votes_after_all_voted', false,
    'ai_visibility', 'after_own_vote',
    'small_count_threshold', 5)
$$;

create function rs.new_confirmation(p_review uuid, p_action text, p_payload jsonb, p_summary text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_id uuid; v_hash text := rs.hash(p_payload); v_exp timestamptz := now() + interval '10 minutes';
begin
  insert into rs.confirmations (user_id, review_id, action, payload, payload_hash, summary, created_channel, expires_at)
  values (auth.uid(), p_review, p_action, p_payload, v_hash, p_summary, rs.channel(), v_exp) returning id into v_id;
  return jsonb_build_object('status','awaiting_human_confirmation','saved',false,'confirmation_id',v_id,'payload_hash',v_hash,
    'action',p_action,'summary',p_summary,'expires_at',v_exp,
    'next_step','Nothing is saved yet. The signed-in person must press Confirm in the Review Studio screen.');
end $$;

create function rs.normalize_registration(p jsonb) returns jsonb language plpgsql immutable set search_path = '' as $$
declare v_status text := coalesce(p ->> 'status', 'none');
begin
  if v_status not in ('none','drafted','submitted','confirmed') then
    perform rs.fail('bad_registration_status', 'Registration status must be none, drafted, submitted or confirmed');
  end if;
  if v_status = 'confirmed' and (coalesce(p ->> 'registration_id','') = '' or coalesce(p ->> 'evidence','') = '' or coalesce(p ->> 'confirmed_on','') = '') then
    perform rs.fail('registration_evidence_required',
      'A registration can be recorded as confirmed only with its registration ID, confirmation date and evidence (for example the registry record URL). Record it as submitted or drafted instead.');
  end if;
  return jsonb_build_object('status', v_status, 'registry', p ->> 'registry', 'registration_id', p ->> 'registration_id',
    'drafted_on', p ->> 'drafted_on', 'submitted_on', p ->> 'submitted_on', 'confirmed_on', p ->> 'confirmed_on', 'evidence', p ->> 'evidence');
end $$;

create function rs.norm_label(p text) returns text language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g'))
$$;

do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'rs' and c.relkind = 'r' loop
    execute format('alter table rs.%I enable row level security', t.relname);
  end loop;
end $$;
