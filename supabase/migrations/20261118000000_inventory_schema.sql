-- =====================================================================
--  Robotics and Automation Club — Inventory Portal
--  Supabase (PostgreSQL) schema, security rules and server-side logic
--
--  How to apply (pick one):
--    • Dashboard → SQL Editor → New query → paste this file → Run
--    • CLI:  supabase db push        (after `supabase link`)
--
--  The file is idempotent: running it again is safe and also upgrades a
--  database created with the earlier schema.sql.
--  Requires the pg_cron extension (Dashboard → Database → Extensions).
-- =====================================================================

create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- 0. Admin allow-list
--    A user becomes an administrator only when their email is on this
--    list AND they have confirmed it (clicked the confirmation link).
--    Adding an email later also promotes an already-confirmed account.
-- ---------------------------------------------------------------------
create table if not exists public.admin_emails (email text primary key);
insert into public.admin_emails(email) values
  ('jayanthbalaji.24ec@kct.ac.in'),
  ('jaisurya.24ec@kct.ac.in'),
  ('gokulvasan.24mc@kct.ac.in'),
  ('raghavan.25ec@kct.ac.in'),
  ('tholkappiyan.25ec@kct.ac.in')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              text not null unique,
  name               text not null,
  reg                text not null,
  phone              text,
  department         text,
  year               text,
  designation        text,
  role               text not null default 'user' check (role in ('user','admin')),
  status             text not null default 'Active',
  late_return_level  int  not null default 0,
  last_warning_at    date,
  suspended_until    date,
  inventory_blocked  boolean not null default false,
  warning_history    jsonb not null default '[]'::jsonb,
  created_at         timestamptz not null default now()
);
create unique index if not exists profiles_reg_key on public.profiles (upper(reg));

create table if not exists public.inventory (
  id           text primary key,
  name         text not null,
  category     text not null,
  icon         text default '▦',
  description  text not null default '',
  total        int  not null default 0 check (total >= 0),
  available    int  not null default 0 check (available >= 0),
  location     text default '',
  datasheet    text default '',
  returnable   boolean not null default true,
  art          int not null default 0,
  created_at   timestamptz not null default now(),
  check (available <= total)
);

create table if not exists public.wishlist_items (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  component_id text not null references public.inventory(id) on delete cascade,
  quantity     int  not null check (quantity >= 1),
  primary key (user_id, component_id)
);

create table if not exists public.requests (
  id                 text primary key,
  user_id            uuid not null references public.profiles(id),
  user_name          text not null,
  email              text,
  reg                text,
  project            text not null,
  purpose            text not null,
  required_date      date,
  notes              text default '',
  status             text not null default 'Pending Approval',
  admin_remarks      text default '',
  approved_by        text,
  approved_by_email  text,
  decision_at        timestamptz,
  created_at         timestamptz not null default now()
);
create index if not exists requests_user_idx on public.requests(user_id);

create table if not exists public.request_items (
  id            bigserial primary key,
  request_id    text not null references public.requests(id) on delete cascade,
  idx           int  not null,
  component_id  text not null references public.inventory(id),
  name          text not null,
  requested     int  not null check (requested >= 1),
  approved      int  not null default 0 check (approved >= 0),
  issued        int  not null default 0 check (issued >= 0),
  status        text not null default 'Pending Approval',
  unique (request_id, idx)
);

create table if not exists public.borrowings (
  id            text primary key,
  request_id    text not null references public.requests(id),
  user_id       uuid not null references public.profiles(id),
  user_name     text not null,
  component_id  text not null references public.inventory(id),
  name          text not null,
  quantity      int  not null check (quantity >= 0),
  outstanding   int  not null check (outstanding >= 0),
  issue_date    date,
  due_date      date,
  status        text not null default 'Approved',
  issued        boolean not null default false,
  returnable    boolean not null default true,
  approved_at   timestamptz not null default now(),
  issued_at     timestamptz
);
create index if not exists borrowings_user_idx    on public.borrowings(user_id);
create index if not exists borrowings_request_idx on public.borrowings(request_id);

create table if not exists public.returns (
  id                  text primary key,
  user_id             uuid not null references public.profiles(id),
  user_name           text not null,
  email               text,
  borrowing_id        text not null references public.borrowings(id),
  request_id          text,
  component_id        text not null,
  name                text not null,
  requested_quantity  int  not null check (requested_quantity >= 1),
  confirmed_quantity  int  not null default 0,
  condition           text not null default 'Good',
  notes               text default '',
  status              text not null default 'Return Pending',
  admin_remarks       text default '',
  processed           boolean not null default false,
  acknowledged_by     text,
  acknowledged_at     timestamptz,
  created_at          timestamptz not null default now()
);
create index if not exists returns_user_idx      on public.returns(user_id);
create index if not exists returns_borrowing_idx on public.returns(borrowing_id);

-- recipient is either a user's uuid (as text) or the word 'admin'
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  recipient   text not null,
  title       text not null,
  message     text not null,
  related_id  text default '',
  icon        text default '♧',
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
-- set by the notify-email function so each notification is emailed at most once
alter table public.notifications add column if not exists emailed_at timestamptz;
create index if not exists notifications_recipient_idx on public.notifications(recipient, created_at desc);

create table if not exists public.activity_log (
  id      bigserial primary key,
  title   text not null,
  detail  text,
  at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Inventory starts empty: admins add every component from the portal
--    (Admin → Inventory → Add component).

-- ---------------------------------------------------------------------
-- 3. Helper functions (internal — not callable from the browser)
-- ---------------------------------------------------------------------
create or replace function public.ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

create or replace function public.notify(p_recipient text, p_title text, p_message text,
                                         p_related text default '', p_icon text default '♧')
returns void language sql security definer set search_path = public as $$
  insert into public.notifications(recipient,title,message,related_id,icon)
  values (p_recipient,p_title,p_message,coalesce(p_related,''),coalesce(p_icon,'♧'));
$$;

create or replace function public.log_activity(p_title text, p_detail text)
returns void language sql security definer set search_path = public as $$
  insert into public.activity_log(title,detail) values (p_title,p_detail);
$$;

-- Readable ids such as REQ-JAYANTH-0003. The advisory lock stops two
-- simultaneous submissions from picking the same number.
create or replace function public.gen_id(p_prefix text, p_name text, p_table text)
returns text language plpgsql security definer set search_path = public as $$
declare slug text; n int := 1; cand text; taken boolean;
begin
  if p_table not in ('requests','returns') then raise exception 'gen_id: unsupported table %', p_table; end if;
  slug := left(regexp_replace(upper(coalesce(p_name,'USER')),'[^A-Z0-9]+','','g'),12);
  if slug = '' then slug := 'USER'; end if;
  perform pg_advisory_xact_lock(hashtext(p_prefix||'-'||slug));
  loop
    cand := p_prefix||'-'||slug||'-'||lpad(n::text,4,'0');
    execute format('select exists(select 1 from public.%I where id = $1)', p_table) into taken using cand;
    exit when not taken;
    n := n + 1;
  end loop;
  return cand;
end $$;

create or replace function public.gen_borrow_id() returns text
language sql volatile as $$ select 'BOR-'||upper(substr(md5(random()::text||clock_timestamp()::text),1,8)) $$;

-- p_quantities looks like [{"idx":0,"qty":2}, ...]; missing index → 0
create or replace function public.qty_for(p_quantities jsonb, p_idx int) returns int
language sql immutable as $$
  select coalesce((select (e->>'qty')::int
                   from jsonb_array_elements(coalesce(p_quantities,'[]'::jsonb)) e
                   where (e->>'idx')::int = p_idx limit 1), 0)
$$;

-- returns a message when the user may not borrow, otherwise null
create or replace function public.user_restricted(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p.inventory_blocked then
      'Your inventory access is permanently blocked because overdue components were not returned after repeated warnings.'
    when p.suspended_until is not null and p.suspended_until >= public.ist_today() then
      'Borrowing is suspended until '||to_char(p.suspended_until,'DD Mon YYYY')||' because of overdue components. You can still submit return requests.'
    else null end
  from public.profiles p where p.id = p_user
$$;

-- ---------------------------------------------------------------------
-- 4. Accounts: enforce @kct.ac.in, create the profile, grant admin
--    only after the email address has been confirmed
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(new.email);
  m jsonb := coalesce(new.raw_user_meta_data,'{}'::jsonb);
begin
  if v_email is null or v_email !~ '^[a-z0-9._%+-]+@kct\.ac\.in$' then
    raise exception 'Email must end with @kct.ac.in';
  end if;
  insert into public.profiles(id,email,name,reg,phone,department,year,designation,role)
  values (
    new.id, v_email,
    coalesce(nullif(trim(m->>'name'),''), split_part(v_email,'@',1)),
    upper(coalesce(nullif(trim(m->>'reg'),''), 'NA-'||new.id::text)),
    nullif(trim(m->>'phone'),''), nullif(trim(m->>'department'),''),
    nullif(trim(m->>'year'),''), nullif(trim(m->>'designation'),''),
    -- admin only if the address is already confirmed (e.g. confirmations disabled)
    case when new.email_confirmed_at is not null
          and exists(select 1 from public.admin_emails a where a.email = v_email)
         then 'admin' else 'user' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    update public.profiles set role = 'admin'
     where id = new.id
       and exists(select 1 from public.admin_emails a where a.email = lower(new.email));
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row execute function public.handle_user_confirmed();

create or replace function public.handle_admin_email_added() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles p set role = 'admin'
    from auth.users u
   where u.id = p.id and lower(u.email) = lower(new.email) and u.email_confirmed_at is not null;
  return new;
end $$;

drop trigger if exists on_admin_email_added on public.admin_emails;
create trigger on_admin_email_added after insert on public.admin_emails
  for each row execute function public.handle_admin_email_added();

-- keep stored addresses lower-case so the comparisons above always match
update public.admin_emails set email = lower(trim(email)) where email <> lower(trim(email));

-- ---------------------------------------------------------------------
-- 5. Business functions (called from the browser with supabase.rpc)
--    Every function checks who is calling; the browser cannot bypass them.
-- ---------------------------------------------------------------------

-- 5.1 User submits the whole wishlist as one request
create or replace function public.submit_request(p_project text, p_purpose text, p_required_date date, p_notes text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_prof public.profiles; v_msg text; v_id text; r record; v_count int; v_idx int := 0;
begin
  if v_uid is null then raise exception 'Please sign in.'; end if;
  select * into v_prof from public.profiles where id = v_uid;
  if not found then raise exception 'Profile not found.'; end if;
  v_msg := public.user_restricted(v_uid);
  if v_msg is not null then raise exception '%', v_msg; end if;
  if coalesce(trim(p_project),'') = '' or coalesce(trim(p_purpose),'') = '' or p_required_date is null then
    raise exception 'Project, purpose and required date are required.';
  end if;
  if p_required_date < public.ist_today() then
    raise exception 'Required date cannot be in the past.';
  end if;
  select count(*) into v_count from public.wishlist_items where user_id = v_uid;
  if v_count = 0 then raise exception 'Your Wishlist is empty.'; end if;
  if exists(select 1 from public.wishlist_items w left join public.inventory i on i.id = w.component_id
            where w.user_id = v_uid and (i.id is null or w.quantity < 1 or w.quantity > i.available)) then
    raise exception 'Stock changed. Review your Wishlist before submitting.';
  end if;
  v_id := public.gen_id('REQ', v_prof.name, 'requests');
  insert into public.requests(id,user_id,user_name,email,reg,project,purpose,required_date,notes)
  values (v_id,v_uid,v_prof.name,v_prof.email,v_prof.reg,trim(p_project),trim(p_purpose),p_required_date,coalesce(trim(p_notes),''));
  for r in select w.component_id, w.quantity, i.name from public.wishlist_items w
           join public.inventory i on i.id = w.component_id where w.user_id = v_uid order by i.id loop
    insert into public.request_items(request_id,idx,component_id,name,requested)
    values (v_id,v_idx,r.component_id,r.name,r.quantity);
    v_idx := v_idx + 1;
  end loop;
  delete from public.wishlist_items where user_id = v_uid;
  perform public.notify('admin','New combined component request',
     v_prof.name||' ('||v_prof.email||') submitted '||v_id||' for '||v_count||' component type(s).', v_id,'⇄');
  perform public.notify(v_uid::text,'Request submitted successfully','Your request '||v_id||' is pending admin approval.', v_id,'⇄');
  perform public.log_activity('New component request', v_prof.name||' submitted '||v_id);
  return v_id;
end $$;

-- 5.2 User cancels a pending request
create or replace function public.cancel_request(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  select name into v_name from public.profiles where id = auth.uid();
  update public.requests set status = 'Cancelled', admin_remarks = 'Cancelled by user'
   where id = p_id and user_id = auth.uid() and status = 'Pending Approval';
  if not found then raise exception 'Only pending requests can be cancelled.'; end if;
  update public.request_items set status = 'Cancelled' where request_id = p_id;
  perform public.notify('admin','Request cancelled', v_name||' cancelled '||p_id||'.', p_id,'×');
  perform public.log_activity('Request cancelled', v_name||' cancelled '||p_id);
end $$;

-- 5.3 Admin approves / rejects. Approved items appear in the user's borrowings at once.
create or replace function public.decide_request(p_id text, p_action text, p_remarks text, p_quantities jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin public.profiles; r public.requests; it public.request_items; comp public.inventory;
  q int; v_total int := 0; v_status text; v_remarks text := coalesce(trim(p_remarks),''); v_final text;
begin
  if not public.is_admin() then raise exception 'Only administrators can do this.'; end if;
  if p_action not in ('approve','reject') then raise exception 'Unknown action.'; end if;
  select * into v_admin from public.profiles where id = auth.uid();
  select * into r from public.requests where id = p_id for update;
  if not found or r.status <> 'Pending Approval' then raise exception 'This request has already been processed.'; end if;

  if p_action = 'reject' then
    update public.request_items set approved = 0, status = 'Rejected' where request_id = p_id;
    v_status := 'Rejected';
  else
    -- validate everything first, then write
    for it in select * from public.request_items where request_id = p_id order by idx loop
      q := public.qty_for(p_quantities, it.idx);
      select * into comp from public.inventory where id = it.component_id for update;
      if q < 0 or q > it.requested or q > coalesce(comp.available,0) then
        raise exception 'Invalid approval quantity or stock has changed for %.', it.name;
      end if;
    end loop;
    for it in select * from public.request_items where request_id = p_id order by idx loop
      q := public.qty_for(p_quantities, it.idx);
      select * into comp from public.inventory where id = it.component_id;
      update public.request_items
         set approved = q,
             status = case when q = 0 then 'Rejected' when q = it.requested then 'Approved' else 'Partially Approved' end
       where id = it.id;
      v_total := v_total + q;
      if q > 0 then
        insert into public.borrowings(id,request_id,user_id,user_name,component_id,name,quantity,outstanding,due_date,status,issued,returnable)
        values (public.gen_borrow_id(), r.id, r.user_id, r.user_name, it.component_id, it.name, q,
                case when comp.returnable then q else 0 end, r.required_date, 'Approved', false, comp.returnable);
      end if;
    end loop;
    v_status := case when v_total = 0 then 'Rejected'
                     when not exists(select 1 from public.request_items where request_id = p_id and approved <> requested) then 'Approved'
                     else 'Partially Approved' end;
  end if;

  v_final := case when v_status = 'Rejected' and p_action <> 'reject' and v_remarks = '' then 'No items could be approved.' else v_remarks end;
  update public.requests set status = v_status, admin_remarks = v_final, approved_by = v_admin.name,
         approved_by_email = v_admin.email, decision_at = now() where id = p_id;

  perform public.notify(r.user_id::text,
    case v_status when 'Approved' then 'Request approved' when 'Partially Approved' then 'Request partially approved' else 'Request rejected' end,
    'Your request '||r.id||' is now '||lower(v_status)||'. Decision made by: '||v_admin.name||' ('||v_admin.email||'). '
      ||case when v_status <> 'Rejected' then 'Approved components are now listed in My Borrowings. ' else '' end
      ||case when v_final <> '' then 'Admin note: '||v_final else '' end,
    r.id,'⇄');
  perform public.log_activity('Request decision', v_admin.name||' set '||p_id||' to '||v_status);
end $$;

-- 5.4 Admin records the physical hand-over (deducts stock)
create or replace function public.record_issue(p_request_id text, p_issue_date date, p_due_date date, p_quantities jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin public.profiles; r public.requests; it public.request_items; comp public.inventory; b public.borrowings;
  q int; v_any boolean := false; v_rest int;
begin
  if not public.is_admin() then raise exception 'Only administrators can do this.'; end if;
  select * into v_admin from public.profiles where id = auth.uid();
  select * into r from public.requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status not in ('Approved','Partially Approved','Partially Issued','Ready for Collection') then
    raise exception 'This request is not ready for issue.';
  end if;
  if p_issue_date is null then raise exception 'Issue date is required.'; end if;
  if p_due_date is not null and p_due_date < p_issue_date then
    raise exception 'Due date cannot be before the issue date.';
  end if;

  for it in select * from public.request_items where request_id = p_request_id and approved > issued order by idx loop
    q := public.qty_for(p_quantities, it.idx);
    select * into comp from public.inventory where id = it.component_id for update;
    if q < 0 or q > it.approved - it.issued or q > coalesce(comp.available,0) then
      raise exception 'Issue quantity invalid or stock changed for %.', it.name;
    end if;
    if q > 0 then v_any := true; end if;
  end loop;
  if not v_any then raise exception 'Enter at least one quantity to issue.'; end if;

  for it in select * from public.request_items where request_id = p_request_id and approved > issued order by idx loop
    q := public.qty_for(p_quantities, it.idx);
    if q = 0 then continue; end if;
    select * into comp from public.inventory where id = it.component_id;
    update public.inventory set available = available - q where id = comp.id;
    update public.request_items
       set issued = issued + q,
           status = case when issued + q >= approved then 'Issued' else 'Partially Issued' end
     where id = it.id;

    select * into b from public.borrowings
     where request_id = p_request_id and component_id = it.component_id and issued = false and quantity > 0
     order by approved_at limit 1 for update;
    if found then
      if q < b.quantity then
        -- split: the part not handed over yet stays as an "Approved" borrowing
        v_rest := b.quantity - q;
        insert into public.borrowings(id,request_id,user_id,user_name,component_id,name,quantity,outstanding,due_date,status,issued,returnable,approved_at)
        values (public.gen_borrow_id(), b.request_id, b.user_id, b.user_name, b.component_id, b.name, v_rest,
                case when b.returnable then v_rest else 0 end, b.due_date, 'Approved', false, b.returnable, b.approved_at);
      end if;
      update public.borrowings
         set quantity = q, outstanding = case when returnable then q else 0 end,
             issue_date = p_issue_date, due_date = coalesce(p_due_date, due_date),
             status = case when returnable then 'Borrowed' else 'Issued' end,
             issued = true, issued_at = now()
       where id = b.id;
    else
      insert into public.borrowings(id,request_id,user_id,user_name,component_id,name,quantity,outstanding,issue_date,due_date,status,issued,returnable,issued_at)
      values (public.gen_borrow_id(), r.id, r.user_id, r.user_name, comp.id, comp.name, q,
              case when comp.returnable then q else 0 end, p_issue_date, coalesce(p_due_date, r.required_date),
              case when comp.returnable then 'Borrowed' else 'Issued' end, true, comp.returnable, now());
    end if;
  end loop;

  update public.requests
     set status = case when exists(select 1 from public.request_items where request_id = p_request_id and approved > issued)
                       then 'Partially Issued' else 'Issued' end
   where id = p_request_id;
  perform public.notify(r.user_id::text,'Components issued','The admin recorded physical issuance for request '||r.id||'.', r.id,'⇧');
  perform public.log_activity('Components issued', v_admin.name||' issued components for '||r.id);
end $$;

-- 5.5 User asks to return one or more borrowed items (any time, even while suspended)
--     p_items: [{"borrowing_id":"BOR-…","qty":1,"condition":"Good"}, ...]
create or replace function public.submit_return(p_items jsonb, p_notes text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_prof public.profiles; e jsonb; b public.borrowings; q int; v_cond text; v_pending int; v_id text;
begin
  if v_uid is null then raise exception 'Please sign in.'; end if;
  select * into v_prof from public.profiles where id = v_uid;
  if not found then raise exception 'Profile not found.'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one component to return.';
  end if;

  -- one pass: each row is checked against what is already pending, including
  -- rows inserted earlier in this same call. Any error rolls back everything.
  for e in select value from jsonb_array_elements(p_items) loop
    select * into b from public.borrowings where id = e->>'borrowing_id' and user_id = v_uid for update;
    if not found or b.returnable = false then raise exception 'This item cannot be returned through this page.'; end if;
    begin q := (e->>'qty')::int; exception when others then q := null; end;
    v_cond := e->>'condition';
    if v_cond is null or v_cond not in ('Good','Needs Inspection','Damaged') then raise exception 'Invalid condition.'; end if;
    select coalesce(sum(requested_quantity),0) into v_pending from public.returns
     where borrowing_id = b.id and not processed
       and status in ('Return Pending','Return Acknowledged','Needs Review','Partially Returned');
    if q is null or q < 1 or q > b.outstanding - v_pending then
      raise exception 'Return quantity exceeds the quantity available to request for %.', b.name;
    end if;

    v_id := public.gen_id('RET', v_prof.name, 'returns');
    insert into public.returns(id,user_id,user_name,email,borrowing_id,request_id,component_id,name,requested_quantity,condition,notes)
    values (v_id,v_uid,v_prof.name,v_prof.email,b.id,b.request_id,b.component_id,b.name,q,v_cond,coalesce(trim(p_notes),''));
    perform public.notify('admin','New component return request',
      v_prof.name||' ('||v_prof.email||') submitted '||v_id||' to return '||q||' × '||b.name||' (reported condition: '||v_cond||'). Please acknowledge and verify the physical item.',
      v_id,'⟲');
    perform public.notify(v_uid::text,'Return request submitted','Your return request '||v_id||' is waiting for the admin to acknowledge it.', v_id,'⟲');
    perform public.log_activity('New return request', v_prof.name||' submitted '||v_id);
  end loop;
end $$;

-- 5.6 Admin acknowledges a return request (step 1 of 2)
create or replace function public.acknowledge_return(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare v_admin public.profiles; r public.returns;
begin
  if not public.is_admin() then raise exception 'Only administrators can do this.'; end if;
  select * into v_admin from public.profiles where id = auth.uid();
  select * into r from public.returns where id = p_id for update;
  if not found or r.status <> 'Return Pending' or r.processed then
    raise exception 'This return request cannot be acknowledged.';
  end if;
  update public.returns set status = 'Return Acknowledged', acknowledged_by = v_admin.name, acknowledged_at = now() where id = p_id;
  perform public.notify(r.user_id::text,'Return request acknowledged',
    'Your return request '||r.id||' was acknowledged by '||v_admin.name||'. Please hand over '||r.requested_quantity||' × '||r.name||' to the club admin for verification.',
    r.id,'⟲');
  perform public.log_activity('Return acknowledged', v_admin.name||' acknowledged '||r.id);
end $$;

-- 5.7 Admin verifies the physical item and approves the return (step 2 of 2)
--     Good items go back into available stock; damaged / needs-inspection items do not.
create or replace function public.confirm_return(p_id text, p_received int, p_condition text, p_remarks text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin public.profiles; r public.returns; b public.borrowings; comp public.inventory;
  v_status text; v_remarks text := coalesce(trim(p_remarks),'');
begin
  if not public.is_admin() then raise exception 'Only administrators can do this.'; end if;
  select * into v_admin from public.profiles where id = auth.uid();
  select * into r from public.returns where id = p_id for update;
  if not found or r.processed
     or r.status not in ('Return Acknowledged','Needs Review','Partially Returned') then
    raise exception 'This return cannot be approved yet. Acknowledge it first.';
  end if;
  if p_condition is null or p_condition not in ('Good','Needs Inspection','Damaged') then raise exception 'Invalid condition.'; end if;
  select * into b from public.borrowings where id = r.borrowing_id for update;
  if not found then raise exception 'Borrowing record not found.'; end if;
  select * into comp from public.inventory where id = r.component_id for update;
  if not found then raise exception 'Component no longer exists in inventory.'; end if;
  if p_received is null or p_received < 0 or p_received > r.requested_quantity or p_received > b.outstanding then
    raise exception 'Received quantity is invalid.';
  end if;

  v_status := case
    when p_condition in ('Damaged','Needs Inspection') then 'Needs Review'
    when p_received = r.requested_quantity then 'Return Confirmed'
    when p_received > 0 then 'Partially Returned'
    else 'Needs Review' end;

  if p_received > 0 then
    if b.issued = false then
      -- returned before the admin recorded the hand-over: stock was never deducted
      update public.borrowings set outstanding = outstanding - p_received, quantity = quantity - p_received,
             status = case when outstanding - p_received = 0 then 'Returned' else 'Approved' end where id = b.id;
      update public.request_items set approved = greatest(issued, approved - p_received)
       where request_id = b.request_id and component_id = b.component_id;
    else
      update public.borrowings set outstanding = outstanding - p_received,
             status = case when outstanding - p_received = 0 then 'Returned' else 'Borrowed' end where id = b.id;
      if p_condition = 'Good' then
        update public.inventory set available = least(total, available + p_received) where id = comp.id;
      end if;
    end if;
  end if;

  update public.returns set confirmed_quantity = p_received, condition = p_condition, admin_remarks = v_remarks,
         processed = (p_received > 0), status = v_status where id = p_id;

  perform public.notify(r.user_id::text,
    case v_status when 'Return Confirmed' then 'Component return confirmed' when 'Partially Returned' then 'Partial return recorded' else 'Return requires further action' end,
    'Return '||r.id||': '||p_received||' item(s) physically received. Status: '||v_status||'. '
      ||case when v_remarks <> '' then 'Admin note: '||v_remarks else '' end,
    r.id,'⟲');
  perform public.notify('admin','Return verification saved', r.id||' was updated for '||r.user_name||'.', r.id,'⟲');
  perform public.log_activity('Return verified', v_admin.name||' processed '||r.id);
end $$;

-- 5.8 Admin lifts a user's late-return restrictions (warnings, suspension, block)
create or replace function public.lift_restrictions(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_admin public.profiles; u public.profiles;
begin
  if not public.is_admin() then raise exception 'Only administrators can do this.'; end if;
  select * into v_admin from public.profiles where id = auth.uid();
  select * into u from public.profiles where id = p_user and role = 'user';
  if not found then raise exception 'User not found.'; end if;
  update public.profiles
     set late_return_level = 0, last_warning_at = null, suspended_until = null, inventory_blocked = false,
         warning_history = warning_history || jsonb_build_array(jsonb_build_object(
           'level',0,'date',public.ist_today(),'title','Restrictions lifted',
           'message','Restrictions were lifted by '||v_admin.name||'.'))
   where id = p_user;
  perform public.notify(p_user::text,'Borrowing restrictions lifted','Your borrowing access has been restored by '||v_admin.name||'.','','✓');
  perform public.log_activity('Restrictions lifted', v_admin.name||' lifted restrictions for '||u.name);
end $$;

-- 5.9 Daily overdue check (run by pg_cron on the server, never by browsers)
--     Warning 1 → (7 days) → Warning 2 + 2-week suspension → (after suspension) → permanent block
create or replace function public.check_overdue() returns void
language plpgsql security definer set search_path = public as $$
declare
  u public.profiles; v_names text; v_next int; v_title text; v_msg text; v_gap int; v_today date := public.ist_today();
begin
  for u in select * from public.profiles where role = 'user' and not inventory_blocked loop
    select string_agg(n, ', ') into v_names from (
      select distinct b.name as n from public.borrowings b
       where b.user_id = u.id and b.issued and b.returnable and b.outstanding > 0
         and b.due_date is not null and b.due_date < v_today
       order by 1 limit 5) s;
    if v_names is null then continue; end if;
    if u.late_return_level >= 3 then continue; end if;
    v_gap := case when u.late_return_level = 2 then 14 else 7 end;
    if u.late_return_level > 0 and u.last_warning_at is not null and v_today <= u.last_warning_at + v_gap then
      continue;
    end if;
    v_next := u.late_return_level + 1;
    if v_next = 1 then
      v_title := 'Warning 1: Component return overdue';
      v_msg := 'Your component return is overdue: '||v_names||'. Please return it immediately. If it is still not returned after 7 days, borrowing will be suspended for 2 weeks (Warning 2).';
    elsif v_next = 2 then
      v_title := 'Warning 2: Two-week borrowing suspension';
      v_msg := 'Your component return is still overdue: '||v_names||'. You cannot borrow any components for 2 weeks. You may still submit return requests. If the items are still not returned after the suspension, your inventory access will be permanently blocked.';
    else
      v_title := 'Inventory access permanently blocked';
      v_msg := 'Your component return remains overdue: '||v_names||'. Your inventory borrowing access is now permanently blocked. Contact the club administrator after returning the items.';
    end if;
    update public.profiles
       set late_return_level = v_next, last_warning_at = v_today,
           suspended_until = case when v_next = 2 then v_today + 14 else suspended_until end,
           inventory_blocked = (v_next = 3),
           warning_history = warning_history || jsonb_build_array(jsonb_build_object(
             'level',v_next,'date',v_today,'title',v_title,'message',v_msg))
     where id = u.id;
    perform public.notify(u.id::text, v_title, v_msg, '', case when v_next = 3 then '⛔' else '⚠' end);
    perform public.notify('admin', 'User '||v_title, u.name||' ('||u.email||') — '||v_msg, 'USR-'||u.id::text,
                          case when v_next = 3 then '⛔' else '⚠' end);
    perform public.log_activity(v_title, v_title||' issued to '||u.name||'.');
  end loop;
end $$;

-- run every day at 09:00 India time (03:30 UTC); re-running replaces the job
select cron.schedule('overdue-check', '30 3 * * *', 'select public.check_overdue()');

-- ---------------------------------------------------------------------
-- 6. Security: browsers may only do what is allowed below
-- ---------------------------------------------------------------------
alter table public.admin_emails    enable row level security;   -- no policies: invisible to browsers
alter table public.profiles        enable row level security;
alter table public.inventory       enable row level security;
alter table public.wishlist_items  enable row level security;
alter table public.requests        enable row level security;
alter table public.request_items   enable row level security;
alter table public.borrowings      enable row level security;
alter table public.returns         enable row level security;
alter table public.notifications   enable row level security;
alter table public.activity_log    enable row level security;

-- (select …) wrappers let Postgres evaluate auth.uid()/is_admin() once per query, not per row
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists inventory_read on public.inventory;
create policy inventory_read on public.inventory for select to authenticated using (true);
drop policy if exists inventory_admin_write on public.inventory;
drop policy if exists inventory_admin_insert on public.inventory;
drop policy if exists inventory_admin_update on public.inventory;
drop policy if exists inventory_admin_delete on public.inventory;
create policy inventory_admin_insert on public.inventory for insert to authenticated
  with check ((select public.is_admin()));
create policy inventory_admin_update on public.inventory for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy inventory_admin_delete on public.inventory for delete to authenticated
  using ((select public.is_admin()));

drop policy if exists wishlist_own on public.wishlist_items;
create policy wishlist_own on public.wishlist_items for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists requests_read on public.requests;
create policy requests_read on public.requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists request_items_read on public.request_items;
create policy request_items_read on public.request_items for select to authenticated
  using ((select public.is_admin())
         or exists(select 1 from public.requests r where r.id = request_id and r.user_id = (select auth.uid())));

drop policy if exists borrowings_read on public.borrowings;
create policy borrowings_read on public.borrowings for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists returns_read on public.returns;
create policy returns_read on public.returns for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists notifications_read on public.notifications;
create policy notifications_read on public.notifications for select to authenticated
  using (recipient = (select auth.uid())::text or (recipient = 'admin' and (select public.is_admin())));
drop policy if exists notifications_mark_read on public.notifications;
create policy notifications_mark_read on public.notifications for update to authenticated
  using (recipient = (select auth.uid())::text or (recipient = 'admin' and (select public.is_admin())))
  with check (recipient = (select auth.uid())::text or (recipient = 'admin' and (select public.is_admin())));

drop policy if exists activity_admin_read on public.activity_log;
create policy activity_admin_read on public.activity_log for select to authenticated using ((select public.is_admin()));

-- table privileges: start from nothing, then grant only what is needed
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on public.profiles, public.inventory, public.requests, public.request_items,
                public.borrowings, public.returns, public.notifications, public.activity_log to authenticated;
grant insert, update, delete on public.inventory to authenticated;               -- RLS: admins only
grant select, insert, update, delete on public.wishlist_items to authenticated;  -- RLS: own rows only
grant update (read) on public.notifications to authenticated;                    -- may only flip the read flag
-- the notify-email Edge Function (service_role) reads recipients and marks notifications as emailed
grant select on public.profiles to service_role;
grant select, update on public.notifications to service_role;

-- function privileges: only the functions the browser needs
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin()                                     to authenticated;
grant execute on function public.submit_request(text,text,date,text)            to authenticated;
grant execute on function public.cancel_request(text)                           to authenticated;
grant execute on function public.decide_request(text,text,text,jsonb)           to authenticated;
grant execute on function public.record_issue(text,date,date,jsonb)             to authenticated;
grant execute on function public.submit_return(jsonb,text)                      to authenticated;
grant execute on function public.acknowledge_return(text)                       to authenticated;
grant execute on function public.confirm_return(text,int,text,text)             to authenticated;
grant execute on function public.lift_restrictions(uuid)                        to authenticated;

-- stop functions created later in this schema from being callable by browsers by default
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
