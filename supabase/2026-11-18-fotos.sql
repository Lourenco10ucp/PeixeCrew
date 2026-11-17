-- PeixeCrew: fotografias das saídas partilhadas (correr uma vez no SQL Editor do Supabase)
-- Espaço privado «fotos»: cada um só envia e apaga na sua pasta (<id da conta>/<id da saída>/...);
-- só vê as fotografias quem já pode ver a saída (amigos ou membros do grupo com quem foi partilhada).
-- Cada fotografia tem no máximo 1 MB (a app envia cerca de 150 KB).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', false, 1048576, array['image/jpeg'])
on conflict (id) do nothing;
create policy fotos_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'fotos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy fotos_delete on storage.objects for delete to authenticated using (
  bucket_id = 'fotos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy fotos_select on storage.objects for select to authenticated using (
  bucket_id = 'fotos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.outings o
               where o.owner::text = (storage.foldername(name))[1] and o.id = (storage.foldername(name))[2])));
