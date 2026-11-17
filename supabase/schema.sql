-- =====================================================================
-- PeixeCrew — estrutura da base de dados (Fase A: contas, amigos, grupos)
-- Colar no Supabase: SQL Editor › New query › Run. Pode correr-se uma vez.
--
-- Princípios:
--  * Cada pessoa só vê o que é seu, mais o que outros partilharam com ela.
--  * Locais e saídas são privados por omissão; partilham-se com amigos e/ou grupos escolhidos.
--  * Notas pessoais ficam em tabelas próprias, que só o dono lê (nunca são partilhadas).
--  * Fotografias não vêm para aqui (ficam no telemóvel).
--  * Nada é exposto ao papel «anon»: tudo exige sessão iniciada.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Perfis (um por conta; criado automaticamente no registo)
-- ---------------------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  nome       text not null default '' check (char_length(nome) <= 40),
  created_at timestamptz not null default now()
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare base text; u text; i int := 0;
begin
  base := regexp_replace(lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))), '[^a-z0-9_.]', '', 'g');
  if char_length(base) < 3 then base := base || 'peixe'; end if;
  base := left(base, 16); u := base;
  while exists (select 1 from public.profiles where username = u) loop
    i := i + 1; u := base || i::text;
  end loop;
  insert into public.profiles (id, username, nome)
  values (new.id, u, left(coalesce(new.raw_user_meta_data->>'nome', ''), 40));
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Amizades (pedido -> aceite)
-- ---------------------------------------------------------------------
create table public.friendships (
  requester  uuid not null references public.profiles(id) on delete cascade,
  addressee  uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);
create unique index friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));

-- ---------------------------------------------------------------------
-- Grupos e membros
-- ---------------------------------------------------------------------
create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null check (char_length(nome) between 2 and 40),
  owner       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  invite_code text not null unique default encode(gen_random_bytes(6), 'hex'),
  created_at  timestamptz not null default now()
);

create table public.group_members (
  group_id  uuid not null references public.groups(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  role      text not null default 'member' check (role in ('admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- quem cria o grupo fica administrador
create function public.handle_new_group() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.group_members (group_id, user_id, role) values (new.id, new.owner, 'admin');
  return new;
end $$;
create trigger on_group_created after insert on public.groups
  for each row execute function public.handle_new_group();

-- ---------------------------------------------------------------------
-- Funções auxiliares (security definer para evitar recursão nas regras)
-- ---------------------------------------------------------------------
create function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a)));
$$;

create function public.my_group_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(group_id), '{}') from public.group_members where user_id = auth.uid();
$$;

create function public.is_group_admin(g uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.group_members where group_id = g and user_id = auth.uid() and role = 'admin');
$$;

create function public.shares_group_with(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.group_members a join public.group_members b on a.group_id = b.group_id
    where a.user_id = auth.uid() and b.user_id = other);
$$;

-- vê o perfil: o próprio, amigos, pedidos pendentes e colegas de grupo
create function public.can_see_profile(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p = auth.uid()
      or exists (select 1 from public.friendships f
                 where (f.requester = auth.uid() and f.addressee = p) or (f.requester = p and f.addressee = auth.uid()))
      or public.shares_group_with(p);
$$;

-- procurar alguém pelo nome de utilizador exato (não dá para listar toda a gente)
create function public.find_profile(q text) returns table (id uuid, username text, nome text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.username, p.nome from public.profiles p where p.username = lower(trim(q)) limit 1;
$$;

-- criar um grupo (devolve id e código; o criador fica administrador pelo trigger)
create function public.create_group(nome text) returns table (id uuid, invite_code text)
language plpgsql security definer set search_path = '' as $$
declare g uuid; c text;
begin
  if auth.uid() is null then raise exception 'Sem sessão'; end if;
  insert into public.groups (nome, owner) values (left(trim(create_group.nome), 40), auth.uid()) returning groups.id, groups.invite_code into g, c;
  return query select g, c;
end $$;

-- entrar num grupo com o código de convite
create function public.join_group(code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'Sem sessão'; end if;
  select id into g from public.groups where invite_code = lower(trim(code));
  if g is null then raise exception 'Código de convite inválido'; end if;
  insert into public.group_members (group_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end $$;

-- novo código de convite (só administradores)
create function public.new_invite_code(g uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare c text := encode(gen_random_bytes(6), 'hex');
begin
  if not public.is_group_admin(g) then raise exception 'Só administradores'; end if;
  update public.groups set invite_code = c where id = g;
  return c;
end $$;

-- apagar a própria conta e todos os dados (RGPD)
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sem sessão'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Locais e saídas (dados da app em JSON; partilha por amigos/grupos)
-- ---------------------------------------------------------------------
create table public.spots (
  owner         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  id            text not null check (char_length(id) between 2 and 40),
  data          jsonb not null check (pg_column_size(data) < 20000),
  share_friends boolean not null default false,
  share_groups  uuid[] not null default '{}',
  deleted       boolean not null default false,
  updated_at    timestamptz not null default now(),
  primary key (owner, id)
);

create table public.outings (
  owner         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  id            text not null check (char_length(id) between 2 and 40),
  gid           text check (gid is null or char_length(gid) <= 45),
  date          date not null,
  data          jsonb not null check (pg_column_size(data) < 30000),
  share_friends boolean not null default false,
  share_groups  uuid[] not null default '{}',
  deleted       boolean not null default false,
  updated_at    timestamptz not null default now(),
  primary key (owner, id)
);
create index outings_gid on public.outings (gid);

-- notas pessoais: só o dono
create table public.private_notes (
  owner      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('spot', 'outing')),
  id         text not null check (char_length(id) between 2 and 40),
  notas      text not null default '' check (char_length(notas) <= 2000),
  updated_at timestamptz not null default now(),
  primary key (owner, kind, id)
);

-- convite para uma saída de grupo (aparece ao companheiro, que a junta ao seu diário)
create table public.outing_invites (
  id         uuid primary key default gen_random_uuid(),
  from_user  uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  to_user    uuid not null references public.profiles(id) on delete cascade,
  gid        text not null check (char_length(gid) <= 45),
  payload    jsonb not null check (pg_column_size(payload) < 20000),
  created_at timestamptz not null default now(),
  unique (to_user, gid),
  check (from_user <> to_user)
);

-- updated_at automático
create function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger spots_touch before update on public.spots for each row execute function public.touch_updated_at();
create trigger outings_touch before update on public.outings for each row execute function public.touch_updated_at();
create trigger notes_touch before update on public.private_notes for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Regras de acesso (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.profiles       enable row level security;
alter table public.friendships    enable row level security;
alter table public.groups         enable row level security;
alter table public.group_members  enable row level security;
alter table public.spots          enable row level security;
alter table public.outings        enable row level security;
alter table public.private_notes  enable row level security;
alter table public.outing_invites enable row level security;

-- perfis
create policy profiles_select on public.profiles for select to authenticated using (public.can_see_profile(id));
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- amizades: só os dois envolvidos; quem recebe é que aceita
create policy fr_select on public.friendships for select to authenticated using (auth.uid() in (requester, addressee));
create policy fr_insert on public.friendships for insert to authenticated with check (requester = auth.uid() and status = 'pending');
create policy fr_accept on public.friendships for update to authenticated using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
create policy fr_delete on public.friendships for delete to authenticated using (auth.uid() in (requester, addressee));

-- grupos: membros veem; qualquer um cria (fica dono); administradores alteram/apagam
create policy gr_select on public.groups for select to authenticated using (id = any (public.my_group_ids()));
create policy gr_insert on public.groups for insert to authenticated with check (owner = auth.uid());
create policy gr_update on public.groups for update to authenticated using (public.is_group_admin(id)) with check (public.is_group_admin(id));
create policy gr_delete on public.groups for delete to authenticated using (public.is_group_admin(id));

-- membros: membros veem; sai quem quer; administradores tiram e promovem (entrar é só com join_group)
create policy gm_select on public.group_members for select to authenticated using (group_id = any (public.my_group_ids()));
create policy gm_delete on public.group_members for delete to authenticated using (user_id = auth.uid() or public.is_group_admin(group_id));
create policy gm_update on public.group_members for update to authenticated using (public.is_group_admin(group_id)) with check (public.is_group_admin(group_id));

-- locais e saídas: o dono faz tudo; amigos/grupos só leem o que foi partilhado (e não apagado)
create policy sp_select on public.spots for select to authenticated using (
  owner = auth.uid() or (not deleted and (
    (share_friends and public.are_friends(auth.uid(), owner)) or (share_groups && public.my_group_ids()))));
create policy sp_insert on public.spots for insert to authenticated with check (owner = auth.uid());
create policy sp_update on public.spots for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy sp_delete on public.spots for delete to authenticated using (owner = auth.uid());

create policy ou_select on public.outings for select to authenticated using (
  owner = auth.uid() or (not deleted and (
    (share_friends and public.are_friends(auth.uid(), owner)) or (share_groups && public.my_group_ids()))));
create policy ou_insert on public.outings for insert to authenticated with check (owner = auth.uid());
create policy ou_update on public.outings for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy ou_delete on public.outings for delete to authenticated using (owner = auth.uid());

-- notas: só o dono, para tudo
create policy pn_all on public.private_notes for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

-- convites de saída: só a amigos ou colegas de grupo; os dois envolvidos veem e apagam
create policy oi_select on public.outing_invites for select to authenticated using (auth.uid() in (from_user, to_user));
create policy oi_insert on public.outing_invites for insert to authenticated with check (
  from_user = auth.uid() and (public.are_friends(auth.uid(), to_user) or public.shares_group_with(to_user)));
create policy oi_delete on public.outing_invites for delete to authenticated using (auth.uid() in (from_user, to_user));

-- ---------------------------------------------------------------------
-- Permissões: nada para «anon»; o necessário para «authenticated»
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
grant select, update                 on public.profiles       to authenticated;
grant select, insert, update, delete on public.friendships    to authenticated;
grant select, insert, update, delete on public.groups         to authenticated;
grant select, update, delete         on public.group_members  to authenticated;
grant select, insert, update, delete on public.spots          to authenticated;
grant select, insert, update, delete on public.outings        to authenticated;
grant select, insert, update, delete on public.private_notes  to authenticated;
grant select, insert, delete         on public.outing_invites to authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.are_friends(uuid, uuid)   to authenticated;
grant execute on function public.my_group_ids()            to authenticated;
grant execute on function public.is_group_admin(uuid)      to authenticated;
grant execute on function public.shares_group_with(uuid)   to authenticated;
grant execute on function public.can_see_profile(uuid)     to authenticated;
grant execute on function public.find_profile(text)        to authenticated;
grant execute on function public.join_group(text)          to authenticated;
grant execute on function public.create_group(text)        to authenticated;
grant execute on function public.new_invite_code(uuid)     to authenticated;
grant execute on function public.delete_my_account()       to authenticated;
