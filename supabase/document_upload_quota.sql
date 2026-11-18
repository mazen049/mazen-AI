-- NEXORA AI: Free document upload quota (5 files per Riyadh day)
-- Run once in Supabase SQL Editor.

create table if not exists public.document_upload_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null,
  used integer not null default 0 check (used >= 0 and used <= 5),
  updated_at timestamptz not null default now(),
  primary key (user_id, usage_date)
);

alter table public.document_upload_usage enable row level security;

create or replace function public.consume_document_daily_limit(p_user_id uuid)
returns table(allowed boolean, used integer, remaining integer, is_pro boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan text;
  v_expiry timestamptz;
  v_today date := (now() at time zone 'Asia/Riyadh')::date;
  v_used integer;
begin
  select coalesce(plan, 'free'), pro_expires_at
    into v_plan, v_expiry
  from public.user_profiles
  where user_id = p_user_id
  for update;

  if not found then
    v_plan := 'free';
    v_expiry := null;
  end if;

  if lower(v_plan) = 'pro' and (v_expiry is null or v_expiry > now()) then
    return query select true, 0, -1, true;
    return;
  end if;

  insert into public.document_upload_usage(user_id, usage_date, used)
  values (p_user_id, v_today, 1)
  on conflict (user_id, usage_date)
  do update
    set used = public.document_upload_usage.used + 1,
        updated_at = now()
    where public.document_upload_usage.used < 5
  returning public.document_upload_usage.used into v_used;

  if v_used is null then
    select d.used into v_used
    from public.document_upload_usage d
    where d.user_id = p_user_id and d.usage_date = v_today;

    return query select false, coalesce(v_used, 5), 0, false;
    return;
  end if;

  return query select true, v_used, greatest(0, 5 - v_used), false;
end;
$$;

revoke all on function public.consume_document_daily_limit(uuid) from public, anon, authenticated;
grant execute on function public.consume_document_daily_limit(uuid) to service_role;
