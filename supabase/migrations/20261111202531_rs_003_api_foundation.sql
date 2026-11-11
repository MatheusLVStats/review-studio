create function rs.review_header(p_review uuid, p_uid uuid) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'review_id', r.id, 'code', r.code, 'title', r.title, 'status', r.status, 'is_synthetic', r.is_synthetic, 'revision', r.revision,
    'protocol', (select jsonb_build_object('protocol_version_id', p.id, 'label', p.label, 'status', p.status, 'source_ref', p.source_ref, 'content_sha256', p.content_sha256, 'approved_at', p.approved_at)
                 from rs.protocol_versions p where p.review_id = r.id and (p.id = r.active_protocol_version_id or (r.active_protocol_version_id is null and p.status = 'draft')) order by p.id desc limit 1),
    'your_role', case when rs.is_moderator(p_uid) then 'principal_moderator' else 'member' end,
    'your_capabilities', (select coalesce(jsonb_agg(g.capability order by g.capability), '[]') from rs.grants g where g.review_id = r.id and g.user_id = p_uid and g.revoked_at is null),
    'policy', r.policy, 'policy_version', r.policy_version, 'registration', r.registration,
    'retrieved_at', now())
  from rs.reviews r where r.id = p_review
$$;

create function public.rs_whoami() returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid(); v_email text; v_mod boolean;
begin
  select u.email into v_email from auth.users u where u.id = v;
  insert into rs.profiles (user_id, email, display_name) values (v, v_email, split_part(coalesce(v_email, ''), '@', 1))
  on conflict (user_id) do update set email = excluded.email;
  v_mod := rs.is_moderator(v);
  return jsonb_build_object(
    'user_id', v, 'email', v_email,
    'display_name', (select p.display_name from rs.profiles p where p.user_id = v),
    'locale', (select p.locale from rs.profiles p where p.user_id = v),
    'is_principal_moderator', v_mod, 'channel', rs.channel(),
    'workspace', (select jsonb_build_object('moderator_set', w.principal_moderator is not null, 'confirmation_channel', w.confirmation_channel, 'schema_version', w.schema_version) from rs.workspace w),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('review_id', r.id, 'code', r.code, 'title', r.title, 'status', r.status, 'is_synthetic', r.is_synthetic,
        'capabilities', (select coalesce(jsonb_agg(g.capability order by g.capability), '[]') from rs.grants g where g.review_id = r.id and g.user_id = v and g.revoked_at is null)) order by r.created_at desc)
      from rs.reviews r where v_mod or exists (select 1 from rs.memberships m where m.review_id = r.id and m.user_id = v and m.status = 'active')), '[]'),
    'retrieved_at', now());
end $$;

create function public.rs_set_profile(p_display_name text, p_locale text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid();
begin
  if p_locale not in ('en','pt-BR') then perform rs.fail('bad_locale', 'Locale must be en or pt-BR'); end if;
  update rs.profiles set display_name = coalesce(nullif(btrim(p_display_name), ''), display_name), locale = p_locale where user_id = v;
  return jsonb_build_object('status', 'saved');
end $$;

create function public.rs_create_review_draft(p_title text, p_handoff jsonb, p_synthetic boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator(); v_id uuid; v_code text; v_pv bigint; v_policy jsonb; v_reg jsonb; c jsonb; v_crit bigint; v_content jsonb; h jsonb := coalesce(p_handoff, '{}');
begin
  if coalesce(btrim(p_title), '') = '' then perform rs.fail('title_required', 'A review title is required'); end if;
  v_policy := rs.default_policy() || coalesce(h -> 'policy', '{}');
  if coalesce((v_policy ->> 'reviewers_per_record')::int, 0) < 1 then perform rs.fail('bad_policy', 'reviewers_per_record must be at least 1'); end if;
  v_reg := rs.normalize_registration(coalesce(h -> 'registration', '{"status":"none"}'));
  v_code := 'RS-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('rs.review_code_seq')::text, 3, '0');
  insert into rs.reviews (code, title, is_synthetic, policy, registration, handoff, created_by)
  values (v_code, btrim(p_title), coalesce(p_synthetic, false), v_policy, v_reg, h, v) returning id into v_id;
  insert into rs.memberships (review_id, user_id) values (v_id, v);
  v_content := coalesce(h -> 'protocol' -> 'content', '{}');
  insert into rs.protocol_versions (review_id, label, content, source_ref, content_sha256, created_by)
  values (v_id, coalesce(h -> 'protocol' ->> 'label', 'v1.0'), v_content, h -> 'protocol' ->> 'source_ref', rs.hash(v_content), v) returning id into v_pv;
  for c in select * from jsonb_array_elements(coalesce(h -> 'criteria', '[]')) loop
    if coalesce(c ->> 'code', '') = '' or coalesce(c ->> 'text', '') = '' or coalesce(c ->> 'kind', '') not in ('include','exclude') then
      perform rs.fail('bad_criterion', 'Each criterion needs code, kind (include or exclude) and text');
    end if;
    insert into rs.criteria (review_id, code, kind, stage, status, created_by, created_channel)
    values (v_id, c ->> 'code', c ->> 'kind', coalesce(c ->> 'stage', 'both'), 'proposed', v, rs.channel()) returning id into v_crit;
    insert into rs.criterion_versions (criterion_id, review_id, version, text, rationale, examples, priority, protocol_version_id)
    values (v_crit, v_id, 1, c ->> 'text', c ->> 'rationale', c ->> 'examples', coalesce((c ->> 'priority')::int, 100), v_pv);
  end loop;
  for c in select * from jsonb_array_elements(coalesce(h -> 'sources', '[]')) loop
    insert into rs.sources (review_id, preset, database_name, platform, notes, created_by)
    values (v_id, coalesce(c ->> 'preset', 'other'), coalesce(c ->> 'database_name', c ->> 'preset', 'Unnamed source'), c ->> 'platform', c ->> 'notes', v);
  end loop;
  perform rs.audit(v_id, 'review_draft_created', 'review', v_id::text, jsonb_build_object('code', v_code, 'protocol_version_id', v_pv));
  return rs.review_header(v_id, v) || jsonb_build_object('saved', true,
    'next_step', 'This is a draft handoff. Nothing is active until the moderator confirms activation in the Review Studio screen.');
end $$;

create function public.rs_get_review(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  return rs.review_header(p_review, v) || jsonb_build_object(
    'protocol_content', (select p.content from rs.protocol_versions p join rs.reviews r on r.id = p.review_id
       where r.id = p_review and (p.id = r.active_protocol_version_id or (r.active_protocol_version_id is null and p.status = 'draft')) order by p.id desc limit 1),
    'proposed_team', case when rs.is_moderator(v) then (select r.handoff -> 'team' from rs.reviews r where r.id = p_review) end,
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source_id', s.id, 'preset', s.preset, 'database_name', s.database_name, 'platform', s.platform) order by s.id), '[]') from rs.sources s where s.review_id = p_review),
    'open_tasks', (select count(*) from rs.tasks t where t.review_id = p_review and t.status = 'open'));
end $$;

create function public.rs_propose_activation(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator(); r rs.reviews; pv rs.protocol_versions; v_n int;
begin
  select * into r from rs.reviews where id = p_review;
  if not found then perform rs.fail('not_found', 'Review not found'); end if;
  if r.status <> 'draft' then perform rs.fail('not_draft', 'Only a draft review can be activated'); end if;
  select * into pv from rs.protocol_versions where review_id = p_review and status = 'draft' order by id desc limit 1;
  if not found then perform rs.fail('no_protocol', 'The draft has no protocol version'); end if;
  select count(*) into v_n from rs.criteria where review_id = p_review and status = 'proposed';
  return rs.new_confirmation(p_review, 'activate_review',
    jsonb_build_object('review_id', p_review, 'revision', r.revision, 'protocol_version_id', pv.id, 'protocol_sha256', pv.content_sha256, 'policy', r.policy, 'registration', r.registration),
    format('Activate %s "%s" with protocol %s, %s criteria, %s reviewers per record, registration status: %s', r.code, r.title, pv.label, v_n, r.policy ->> 'reviewers_per_record', r.registration ->> 'status'));
end $$;

create function public.rs_propose_invitation(p_review uuid, p_email_hint text, p_capabilities text[]) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator(); v_code text; c text;
begin
  select code into v_code from rs.reviews where id = p_review;
  if not found then perform rs.fail('not_found', 'Review not found'); end if;
  foreach c in array coalesce(p_capabilities, '{}') loop
    if c not in ('viewer','screen_ta','screen_ft','import','extract','check','bias','adjudicate','run_analysis') then perform rs.fail('bad_capability', format('Unknown right: %s', c)); end if;
  end loop;
  return rs.new_confirmation(p_review, 'create_invitation',
    jsonb_build_object('review_id', p_review, 'email_hint', p_email_hint, 'capabilities', to_jsonb(coalesce(p_capabilities, '{}'))),
    format('Create a one-time invitation to %s for %s with rights: %s', v_code, coalesce(nullif(p_email_hint, ''), 'an unnamed colleague'), array_to_string(coalesce(p_capabilities, '{}'), ', ')));
end $$;

create function public.rs_redeem_invitation(p_token text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid(); i rs.invitations; v_email text; v_payload jsonb; v_ap bigint;
begin
  select * into i from rs.invitations where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') for update;
  if not found or i.status <> 'pending' or i.expires_at < now() then
    perform rs.fail('invitation_invalid', 'This invitation is not valid, was already used, or has expired. Ask the moderator for a new one.');
  end if;
  if exists (select 1 from rs.memberships m where m.review_id = i.review_id and m.user_id = v and m.status = 'active') then
    perform rs.fail('already_member', 'You are already a member of this review');
  end if;
  select u.email into v_email from auth.users u where u.id = v;
  update rs.invitations set status = 'redeemed', redeemed_by = v, redeemed_at = now() where id = i.id;
  v_payload := jsonb_build_object('invitation_id', i.id, 'user_id', v, 'account_email', v_email, 'email_hint', i.email_hint, 'capabilities', to_jsonb(i.capabilities));
  insert into rs.approvals (review_id, kind, title, payload, payload_hash, evidence, requested_by, requested_channel)
  values (i.review_id, 'membership', format('Membership: %s accepted an invitation', coalesce(v_email, v::text)), v_payload, rs.hash(v_payload),
    jsonb_build_object('email_matches_hint', lower(coalesce(v_email, '')) = lower(coalesce(i.email_hint, '')), 'note', 'Identity is the signed-in Review Studio account that used the one-time link.'), v, rs.channel())
  returning id into v_ap;
  perform rs.audit(i.review_id, 'invitation_redeemed', 'invitation', i.id::text, jsonb_build_object('approval_id', v_ap));
  return jsonb_build_object('status', 'awaiting_moderator_approval', 'saved', true, 'approval_id', v_ap,
    'next_step', 'You accepted the invitation. You get access after the moderator approves your membership.');
end $$;

create function public.rs_propose_grant_change(p_review uuid, p_user uuid, p_grant text[], p_revoke text[], p_remove_member boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator(); v_name text; c text;
begin
  if not exists (select 1 from rs.memberships m where m.review_id = p_review and m.user_id = p_user and m.status = 'active') then
    perform rs.fail('not_member', 'That person is not an active member of this review');
  end if;
  if coalesce(p_remove_member, false) and rs.is_moderator(p_user) then perform rs.fail('moderator_protected', 'The principal moderator cannot be removed'); end if;
  foreach c in array coalesce(p_grant, '{}') || coalesce(p_revoke, '{}') loop
    if c not in ('viewer','screen_ta','screen_ft','import','extract','check','bias','adjudicate','run_analysis') then perform rs.fail('bad_capability', format('Unknown right: %s', c)); end if;
  end loop;
  select coalesce(p.display_name, p.email, p_user::text) into v_name from rs.profiles p where p.user_id = p_user;
  return rs.new_confirmation(p_review, 'grant_change',
    jsonb_build_object('review_id', p_review, 'user_id', p_user, 'grant', to_jsonb(coalesce(p_grant, '{}')), 'revoke', to_jsonb(coalesce(p_revoke, '{}')), 'remove_member', coalesce(p_remove_member, false)),
    format('Rights for %s: grant [%s], revoke [%s]%s', coalesce(v_name, p_user::text), array_to_string(coalesce(p_grant, '{}'), ', '), array_to_string(coalesce(p_revoke, '{}'), ', '),
      case when coalesce(p_remove_member, false) then ', and remove from the review' else '' end));
end $$;

create function public.rs_list_team(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  return jsonb_build_object(
    'review_id', p_review,
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'display_name', p.display_name, 'email', p.email,
        'is_principal_moderator', rs.is_moderator(m.user_id), 'is_you', m.user_id = v,
        'capabilities', (select coalesce(jsonb_agg(g.capability order by g.capability), '[]') from rs.grants g where g.review_id = p_review and g.user_id = m.user_id and g.revoked_at is null)) order by m.created_at), '[]')
      from rs.memberships m left join rs.profiles p on p.user_id = m.user_id where m.review_id = p_review and m.status = 'active'),
    'invitations', case when rs.is_moderator(v) then (select coalesce(jsonb_agg(jsonb_build_object('invitation_id', i.id, 'email_hint', i.email_hint, 'capabilities', i.capabilities, 'status', i.status, 'expires_at', i.expires_at) order by i.id desc), '[]') from rs.invitations i where i.review_id = p_review) end,
    'retrieved_at', now());
end $$;

create function public.rs_propose_criterion(p_review uuid, p_kind text, p_stage text, p_text text, p_rationale text default null, p_examples text default null, p_priority int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_crit bigint; v_ver bigint; v_code text; v_payload jsonb; v_ap bigint; v_votes int;
begin
  if p_kind not in ('include','exclude') or p_stage not in ('ta','ft','both') or coalesce(btrim(p_text), '') = '' then
    perform rs.fail('bad_criterion', 'A criterion needs kind (include/exclude), stage (ta/ft/both) and text');
  end if;
  v_code := upper(left(p_kind, 1)) || 'P' || ((select count(*) from rs.criteria c where c.review_id = p_review) + 1)::text;
  insert into rs.criteria (review_id, code, kind, stage, status, created_by, created_channel) values (p_review, v_code, p_kind, p_stage, 'proposed', v, rs.channel()) returning id into v_crit;
  insert into rs.criterion_versions (criterion_id, review_id, version, text, rationale, examples, priority) values (v_crit, p_review, 1, btrim(p_text), p_rationale, p_examples, coalesce(p_priority, 100)) returning id into v_ver;
  select count(*) into v_votes from rs.votes x where x.review_id = p_review and x.is_current;
  v_payload := jsonb_build_object('criterion_id', v_crit, 'criterion_version_id', v_ver, 'code', v_code, 'kind', p_kind, 'stage', p_stage, 'text', btrim(p_text), 'rationale', p_rationale);
  insert into rs.approvals (review_id, kind, title, payload, payload_hash, impact, requested_by, requested_channel)
  values (p_review, 'criterion_activation', format('New %s criterion proposed: %s', p_kind, left(btrim(p_text), 80)), v_payload, rs.hash(v_payload),
    jsonb_build_object('current_votes_in_review', v_votes, 'note', 'Activating a new eligibility criterion is a protocol amendment. Decisions already saved must be reassessed against it.'), v, rs.channel())
  returning id into v_ap;
  perform rs.audit(p_review, 'criterion_proposed', 'criterion', v_crit::text, jsonb_build_object('approval_id', v_ap));
  return jsonb_build_object('status', 'proposed_inactive', 'saved', true, 'criterion_id', v_crit, 'code', v_code, 'approval_id', v_ap,
    'next_step', 'This criterion is a draft. It does not affect eligibility until the moderator activates it.');
end $$;

create function public.rs_list_criteria(p_review uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  return jsonb_build_object(
    'review_id', p_review,
    'criteria', (select coalesce(jsonb_agg(jsonb_build_object('criterion_id', c.id, 'code', c.code, 'kind', c.kind, 'stage', c.stage, 'status', c.status,
        'criterion_version_id', cv.id, 'version', cv.version, 'text', cv.text, 'rationale', cv.rationale, 'examples', cv.examples, 'priority', cv.priority,
        'is_active', c.status = 'active' and cv.status = 'active') order by (c.status = 'active') desc, cv.priority, c.code), '[]')
      from rs.criteria c join lateral (select * from rs.criterion_versions x where x.criterion_id = c.id order by (x.status = 'active') desc, x.version desc limit 1) cv on true
      where c.review_id = p_review and c.status in ('active','proposed')),
    'reason_labels', (select coalesce(jsonb_agg(jsonb_build_object('reason_id', l.id, 'code', l.code, 'label', l.label, 'stage', l.stage,
        'criterion_id', l.criterion_id, 'criterion_code', c.code, 'criterion_version_id', l.criterion_version_id) order by l.code), '[]')
      from rs.reason_labels l join rs.criteria c on c.id = l.criterion_id where l.review_id = p_review and l.status = 'active'),
    'retrieved_at', now());
end $$;

create function rs.make_reason_label(p_review uuid, p_stage text, p_label text, p_criterion bigint, p_uid uuid) returns jsonb language plpgsql set search_path = '' as $$
declare v_norm text := rs.norm_label(p_label); l rs.reason_labels; v_cv bigint; v_id bigint;
begin
  if v_norm = '' then perform rs.fail('label_required', 'A reason label needs text'); end if;
  if p_stage not in ('ta','ft','both') then perform rs.fail('bad_stage', 'Stage must be ta, ft or both'); end if;
  select * into l from rs.reason_labels where review_id = p_review and norm_label = v_norm;
  if found then
    if l.status = 'merged' then select * into l from rs.reason_labels where id = l.merged_into; end if;
    return jsonb_build_object('status', 'reused_existing', 'saved', true, 'reason_id', l.id, 'code', l.code, 'label', l.label, 'criterion_version_id', l.criterion_version_id);
  end if;
  select cv.id into v_cv from rs.criteria c join rs.criterion_versions cv on cv.criterion_id = c.id and cv.status = 'active'
  where c.id = p_criterion and c.review_id = p_review and c.status = 'active';
  if v_cv is null then
    perform rs.fail('criterion_not_active', 'A reason label must point to an active approved criterion. If the rule is not in the protocol, propose a new criterion instead; it stays a draft until the moderator activates it.');
  end if;
  insert into rs.reason_labels (review_id, code, label, norm_label, stage, criterion_id, criterion_version_id, created_by, created_channel)
  values (p_review, 'R' || ((select count(*) from rs.reason_labels x where x.review_id = p_review) + 1)::text, btrim(p_label), v_norm, p_stage, p_criterion, v_cv, p_uid, rs.channel())
  returning id into v_id;
  perform rs.audit(p_review, 'reason_label_created', 'reason_label', v_id::text, jsonb_build_object('criterion_id', p_criterion));
  return (select jsonb_build_object('status', 'created', 'saved', true, 'reason_id', x.id, 'code', x.code, 'label', x.label, 'criterion_version_id', x.criterion_version_id) from rs.reason_labels x where x.id = v_id);
end $$;

create function public.rs_create_reason_label(p_review uuid, p_stage text, p_label text, p_criterion_id bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review);
begin
  if not (rs.has_cap(p_review, v, 'screen_ta') or rs.has_cap(p_review, v, 'screen_ft') or rs.has_cap(p_review, v, 'adjudicate')) then
    raise exception 'Creating reason labels needs a screening or adjudication right' using errcode = '42501', detail = 'capability_required';
  end if;
  return rs.make_reason_label(p_review, p_stage, p_label, p_criterion_id, v);
end $$;

create function public.rs_list_approvals(p_review uuid, p_status text default 'pending') returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_mod boolean := rs.is_moderator(v);
begin
  return jsonb_build_object('review_id', p_review, 'you_can_decide', v_mod,
    'approvals', (select coalesce(jsonb_agg(jsonb_build_object('approval_id', a.id, 'kind', a.kind, 'title', a.title, 'status', a.status,
        'payload', a.payload, 'payload_hash', a.payload_hash, 'impact', a.impact, 'evidence', a.evidence,
        'requested_by', coalesce(p.display_name, p.email), 'requested_channel', a.requested_channel, 'requested_at', a.requested_at,
        'decided_at', a.decided_at, 'decision_reason', a.decision_reason) order by a.id desc), '[]')
      from rs.approvals a left join rs.profiles p on p.user_id = a.requested_by
      where a.review_id = p_review and (p_status = 'all' or a.status = p_status) and (v_mod or a.requested_by = v)),
    'retrieved_at', now());
end $$;

create function public.rs_propose_approval_decision(p_approval bigint, p_decision text, p_reason text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_moderator(); a rs.approvals;
begin
  select * into a from rs.approvals where id = p_approval;
  if not found then perform rs.fail('not_found', 'Approval request not found'); end if;
  if a.status <> 'pending' then perform rs.fail('not_pending', format('This request is already %s', a.status)); end if;
  if p_decision not in ('approve','request_changes','decline') then perform rs.fail('bad_decision', 'Decision must be approve, request_changes or decline'); end if;
  if p_decision <> 'approve' and coalesce(btrim(p_reason), '') = '' then perform rs.fail('reason_required', 'Give a reason when declining or requesting changes'); end if;
  return rs.new_confirmation(a.review_id, 'approval_decision',
    jsonb_build_object('approval_id', a.id, 'decision', p_decision, 'reason', p_reason, 'approval_payload_hash', a.payload_hash),
    format('%s request #%s: %s', initcap(replace(p_decision, '_', ' ')), a.id, a.title));
end $$;

create function public.rs_pending_confirmations(p_review uuid default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid();
begin
  return jsonb_build_object('confirmations', (select coalesce(jsonb_agg(jsonb_build_object('confirmation_id', c.id, 'review_id', c.review_id, 'action', c.action,
      'summary', c.summary, 'payload', c.payload, 'payload_hash', c.payload_hash, 'created_channel', c.created_channel, 'created_at', c.created_at, 'expires_at', c.expires_at) order by c.created_at), '[]')
    from rs.confirmations c where c.user_id = v and c.used_at is null and c.cancelled_at is null and c.expires_at > now() and (p_review is null or c.review_id = p_review)),
    'retrieved_at', now());
end $$;

create function public.rs_cancel_confirmation(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid();
begin
  update rs.confirmations set cancelled_at = now() where id = p_id and user_id = v and used_at is null and cancelled_at is null;
  return jsonb_build_object('status', case when found then 'cancelled' else 'not_found' end, 'saved', false);
end $$;

create function public.rs_confirm(p_id uuid, p_payload_hash text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.uid(); c rs.confirmations; v_res jsonb; v_mode text;
begin
  select * into c from rs.confirmations where id = p_id for update;
  if not found or c.user_id <> v then perform rs.fail('confirmation_not_found', 'No such confirmation for the signed-in person'); end if;
  if c.used_at is not null then return jsonb_build_object('status', 'saved', 'saved', true, 'replayed', true, 'action', c.action, 'result', c.result); end if;
  if c.cancelled_at is not null then perform rs.fail('confirmation_cancelled', 'This confirmation was cancelled'); end if;
  if c.expires_at < now() then perform rs.fail('confirmation_expired', 'This confirmation expired. Nothing was saved; prepare it again.'); end if;
  if c.payload_hash is distinct from p_payload_hash then perform rs.fail('payload_mismatch', 'The content shown does not match the prepared request. Nothing was saved.'); end if;
  select w.confirmation_channel into v_mode from rs.workspace w;
  if v_mode = 'browser_only' and rs.channel() <> 'browser' then
    perform rs.fail('human_channel_required', 'This workspace accepts confirmations only from a directly signed-in Review Studio browser session.');
  end if;
  v_res := rs.apply_confirmation(c.action, c.payload, c.review_id, v, c.id);
  update rs.confirmations set used_at = now(), used_channel = rs.channel(), result = v_res - 'invite_token' where id = p_id;
  return jsonb_build_object('status', 'saved', 'saved', true, 'action', c.action, 'result', v_res);
end $$;

create function public.rs_audit(p_review uuid, p_limit int default 100, p_before bigint default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := rs.require_member(p_review); v_mod boolean := rs.is_moderator(v);
begin
  return jsonb_build_object('review_id', p_review, 'events', (select coalesce(jsonb_agg(e order by (e ->> 'id')::bigint desc), '[]') from (
    select jsonb_build_object('id', a.id, 'at', a.at, 'actor', coalesce(p.display_name, p.email), 'channel', a.channel, 'action', a.action,
      'target_type', a.target_type, 'target_id', a.target_id, 'details', a.details) as e
    from rs.audit_log a left join rs.profiles p on p.user_id = a.actor
    where a.review_id = p_review and (p_before is null or a.id < p_before) and (not a.sensitive or a.actor = v)
      and (v_mod or a.actor = v or a.action not like 'vote%')
    order by a.id desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) s), 'retrieved_at', now());
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'rs\_%' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
