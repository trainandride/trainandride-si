-- Train & Ride: samodejni emaili (ponedeljkov opomnik uporabnicam + obvestilo trenerki ob novem check-inu).
-- Zalepi v Supabase > SQL Editor > Run. Prej zamenjaj RE_KLJUC (Resend API ključ) in TEJA_EMAIL.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table public.checkins add column if not exists submitted_at timestamptz;

create or replace view public.v_checkins with (security_invoker=true) as
select c.week_start as teden,
       coalesce(nullif(c.name,''), p.email) as ime,
       p.email,
       (select coalesce(sum((g->>'good')::int),0)   from jsonb_array_elements(c.goals) g) as izvedeno,
       (select coalesce(sum((g->>'target')::int),0) from jsonb_array_elements(c.goals) g) as nacrtovano,
       c.answers->>'w' as kaj_je_delovalo,
       c.answers->>'o' as kaj_je_oviralo,
       c.answers->>'c' as kaj_spremenim,
       c.updated_at,
       c.submitted_at as oddano_ob
from public.checkins c left join public.profiles p using (user_id);

select vault.create_secret('RE_KLJUC','resend_key');

create or replace function public.esc(t text) returns text language sql immutable as
$$ select replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;') $$;

create or replace function public.resend_key() returns text language sql security definer
set search_path = public, vault as
$$ select decrypted_secret from vault.decrypted_secrets where name='resend_key' limit 1 $$;
revoke all on function public.resend_key() from public, anon, authenticated;

-- obvestilo trenerki, ko članica odda check-in
create or replace function public.notify_checkin() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_good int; v_target int; who text; body text;
begin
  if new.submitted_at is null then return new; end if;
  if tg_op = 'UPDATE' and old.submitted_at is not distinct from new.submitted_at then return new; end if;
  select coalesce(sum((g->>'good')::int),0), coalesce(sum((g->>'target')::int),0)
    into v_good, v_target from jsonb_array_elements(coalesce(new.goals,'[]'::jsonb)) g;
  who := coalesce(nullif(new.name,''),'Članica');
  body := '<p><b>'||esc(who)||'</b> je oddala check-in za teden od '||to_char(new.week_start,'DD. MM.')||'.</p>'
       || '<p>Izvedeno: <b>'||v_good||' od '||v_target||'</b> načrtovanih dni.</p>'
       || '<p><b>Kaj je delovalo:</b> '||esc(new.answers->>'w')||'</p>'
       || '<p><b>Kaj me je oviralo:</b> '||esc(new.answers->>'o')||'</p>'
       || '<p><b>Kaj spremenim:</b> '||esc(new.answers->>'c')||'</p>';
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization','Bearer '||public.resend_key(),'Content-Type','application/json'),
    body := jsonb_build_object('from','Train & Ride <app@trainandride.si>','to',jsonb_build_array('TEJA_EMAIL'),
                               'subject','Nov check-in: '||who,'html',body));
  return new;
exception when others then
  return new;  -- obvestilo ne sme ovirati oddaje check-ina
end $$;

drop trigger if exists checkin_notify on public.checkins;
create trigger checkin_notify after insert or update on public.checkins
for each row execute function public.notify_checkin();

-- ponedeljkov opomnik vsem članicam (ena serijska pošiljka)
create or replace function public.send_monday_reminders(p_only text default null, p_force boolean default false)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare payload jsonb;
begin
  if not p_force and (current_date < date '2026-12-07' or current_date > date '2027-03-29') then return; end if;
  select jsonb_agg(jsonb_build_object(
      'from','Train & Ride <app@trainandride.si>','to',jsonb_build_array(email),
      'subject','Ponedeljkov check-in',
      'html','<p>Hej!</p><p>Nov teden se začenja. Vzemi 3 minute in oddaj svoj tedenski check-in: poglej, kaj je delovalo, in izberi eno majhno spremembo.</p>'
           ||'<p><b>Odpri aplikacijo na začetnem zaslonu</b> (ikona Accountability Club na telefonu) in v zavihku Napredek oddaj check-in.</p>'
           ||'<p>Aplikacije nimaš na začetnem zaslonu? Odpri jo v brskalniku:</p>'
           ||'<p><a href="https://trainandride.si/app/#checkin" style="background:#177A4C;color:#fff;padding:12px 20px;border-radius:10px;text-decoration:none;font-weight:bold">Odpri check-in v brskalniku</a></p>'
           ||'<p>Sharing is caring. Tvoja iskrenost pomaga tebi in drugim.</p><p>Train &amp; Ride</p>'))
    into payload
  from public.profiles
  where email is not null and consent_checkins and (p_only is null or email = p_only);
  if payload is not null then
    perform net.http_post(url := 'https://api.resend.com/emails/batch',
      headers := jsonb_build_object('Authorization','Bearer '||public.resend_key(),'Content-Type','application/json'),
      body := payload);
  end if;
end $$;
revoke all on function public.send_monday_reminders(text, boolean) from public, anon, authenticated;

-- vsak ponedeljek ob 06:00 UTC (07:00 po slovenskem zimskem času)
select cron.schedule('ponedeljek-check-in','0 6 * * 1','select public.send_monday_reminders()');
