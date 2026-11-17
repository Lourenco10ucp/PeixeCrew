-- PeixeCrew: reações às saídas partilhadas (correr uma vez no SQL Editor do Supabase)
-- Só reage quem pode ver a saída (amigos ou membros do grupo com quem foi partilhada); cada um só tira as suas.
create table if not exists public.reactions (
  outing_owner uuid not null,
  outing_id    text not null,
  user_id      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  emoji        text not null check (emoji in ('👍', '🐟', '🔥', '💪')),
  created_at   timestamptz not null default now(),
  primary key (outing_owner, outing_id, user_id, emoji),
  foreign key (outing_owner, outing_id) references public.outings (owner, id) on delete cascade
);
alter table public.reactions enable row level security;
create policy re_select on public.reactions for select to authenticated using (
  exists (select 1 from public.outings o where o.owner = reactions.outing_owner and o.id = reactions.outing_id));
create policy re_insert on public.reactions for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.outings o where o.owner = reactions.outing_owner and o.id = reactions.outing_id and not o.deleted));
create policy re_delete on public.reactions for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.reactions to authenticated;
