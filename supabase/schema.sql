-- Train & Ride · Level up: shema za Supabase.
-- Zalepi v Supabase > SQL Editor > Run. Prej zamenjaj TEJA_EMAIL s svojim emailom (isti, s katerim se prijavljaš v aplikacijo).

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  consent_checkins boolean not null default false,
  consent_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.app_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.checkins (
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  name text,
  goals jsonb,
  answers jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, week_start)
);

alter table public.profiles  enable row level security;
alter table public.app_state enable row level security;
alter table public.checkins  enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable as $$ select coalesce(auth.jwt()->>'email','') = 'TEJA_EMAIL' $$;

-- dostop prek API-ja (v novih projektih tabele niso samodejno izpostavljene)
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.app_state, public.checkins to authenticated;

-- vsaka uporabnica vidi in ureja samo svoje vrstice
create policy "own profile"  on public.profiles  for all using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "own state"    on public.app_state  for all using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "own checkins" on public.checkins   for all using (auth.uid()=user_id) with check (auth.uid()=user_id);
-- Teja bere samo profile in tedenske check-ine (ne dnevnih podatkov app_state)
create policy "admin read profiles" on public.profiles for select using (public.is_admin());
create policy "admin read checkins" on public.checkins for select using (public.is_admin());

-- pregleden poročilni pogled za Tejo: Table Editor > v_checkins ali izvoz v CSV
create or replace view public.v_checkins with (security_invoker=true) as
select c.week_start as teden,
       coalesce(nullif(c.name,''), p.email) as ime,
       p.email,
       (select coalesce(sum((g->>'good')::int),0)   from jsonb_array_elements(c.goals) g) as izvedeno,
       (select coalesce(sum((g->>'target')::int),0) from jsonb_array_elements(c.goals) g) as nacrtovano,
       c.answers->>'w' as kaj_je_delovalo,
       c.answers->>'o' as kaj_je_oviralo,
       c.answers->>'c' as kaj_spremenim,
       c.updated_at
from public.checkins c left join public.profiles p using (user_id);

grant select on public.v_checkins to authenticated;
