-- PeixeCrew: fotografia de perfil guardada na conta (correr uma vez no SQL Editor do Supabase)
-- Só aceita JPEG pequenos em base64 (a app envia 192x192, cerca de 15 KB).
-- Quem pode ver a fotografia é quem já pode ver o perfil (amigos, membros do mesmo grupo); só o próprio a pode mudar.
alter table public.profiles
  add column if not exists foto text
  check (foto is null or (char_length(foto) <= 60000 and foto ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$'));
