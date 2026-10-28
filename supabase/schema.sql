-- ═══════════════════════════════════════════════════════════════════════
--  영업부(시흥) 스케줄관리 — Supabase 스키마
--
--  실행 방법: Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 Run.
--  여러 번 실행해도 안전합니다 (멱등).
--
--  실행이 끝나면 맨 아래 "관리자 PIN 설정" 안내를 따라 PIN을 넣어주세요.
--  PIN을 넣지 않으면 관리자모드로 들어갈 수 없습니다.
-- ═══════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  0. 준비 — 로컬/셀프호스팅에서도 돌아가도록 역할과 확장을 보장
--     (Supabase 프로젝트에는 이미 다 있어서 아무 일도 하지 않습니다)
-- ───────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- PIN 해시는 PostgREST에 절대 노출되지 않는 별도 스키마에 둔다.
-- (Supabase는 public 스키마만 API로 공개하므로 private은 네트워크에서 접근 불가)
create schema if not exists private;
revoke all on schema private from public;

-- pgcrypto(bcrypt)가 어느 스키마에 설치돼 있든 동작하도록 얇은 래퍼를 만든다.
do $$
declare v_schema text;
begin
  select n.nspname into v_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_schema is null then
    create schema if not exists extensions;
    execute 'create extension pgcrypto with schema extensions';
    v_schema := 'extensions';
  end if;

  execute format(
    'create or replace function private.hash_pin(p_pin text) returns text
       language sql immutable as $f$ select %I.crypt(p_pin, %I.gen_salt(''bf'', 10)) $f$',
    v_schema, v_schema);

  execute format(
    'create or replace function private.pin_matches(p_pin text, p_hash text) returns boolean
       language sql immutable as $f$ select p_hash = %I.crypt(p_pin, p_hash) $f$',
    v_schema, v_schema);
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  1. 테이블
-- ───────────────────────────────────────────────────────────────────────

-- 연차/휴일근무 종류. 여기에 행을 추가하면 앱에 바로 버튼이 생깁니다.
create table if not exists public.annual_types (
  key          text primary key,
  label        text not null,
  css_class    text not null default 'cc-an',
  weekend_only boolean not null default false,
  sort_order   integer not null default 0
);

create table if not exists public.employees (
  id         uuid primary key default gen_random_uuid(),
  legacy_id  text unique,                       -- 기존 구글시트 id (이관 추적용)
  name       text not null check (length(btrim(name)) > 0),
  team       text not null default '',
  color      text not null default '#3B6FE8' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  retired    boolean not null default false,
  retired_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- 이름에는 "(퇴)"를 붙이지 않습니다. retired 플래그로 화면에서 붙입니다.

create table if not exists public.annuals (
  id         bigint generated always as identity primary key,
  -- 직원을 삭제해도 연차 기록은 남는다 (기존 앱 동작 유지)
  emp_id     uuid references public.employees(id) on delete set null,
  emp_name   text not null default '',          -- 삭제된 직원의 이름 보존용 스냅샷
  date       date not null,
  type       text not null references public.annual_types(key),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint annuals_emp_date_key unique (emp_id, date)
);
create index if not exists annuals_date_idx on public.annuals (date);

create table if not exists public.settings (
  key        text primary key,
  value      text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.change_logs (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       text not null default '',
  description text not null
);
create index if not exists change_logs_at_idx on public.change_logs (at desc);

-- 관리자 PIN (bcrypt 해시). private 스키마라 API로 조회 자체가 불가능합니다.
create table if not exists private.admin_pins (
  role       text primary key check (role in ('admin','super')),
  pin_hash   text not null,
  updated_at timestamptz not null default now()
);

-- 로그인 세션. PIN 검증(bcrypt ~100ms)은 로그인 때 단 한 번만 하고,
-- 이후 요청은 이 토큰을 인덱스로 찾아 확인한다 (~1ms).
-- 덕분에 첫 화면과 모든 쓰기에서 bcrypt 비용이 사라진다.
create table if not exists private.sessions (
  token      text primary key,
  role       text not null check (role in ('admin','super')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_seen  timestamptz not null default now()
);
create index if not exists sessions_expires_idx on private.sessions (expires_at);

-- PIN 무차별 대입 완화용 시도 기록.
--
-- ⚠️ 알려진 한계: 이 차단은 전체 공용이다 (요청자를 식별할 방법이 없음 —
--    Supabase를 거치면 모든 요청이 같은 IP로 보인다). 즉 누군가 계속
--    틀린 PIN을 넣고 있으면 그 1분 동안은 정상 사용자도 로그인이 막힌다.
--    대신 세션 토큰이 30일(사용 시 자동 연장) 유지되므로 이미 로그인한
--    관리자는 영향을 받지 않는다. 평소 로그인할 일이 거의 없어서
--    실무상 문제가 되는 경우는 드물다. 완전한 해결은 Supabase Auth 전환.
create table if not exists private.pin_attempts (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  ok boolean not null
);
create index if not exists pin_attempts_at_idx on private.pin_attempts (at desc);

-- ───────────────────────────────────────────────────────────────────────
--  2. 기본 데이터
-- ───────────────────────────────────────────────────────────────────────
insert into public.annual_types (key, label, css_class, weekend_only, sort_order) values
  ('연차',              '연차 (종일)',        'cc-an',     false,  1),
  ('오전반차',          '오전반차',           'cc-ham',    false,  2),
  ('오후반차',          '오후반차',           'cc-hpm',    false,  3),
  ('0.75차(12시퇴근)',  '0.75차(12시퇴근)',   'cc-h75am',  false,  4),
  ('0.75차(17시출근)',  '0.75차(17시출근)',   'cc-h75pm',  false,  5),
  ('오전반반차',        '오전반반차',         'cc-hham',   false,  6),
  ('오후반반차',        '오후반반차',         'cc-hhpm',   false,  7),
  ('중간반차(4시간)',   '중간반차(4시간)',    'cc-jb4',    false,  8),
  ('중간반차(2시간)',   '중간반차(2시간)',    'cc-jb2',    false,  9),
  ('휴일근무',          '휴일근무',           'cc-hw',     true,  10),
  ('공가(예비군)',      '공가(예비군)',       'cc-gg',     false, 11),
  ('조퇴',              '조퇴',               'cc-jt',     false, 12),
  ('지각',              '지각',               'cc-jg',     false, 13),
  ('병가',              '병가',               'cc-bg',     false, 14),
  ('무단결근',          '무단결근',           'cc-mg',     false, 15)
on conflict (key) do update
  set label = excluded.label,
      css_class = excluded.css_class,
      weekend_only = excluded.weekend_only,
      sort_order = excluded.sort_order;

insert into public.settings (key, value) values ('cal_notice', '')
on conflict (key) do nothing;

-- ───────────────────────────────────────────────────────────────────────
--  3. updated_at 자동 갱신
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.touch_updated_at() returns trigger
  language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists employees_touch on public.employees;
create trigger employees_touch before update on public.employees
  for each row execute function public.touch_updated_at();

drop trigger if exists annuals_touch on public.annuals;
create trigger annuals_touch before update on public.annuals
  for each row execute function public.touch_updated_at();

drop trigger if exists settings_touch on public.settings;
create trigger settings_touch before update on public.settings
  for each row execute function public.touch_updated_at();

-- ───────────────────────────────────────────────────────────────────────
--  4. RLS — 읽기만 허용. 쓰기 정책은 "없다" = 직접 쓰기 전면 거부.
--     모든 쓰기는 아래 5번의 RPC 함수를 통해서만 가능하다.
-- ───────────────────────────────────────────────────────────────────────
alter table public.employees    enable row level security;
alter table public.annuals      enable row level security;
alter table public.settings     enable row level security;
alter table public.change_logs  enable row level security;
alter table public.annual_types enable row level security;

do $$
declare t text;
begin
  foreach t in array array['employees','annuals','settings','change_logs','annual_types'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_read', t);
  end loop;
end $$;

grant usage on schema public to anon, authenticated;
grant select on public.employees, public.annuals, public.settings,
                public.change_logs, public.annual_types to anon, authenticated;
-- insert/update/delete 권한은 주지 않는다.

-- service_role(서버 전용 키)은 전체 권한. Supabase에는 이미 설정돼 있어
-- 아무 변화가 없고, 로컬/셀프호스팅에서 이관 스크립트가 돌게 해줍니다.
grant usage on schema public to service_role;
grant all privileges on all tables in schema public to service_role;
grant all privileges on all sequences in schema public to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  5. 쓰기 경로 — PIN을 검증하는 RPC 함수들
--     security definer + search_path='' (전부 스키마 명시) = 권한 상승 경로 차단
-- ───────────────────────────────────────────────────────────────────────

-- PIN → 역할. 틀리면 null. 과도한 시도는 일시적으로 차단.
create or replace function private.role_for_pin(p_pin text) returns text
  language plpgsql security definer set search_path = '' as $$
declare
  v_role   text := null;
  v_fails  integer;
begin
  if p_pin is null or length(p_pin) = 0 then
    return null;
  end if;

  -- 최근 10분간 실패 20회 이상이면 1분간 잠금 (자동 대입 공격 완화)
  select count(*) into v_fails
    from private.pin_attempts
   where ok = false and at > now() - interval '10 minutes';

  if v_fails >= 20 and exists (
       select 1 from private.pin_attempts
        where ok = false and at > now() - interval '1 minute') then
    raise exception 'PIN 시도가 너무 많습니다. 1분 후 다시 시도해주세요.'
      using errcode = 'P0001';
  end if;

  select a.role into v_role
    from private.admin_pins a
   where private.pin_matches(p_pin, a.pin_hash)
   limit 1;

  insert into private.pin_attempts (ok) values (v_role is not null);
  delete from private.pin_attempts where at < now() - interval '1 day';

  return v_role;
end $$;

-- 세션 토큰 → 역할. 만료됐거나 없으면 null.
create or replace function private.role_for_token(p_token text) returns text
  language plpgsql security definer set search_path = '' as $$
declare v_role text;
begin
  if p_token is null or length(p_token) < 32 then
    return null;
  end if;

  select s.role into v_role
    from private.sessions s
   where s.token = p_token and s.expires_at > now();

  if v_role is null then
    return null;
  end if;

  -- 사용할 때마다 유효기간을 연장(슬라이딩). 하루에 한 번 정도만 쓰기가 발생한다.
  update private.sessions
     set expires_at = now() + interval '30 days', last_seen = now()
   where token = p_token and expires_at < now() + interval '29 days';

  return v_role;
end $$;

-- 최소 권한 확인. 모자라면 예외.
create or replace function private.require_role(p_token text, p_min text) returns text
  language plpgsql security definer set search_path = '' as $$
declare v_role text;
begin
  v_role := private.role_for_token(p_token);
  if v_role is null then
    raise exception '로그인이 필요합니다. 관리자모드로 다시 로그인해주세요.'
      using errcode = 'P0001';
  end if;
  if p_min = 'super' and v_role <> 'super' then
    raise exception '슈퍼관리자만 할 수 있는 작업입니다.' using errcode = 'P0001';
  end if;
  return v_role;
end $$;

create or replace function private.log(p_desc text) returns void
  language sql security definer set search_path = '' as $$
  insert into public.change_logs (description) values (p_desc);
$$;

-- 화면에 보일 이름 ("(퇴)" 접두어 포함)
create or replace function private.display_name(p_name text, p_retired boolean) returns text
  language sql immutable set search_path = '' as $$
  select case when p_retired then '(퇴)' || p_name else p_name end;
$$;

-- ── 로그인 ──────────────────────────────────────────────────────────
-- PIN을 확인하고 세션 토큰을 발급한다. PIN이 오가는 건 이 호출 뿐이다.
create or replace function public.login(p_pin text) returns jsonb
  language plpgsql security definer set search_path = '' as $$
declare
  v_role  text;
  v_token text;
  v_exp   timestamptz;
begin
  v_role := private.role_for_pin(p_pin);
  if v_role is null then
    return jsonb_build_object('role', null, 'token', null);
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '') ||
             replace(gen_random_uuid()::text, '-', '');
  v_exp   := now() + interval '30 days';

  insert into private.sessions (token, role, expires_at) values (v_token, v_role, v_exp);
  delete from private.sessions where expires_at < now();

  return jsonb_build_object('role', v_role, 'token', v_token, 'expiresAt', v_exp);
end $$;

-- 로그아웃 — 토큰 폐기
create or replace function public.logout(p_token text) returns void
  language sql security definer set search_path = '' as $$
  delete from private.sessions where token = p_token;
$$;

-- 저장된 토큰이 아직 유효한지 (앱 시작 시 권한 복원용)
create or replace function public.session_role(p_token text) returns text
  language sql security definer set search_path = '' as $$
  select private.role_for_token(p_token);
$$;

-- ── 첫 화면 한 번에 (직원 + 종류 + 연차 3개월 + 공지 + 권한) ────────
create or replace function public.get_bootstrap(
  p_ym text,
  p_token text default null,
  p_months_before integer default 1,
  p_months_after  integer default 1
) returns jsonb
  language plpgsql security definer set search_path = '' as $$
declare
  v_first date;
  v_from  date;
  v_to    date;
begin
  if p_ym !~ '^\d{4}-\d{2}$' then
    raise exception 'p_ym 형식은 YYYY-MM 이어야 합니다 (받은 값: %)', p_ym
      using errcode = 'P0001';
  end if;
  v_first := to_date(p_ym || '-01', 'YYYY-MM-DD');
  v_from  := v_first - (greatest(p_months_before, 0) || ' months')::interval;
  v_to    := v_first + ((greatest(p_months_after, 0) + 1) || ' months')::interval;

  return jsonb_build_object(
    'role', private.role_for_token(p_token),
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'notice', coalesce((select s.value from public.settings s where s.key = 'cal_notice'), ''),
    'annual_types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', t.key, 'label', t.label,
               'cssClass', t.css_class, 'weekendOnly', t.weekend_only)
             order by t.sort_order)
        from public.annual_types t), '[]'::jsonb),
    'employees', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name,
               'displayName', private.display_name(e.name, e.retired),
               'team', e.team, 'color', e.color,
               'retired', e.retired, 'retiredAt', e.retired_at)
             order by e.retired, e.name)
        from public.employees e), '[]'::jsonb),
    'annuals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'empId', a.emp_id, 'empName', a.emp_name,
               'date', a.date, 'type', a.type)
             order by a.date)
        from public.annuals a
       where a.date >= v_from and a.date < v_to), '[]'::jsonb)
  );
end $$;

-- ── 연차/휴일근무 등록·삭제 (type이 비면 삭제) ──────────────────────
create or replace function public.save_annual(
  p_token text, p_emp_id uuid, p_date date, p_type text
) returns void
  language plpgsql security definer set search_path = '' as $$
declare
  v_emp public.employees;
  v_old text;
begin
  perform private.require_role(p_token, 'admin');

  select * into v_emp from public.employees e where e.id = p_emp_id;
  if not found then
    raise exception '직원을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;

  select a.type into v_old from public.annuals a
   where a.emp_id = p_emp_id and a.date = p_date;

  if p_type is null or length(btrim(p_type)) = 0 then
    delete from public.annuals a where a.emp_id = p_emp_id and a.date = p_date;
    if v_old is not null then
      perform private.log(v_emp.name || ' ' || p_date || ' 연차/휴일근무 삭제');
    end if;
    return;
  end if;

  insert into public.annuals (emp_id, emp_name, date, type)
  values (p_emp_id, v_emp.name, p_date, p_type)
  on conflict (emp_id, date) do update
    set type = excluded.type, emp_name = excluded.emp_name;

  perform private.log(v_emp.name || ' ' || p_date || ' ' || p_type ||
                      case when v_old is null then ' 등록' else ' 변경' end);
end $$;

-- ── 직원 ────────────────────────────────────────────────────────────
create or replace function public.add_employee(
  p_token text, p_name text, p_team text default '', p_color text default '#3B6FE8'
) returns public.employees
  language plpgsql security definer set search_path = '' as $$
declare v_row public.employees;
begin
  perform private.require_role(p_token, 'super');
  insert into public.employees (name, team, color)
  values (btrim(p_name), coalesce(btrim(p_team), ''), p_color)
  returning * into v_row;
  perform private.log('직원 등록: ' || v_row.name);
  return v_row;
end $$;

create or replace function public.update_employee(
  p_token text, p_id uuid, p_name text, p_team text, p_color text
) returns void
  language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  perform private.require_role(p_token, 'super');
  update public.employees
     set name = btrim(p_name), team = coalesce(btrim(p_team), ''), color = p_color
   where id = p_id
  returning name into v_name;
  if v_name is null then
    raise exception '직원을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  -- 이름이 바뀌면 지난 연차 기록의 이름 스냅샷도 맞춘다
  update public.annuals set emp_name = v_name where emp_id = p_id;
  perform private.log('직원 정보 수정: ' || v_name);
end $$;

create or replace function public.set_employee_retired(
  p_token text, p_id uuid, p_retired boolean
) returns void
  language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  perform private.require_role(p_token, 'super');
  update public.employees
     set retired = p_retired,
         retired_at = case when p_retired then coalesce(retired_at, current_date) else null end
   where id = p_id
  returning name into v_name;
  if v_name is null then
    raise exception '직원을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  perform private.log(case when p_retired then '퇴사 처리: ' else '복직 처리: ' end || v_name);
end $$;

create or replace function public.delete_employee(p_token text, p_id uuid) returns void
  language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  perform private.require_role(p_token, 'super');
  select name into v_name from public.employees where id = p_id;
  if v_name is null then
    raise exception '직원을 찾을 수 없습니다.' using errcode = 'P0001';
  end if;
  -- 연차 기록은 지우지 않는다. emp_id만 끊기고 이름은 남는다.
  update public.annuals set emp_name = v_name where emp_id = p_id;
  delete from public.employees where id = p_id;
  perform private.log('직원 삭제: ' || v_name);
end $$;

-- ── 연차 공지 ───────────────────────────────────────────────────────
create or replace function public.save_notice(p_token text, p_notice text) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_token, 'admin');
  insert into public.settings (key, value) values ('cal_notice', coalesce(p_notice, ''))
  on conflict (key) do update set value = excluded.value;
  perform private.log('연차 공지 수정');
end $$;

-- ── 이관용 일괄 입력 (슈퍼관리자 전용) ──────────────────────────────
--  브라우저 이관 도구(migrate.html)가 쓰는 함수들.
--  이관이 끝나면 지워도 됩니다. 지우는 방법은 supabase/README.md 참고.
-- ────────────────────────────────────────────────────────────────────
create or replace function public.import_employees(p_token text, p_rows jsonb) returns integer
  language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_role(p_token, 'super');
  insert into public.employees (legacy_id, name, team, color, retired, retired_at)
  select r->>'legacy_id',
         btrim(r->>'name'),
         coalesce(r->>'team', ''),
         coalesce(r->>'color', '#3B6FE8'),
         coalesce((r->>'retired')::boolean, false),
         nullif(r->>'retired_at', '')::date
    from jsonb_array_elements(p_rows) r
   where btrim(coalesce(r->>'name','')) <> ''
  on conflict (legacy_id) do update
    set name = excluded.name, team = excluded.team, color = excluded.color,
        retired = excluded.retired, retired_at = excluded.retired_at;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.import_annual_types(p_token text, p_rows jsonb) returns integer
  language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_role(p_token, 'super');
  insert into public.annual_types (key, label, css_class, weekend_only, sort_order)
  select r->>'key', coalesce(r->>'label', r->>'key'),
         coalesce(r->>'css_class', 'cc-an'),
         coalesce((r->>'weekend_only')::boolean, false),
         coalesce((r->>'sort_order')::integer, 90)
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'key','') <> ''
  on conflict (key) do nothing;     -- 기존 종류의 색상/순서는 건드리지 않는다
  get diagnostics n = row_count;
  return n;
end $$;

-- 직원과 연결된 연차. (emp_id, date) 기준으로 덮어쓴다.
create or replace function public.import_annuals(p_token text, p_rows jsonb) returns integer
  language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_role(p_token, 'super');
  insert into public.annuals (emp_id, emp_name, date, type)
  select (r->>'emp_id')::uuid, coalesce(r->>'emp_name',''),
         (r->>'date')::date, r->>'type'
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'emp_id','') <> '' and coalesce(r->>'type','') <> ''
  on conflict (emp_id, date) do update
    set type = excluded.type, emp_name = excluded.emp_name;
  get diagnostics n = row_count;
  return n;
end $$;

-- 삭제된 직원의 기록. emp_id가 없어 유니크 제약이 걸리지 않으므로
-- 같은 내용이 이미 있으면 건너뛴다 (여러 번 실행해도 중복이 생기지 않게).
create or replace function public.import_orphan_annuals(p_token text, p_rows jsonb) returns integer
  language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_role(p_token, 'super');
  insert into public.annuals (emp_id, emp_name, date, type)
  select null, src.emp_name, src.d, src.t
    from (
      select distinct coalesce(r->>'emp_name','') as emp_name,
                      (r->>'date')::date as d, r->>'type' as t
        from jsonb_array_elements(p_rows) r
       where coalesce(r->>'type','') <> ''
    ) src
   where not exists (
     select 1 from public.annuals a
      where a.emp_id is null and a.emp_name = src.emp_name
        and a.date = src.d and a.type = src.t);
  get diagnostics n = row_count;
  return n;
end $$;

-- 공지 이관. save_notice와 달리 변경이력을 남기지 않는다.
-- (이관 자체는 사람이 한 변경이 아니고, 여기서 이력을 남기면 바로 아래
--  import_change_logs 가 "이미 이력이 있다"고 오판하게 된다)
create or replace function public.import_notice(p_token text, p_notice text) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_token, 'super');
  insert into public.settings (key, value) values ('cal_notice', coalesce(p_notice, ''))
  on conflict (key) do update set value = excluded.value;
end $$;

-- 변경이력 이관. 같은 시각·같은 내용이 이미 있으면 건너뛴다.
-- 테이블이 비어 있는지로 판단하지 않으므로, 앱을 이미 써서 이력이 쌓인
-- 뒤에 실행해도 정확히 빠진 것만 채운다.
create or replace function public.import_change_logs(p_token text, p_rows jsonb, p_replace boolean default false)
  returns integer
  language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_role(p_token, 'super');
  if p_replace then
    delete from public.change_logs;
  end if;
  insert into public.change_logs (at, actor, description)
  select src.at, src.actor, src.description
    from (
      select distinct
             coalesce((r->>'at')::timestamptz, now()) as at,
             coalesce(r->>'actor','') as actor,
             r->>'description' as description
        from jsonb_array_elements(p_rows) r
       where coalesce(r->>'description','') <> ''
    ) src
   where not exists (
     select 1 from public.change_logs c
      where c.at = src.at and c.description = src.description);
  get diagnostics n = row_count;
  return n;
end $$;

-- ── 권한 ────────────────────────────────────────────────────────────
revoke all on all functions in schema private from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.login(text)',
    'public.logout(text)',
    'public.session_role(text)',
    'public.get_bootstrap(text,text,integer,integer)',
    'public.save_annual(text,uuid,date,text)',
    'public.add_employee(text,text,text,text)',
    'public.update_employee(text,uuid,text,text,text)',
    'public.set_employee_retired(text,uuid,boolean)',
    'public.delete_employee(text,uuid)',
    'public.save_notice(text,text)',
    'public.import_employees(text,jsonb)',
    'public.import_annual_types(text,jsonb)',
    'public.import_annuals(text,jsonb)',
    'public.import_orphan_annuals(text,jsonb)',
    'public.import_change_logs(text,jsonb,boolean)',
    'public.import_notice(text,text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  6. 실시간 — 다른 사람의 변경이 내 화면에 바로 반영되도록
--     (Supabase 외부에서는 publication이 없으므로 건너뜁니다)
-- ───────────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['employees','annuals','settings'] loop
      if not exists (
        select 1 from pg_publication_tables
         where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  7. 관리자 PIN 설정 함수
--
--  ⚠️ 이 파일에 실제 PIN을 적지 마세요.
--     이 파일은 PIN을 넣는 곳이 아니라 set_pin "함수"를 만드는 곳입니다.
--     여기에 PIN을 적어도 설정되지 않고, 파일이 깃에 올라가면 PIN이
--     그대로 공개됩니다.
--
--  PIN은 이 파일을 다 돌린 뒤, SQL Editor에서 New query 를 새로 열고
--  아래 두 줄을 실행해서 넣습니다 (이 주석을 고치는 게 아닙니다):
--
--     select private.set_pin('super', '원하는_PIN');
--     select private.set_pin('admin', '원하는_PIN');
--
--  저장되는 건 bcrypt 해시뿐이라 나중에 PIN을 다시 볼 수는 없습니다.
--  잊으면 위 두 줄을 새 PIN으로 다시 실행하면 됩니다.
-- ───────────────────────────────────────────────────────────────────────
create or replace function private.set_pin(p_role text, p_pin text) returns text
  language plpgsql security definer set search_path = '' as $$
begin
  if p_role not in ('admin','super') then
    raise exception 'p_role은 admin 또는 super 여야 합니다.' using errcode = 'P0001';
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'PIN은 4자 이상이어야 합니다 (8자 이상 권장).' using errcode = 'P0001';
  end if;
  insert into private.admin_pins (role, pin_hash)
  values (p_role, private.hash_pin(p_pin))
  on conflict (role) do update set pin_hash = excluded.pin_hash, updated_at = now();
  return p_role || ' PIN이 설정되었습니다.';
end $$;

revoke all on function private.set_pin(text,text) from public, anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────
--  8. 마무리 점검
--  이 파일의 마지막 결과로 현재 상태와 다음에 할 일을 보여줍니다.
-- ───────────────────────────────────────────────────────────────────────
select
  (select count(*) from public.annual_types) as "연차종류",
  (select count(*) from public.employees)    as "직원",
  (select count(*) from public.annuals)      as "연차기록",
  (select count(*) from private.admin_pins)  as "설정된PIN",
  case when exists (select 1 from private.admin_pins)
    then 'PIN까지 준비됐습니다. 다음은 5단계 데이터 이관입니다.'
    else '⚠️ PIN이 아직 없습니다. 이 파일을 고치지 마세요 — 고쳐도 설정되지 않습니다. '
         || 'SQL Editor에서 New query 를 새로 열고, 아래 두 줄을 붙여넣어 PIN만 바꿔 Run 하세요 → '
         || 'select private.set_pin(''super'', ''여기에_원하는_PIN''); '
         || 'select private.set_pin(''admin'', ''여기에_원하는_PIN'');'
  end as "다음 할 일";
