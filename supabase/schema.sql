-- =====================================================================
--  Dashboard prognoz Monte Carlo — wspólne scenariusze w Supabase
--  Dostęp: JEDNO wspólne konto zespołu chronione hasłem.
--
--  Uruchom w Supabase: SQL Editor → New query → wklej całość → Run.
--  Skrypt można uruchamiać wielokrotnie (także po poprzedniej wersji).
--
--  Konto wspólne: zespol@example.com  (ten sam adres jest w index.html
--  w stałej SHARED_EMAIL — jeśli go zmienisz, zmień w obu miejscach).
-- =====================================================================

-- 1. Konta z dostępem do scenariuszy. Domyślnie tylko konto wspólne.
--    Tabela nie ma polityk RLS, więc ze strony nie da się jej odczytać ani zmienić.
create table if not exists public.mc_members (
  email text primary key check (email = lower(email))
);
alter table public.mc_members enable row level security;
insert into public.mc_members (email) values ('zespol@example.com') on conflict do nothing;

-- 2. Scenariusze prognoz (obie zakładki dashboardu).
create table if not exists public.mc_scenarios (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('backlog', 'epics')),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  description text not null default '' check (char_length(description) <= 500),
  data        jsonb not null check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 65536),
  created_by  text not null,
  updated_by  text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- Podpis osoby (wpisywany na stronie, bo konto jest wspólne) i identyfikator karty przeglądarki.
alter table public.mc_scenarios add column if not exists created_name   text not null default '';
alter table public.mc_scenarios add column if not exists updated_name   text not null default '';
alter table public.mc_scenarios add column if not exists updated_client text not null default '';
create index if not exists mc_scenarios_kind_updated on public.mc_scenarios (kind, updated_at desc);

-- 3. Czas zmiany i konto ustawia baza — przeglądarka nie może ich podrobić.
create or replace function public.mc_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_name   := left(btrim(coalesce(new.updated_name, '')), 60);
  new.updated_client := left(coalesce(new.updated_client, ''), 64);
  if tg_op = 'INSERT' then
    new.created_by   := lower(auth.jwt() ->> 'email');
    new.created_at   := now();
    new.created_name := new.updated_name;
  else
    new.created_by   := old.created_by;
    new.created_at   := old.created_at;
    new.created_name := old.created_name;
  end if;
  new.updated_by := lower(auth.jwt() ->> 'email');
  new.updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists mc_stamp on public.mc_scenarios;
create trigger mc_stamp before insert or update on public.mc_scenarios
  for each row execute function public.mc_stamp();

-- 4. Czy zalogowane konto ma dostęp?
create or replace function public.mc_is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mc_members m
    where m.email = lower(auth.jwt() ->> 'email')
  );
$$;
revoke all on function public.mc_is_member() from public, anon;
grant execute on function public.mc_is_member() to authenticated;

-- 5. Reguły dostępu (RLS): tylko konto wspólne widzi i zmienia scenariusze.
alter table public.mc_scenarios enable row level security;

drop policy if exists mc_select on public.mc_scenarios;
drop policy if exists mc_insert on public.mc_scenarios;
drop policy if exists mc_update on public.mc_scenarios;
drop policy if exists mc_delete on public.mc_scenarios;

create policy mc_select on public.mc_scenarios for select to authenticated
  using ((select public.mc_is_member()));
create policy mc_insert on public.mc_scenarios for insert to authenticated
  with check ((select public.mc_is_member()));
create policy mc_update on public.mc_scenarios for update to authenticated
  using ((select public.mc_is_member())) with check ((select public.mc_is_member()));
create policy mc_delete on public.mc_scenarios for delete to authenticated
  using ((select public.mc_is_member()));

revoke all on public.mc_scenarios from anon;
grant select, insert, update, delete on public.mc_scenarios to authenticated;

-- 6. Powiadomienia na żywo (Realtime).
do $$ begin
  alter publication supabase_realtime add table public.mc_scenarios;
exception when duplicate_object then null; end $$;

-- =====================================================================
--  ZMIANA HASŁA (uruchamiaj osobno, gdy potrzebujesz):
--
--  update auth.users
--     set encrypted_password = extensions.crypt('NOWE-DLUGIE-HASLO', extensions.gen_salt('bf'))
--   where email = 'zespol@example.com';
--
--  Wylogowanie wszystkich urządzeń (np. po zmianie hasła):
--
--  delete from auth.sessions
--   where user_id = (select id from auth.users where email = 'zespol@example.com');
-- =====================================================================
