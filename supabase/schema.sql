-- =====================================================================
--  Dashboard prognoz Monte Carlo — wspólne scenariusze w Supabase
--  Uruchom raz w Supabase: SQL Editor → New query → wklej → Run.
--  Skrypt można uruchamiać ponownie (jest idempotentny).
-- =====================================================================

-- 1. Lista osób z dostępem (czytanie i zapis scenariuszy).
--    Tabela nie ma żadnych polityk RLS, więc przez API strony nie da się
--    jej odczytać ani zmienić — zarządzasz nią wyłącznie w panelu Supabase.
create table if not exists public.mc_members (
  email text primary key check (email = lower(email))
);
alter table public.mc_members enable row level security;

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
create index if not exists mc_scenarios_kind_updated on public.mc_scenarios (kind, updated_at desc);

-- 3. Autor i czas zmiany ustawia baza (na podstawie zalogowanego użytkownika),
--    więc przeglądarka nie może ich podrobić.
create or replace function public.mc_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := lower(auth.jwt() ->> 'email');
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_by := lower(auth.jwt() ->> 'email');
  new.updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists mc_stamp on public.mc_scenarios;
create trigger mc_stamp before insert or update on public.mc_scenarios
  for each row execute function public.mc_stamp();

-- 4. Czy zalogowana osoba jest na liście dostępu?
--    (security definer: funkcja może zajrzeć do mc_members, użytkownik nie)
create or replace function public.mc_is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mc_members m
    where m.email = lower(auth.jwt() ->> 'email')
  );
$$;
revoke all on function public.mc_is_member() from public, anon;
grant execute on function public.mc_is_member() to authenticated;

-- 5. Reguły dostępu (RLS): tylko osoby z listy widzą i zmieniają scenariusze.
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

-- Anonimowi użytkownicy nie mają żadnych uprawnień do tabeli.
revoke all on public.mc_scenarios from anon;
grant select, insert, update, delete on public.mc_scenarios to authenticated;

-- 6. Powiadomienia na żywo (Realtime) — zmiany widoczne od razu u innych osób.
do $$ begin
  alter publication supabase_realtime add table public.mc_scenarios;
exception when duplicate_object then null; end $$;

-- 7. Dodaj osoby z dostępem (małymi literami). Zmień adresy na prawdziwe:
-- insert into public.mc_members (email) values
--   ('imie.nazwisko@firma.pl'),
--   ('wspolpracownik@firma.pl')
-- on conflict do nothing;
