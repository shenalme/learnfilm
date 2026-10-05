-- =====================================================================
-- Story to Screen: Supabase schema
drop function if exists public.submit_quiz(smallint, smallint[]);
-- Run this whole file once in Supabase > SQL Editor > New query.
-- Safe to re-run: it drops and recreates functions, and upserts seed data.
-- =====================================================================

-- ---------- Profiles (one per student, created automatically on sign-up)
create table if not exists public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  full_name          text not null default '' check (char_length(full_name) <= 120),
  language           text not null default 'en' check (language in ('en','si','ta')),
  stage              text check (char_length(stage) <= 80),
  district           text check (char_length(district) <= 60),
  academy_optin      boolean not null default false,
  film_url           text check (char_length(film_url) <= 500),
  academy_enquiry_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "Read own profile"   on public.profiles;
drop policy if exists "Update own profile" on public.profiles;
create policy "Read own profile"   on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "Update own profile" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare lang text := coalesce(new.raw_user_meta_data->>'language', 'en');
begin
  if lang not in ('en','si','ta') then lang := 'en'; end if;
  insert into public.profiles (id, full_name, language, academy_optin)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''), 120),
    lang,
    coalesce((new.raw_user_meta_data->>'academy_optin')::boolean, false)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------- Course structure (seeded below)
create table if not exists public.course_lessons (
  id       text primary key,
  section  smallint not null,
  position smallint not null
);
alter table public.course_lessons enable row level security;
drop policy if exists "Anyone can read lessons" on public.course_lessons;
create policy "Anyone can read lessons" on public.course_lessons for select to anon, authenticated using (true);

-- Quiz answer key: no policies, so it is only readable by the functions below.
create table if not exists public.quiz_keys (
  section  smallint not null,
  question smallint not null,
  correct  smallint not null,
  primary key (section, question)
);
alter table public.quiz_keys enable row level security;

-- ---------- Lesson progress
create table if not exists public.lesson_progress (
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  lesson_id    text not null references public.course_lessons(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (user_id, lesson_id)
);
alter table public.lesson_progress enable row level security;
drop policy if exists "Read own progress"   on public.lesson_progress;
drop policy if exists "Insert own progress" on public.lesson_progress;
create policy "Read own progress"   on public.lesson_progress for select to authenticated using (user_id = (select auth.uid()));
create policy "Insert own progress" on public.lesson_progress for insert to authenticated with check (user_id = (select auth.uid()));

-- ---------- Quiz attempts (written only through submit_quiz)
create table if not exists public.quiz_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  section    smallint not null,
  score      smallint not null,
  total      smallint not null,
  passed     boolean not null,
  answers    int[] not null,
  created_at timestamptz not null default now()
);
create index if not exists quiz_attempts_user_idx on public.quiz_attempts (user_id, section);
alter table public.quiz_attempts enable row level security;
drop policy if exists "Read own attempts" on public.quiz_attempts;
create policy "Read own attempts" on public.quiz_attempts for select to authenticated using (user_id = (select auth.uid()));

-- ---------- Certificates (issued only through issue_certificate)
create table if not exists public.certificates (
  id         text primary key,
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  full_name  text not null,
  issued_at  timestamptz not null default now()
);
alter table public.certificates enable row level security;
drop policy if exists "Read own certificate" on public.certificates;
create policy "Read own certificate" on public.certificates for select to authenticated using (user_id = (select auth.uid()));

-- ---------- Film Academy enquiries (anyone can submit; only your team can read)
create table if not exists public.academy_enquiries (
  id              bigint generated always as identity primary key,
  user_id         uuid default auth.uid() references auth.users(id) on delete set null,
  full_name       text not null check (char_length(full_name) between 2 and 120),
  phone           text check (char_length(phone) <= 30),
  email           text check (char_length(email) <= 200),
  district        text check (char_length(district) <= 60),
  language        text check (language in ('en','si','ta')),
  message         text check (char_length(message) <= 2000),
  course_progress smallint,
  certificate_id  text,
  status          text not null default 'new',
  created_at      timestamptz not null default now(),
  constraint contact_required check (coalesce(phone,'') <> '' or coalesce(email,'') <> '')
);
alter table public.academy_enquiries enable row level security;
drop policy if exists "Anyone can send an enquiry" on public.academy_enquiries;
create policy "Anyone can send an enquiry" on public.academy_enquiries for insert to anon, authenticated
  with check (user_id is null or user_id = (select auth.uid()));

-- ---------- Functions
create or replace function public.submit_quiz(p_section int, p_answers int[])
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_total int; v_score int; v_passed boolean;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select count(*), count(*) filter (where p_answers[k.question] = k.correct)
    into v_total, v_score
    from public.quiz_keys k where k.section = p_section;
  if v_total = 0 then raise exception 'Unknown section %', p_section; end if;
  v_passed := v_score * 3 >= v_total * 2;   -- pass mark: two thirds
  insert into public.quiz_attempts (user_id, section, score, total, passed, answers)
    values (uid, p_section, v_score, v_total, v_passed, p_answers);
  return json_build_object('score', v_score, 'total', v_total, 'passed', v_passed);
end $$;

create or replace function public.issue_certificate()
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_name text; v_missing int; v_cert public.certificates;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into v_cert from public.certificates where user_id = uid;
  if found then return row_to_json(v_cert); end if;

  select count(*) into v_missing from public.course_lessons l
    where not exists (select 1 from public.lesson_progress p where p.user_id = uid and p.lesson_id = l.id);
  if v_missing > 0 then raise exception 'Lessons not finished: %', v_missing; end if;

  select count(*) into v_missing from (select distinct section from public.quiz_keys) s
    where not exists (select 1 from public.quiz_attempts a where a.user_id = uid and a.section = s.section and a.passed);
  if v_missing > 0 then raise exception 'Quizzes not passed: %', v_missing; end if;

  select full_name into v_name from public.profiles where id = uid;
  if coalesce(trim(v_name), '') = '' then raise exception 'Add your name to your profile first'; end if;

  insert into public.certificates (id, user_id, full_name)
    values ('STS-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), uid, v_name)
    returning * into v_cert;
  return row_to_json(v_cert);
end $$;

create or replace function public.verify_certificate(p_id text)
returns table (full_name text, issued_at timestamptz)
language sql security definer set search_path = '' stable as $$
  select c.full_name, c.issued_at from public.certificates c where c.id = upper(trim(p_id));
$$;

revoke all on function public.submit_quiz(int, int[]) from public, anon;
revoke all on function public.issue_certificate() from public, anon;
grant execute on function public.submit_quiz(int, int[]) to authenticated;
grant execute on function public.issue_certificate() to authenticated;
grant execute on function public.verify_certificate(text) to anon, authenticated;

-- ---------- Views for your team (private schema, not exposed to the website)
create schema if not exists admin;
revoke all on schema admin from anon, authenticated;

create or replace view admin.student_funnel as
select p.id, u.email, p.full_name, p.stage, p.district, p.language, p.academy_optin,
       (select count(*) from public.lesson_progress lp where lp.user_id = p.id) as lessons_done,
       (select count(distinct a.section) from public.quiz_attempts a where a.user_id = p.id and a.passed) as sections_passed,
       c.id as certificate_id, c.issued_at as certified_at,
       p.film_url, p.academy_enquiry_at, p.created_at as joined_at
from public.profiles p
join auth.users u on u.id = p.id
left join public.certificates c on c.user_id = p.id;

create or replace view admin.academy_leads as
select e.created_at, e.status, e.full_name, e.phone, e.email, e.district, e.language,
       e.course_progress, e.certificate_id, e.message, f.stage, f.film_url
from public.academy_enquiries e
left join admin.student_funnel f on f.id = e.user_id
order by e.created_at desc;

-- =====================================================================
-- SEED: course lessons and quiz answer key (generated from the website's course data)
-- =====================================================================
insert into public.course_lessons (id, section, position) values
  ('s1l1', 1, 1),
  ('s1l2', 1, 2),
  ('s1l3', 1, 3),
  ('s2l1', 2, 1),
  ('s2l2', 2, 2),
  ('s2l3', 2, 3),
  ('s3l1', 3, 1),
  ('s3l2', 3, 2),
  ('s3l3', 3, 3),
  ('s4l1', 4, 1),
  ('s4l2', 4, 2),
  ('s4l3', 4, 3),
  ('s5l1', 5, 1),
  ('s5l2', 5, 2),
  ('s5l3', 5, 3)
on conflict (id) do update set section = excluded.section, position = excluded.position;

delete from public.quiz_keys;
insert into public.quiz_keys (section, question, correct) values
  (1, 1, 0),
  (1, 2, 1),
  (1, 3, 1),
  (2, 1, 0),
  (2, 2, 1),
  (2, 3, 2),
  (3, 1, 1),
  (3, 2, 0),
  (3, 3, 2),
  (4, 1, 0),
  (4, 2, 2),
  (4, 3, 1),
  (5, 1, 1),
  (5, 2, 0),
  (5, 3, 2);
-- Note: answer indexes start at 0 (first option = 0), matching the website's quiz data.
