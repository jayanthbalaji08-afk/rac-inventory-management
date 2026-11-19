-- Sends every new notification to the notify-email Edge Function (replaces the
-- dashboard "Database Webhook" step). Uses the public anon key: the function only
-- takes the notification id from the request and re-reads everything else itself.
create extension if not exists pg_net with schema extensions;

create or replace function public.notifications_email_hook() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url     := 'https://iycfmnfinhrtdvwtcypl.supabase.co/functions/v1/notify-email',
    body    := jsonb_build_object('type','INSERT','table','notifications','record',jsonb_build_object('id',new.id)),
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml5Y2ZtbmZpbmhydGR2d3RjeXBsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ5NzA5MzIsImV4cCI6MjExMDU0NjkzMn0.TlKX1pCpoYsPHVIRi8LWEcc9rvPx9x2MFU5W5v2p26o'),
    timeout_milliseconds := 10000);
  return new;
exception when others then
  -- never let an email problem block the portal action that created the notification
  raise warning 'notify-email hook failed: %', sqlerrm;
  return new;
end $$;

revoke execute on function public.notifications_email_hook() from public, anon, authenticated;

drop trigger if exists notifications_email on public.notifications;
create trigger notifications_email after insert on public.notifications
  for each row execute function public.notifications_email_hook();
