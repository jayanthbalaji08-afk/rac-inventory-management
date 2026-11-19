# RAC Inventory Portal

Component inventory portal for the Robotics and Automation Club, Kumaraguru College.

**Live site:** https://effulgent-starburst-7588dc.netlify.app/

The website is `index.html` at the root of this repo (plus the logos and intro video). The backend is built on **[Supabase](https://github.com/supabase/supabase)** (open source:
PostgreSQL + Auth + Edge Functions). There is no separate server to run. The browser talks to Supabase directly,
and the database itself enforces every rule:

| Layer | What it does |
|---|---|
| **Auth** | Email + password sign-up, email confirmation, password reset. Only `@kct.ac.in` addresses are accepted. |
| **Row-level security** | Students see only their own profile, requests, borrowings, returns and notifications. Admins see everything. Only admins can add or edit inventory. |
| **Server functions** (`supabase.rpc`) | `submit_request`, `cancel_request`, `decide_request`, `record_issue`, `submit_return`, `acknowledge_return`, `confirm_return`, `lift_restrictions`. Each one checks who is calling, validates stock and quantities, and runs atomically. |
| **pg_cron job** | `check_overdue()` runs daily at 09:00 IST: Warning 1 → (7 days) Warning 2 + 2-week suspension → (after suspension) permanent block. |
| **Edge Function** `notify-email` | Emails every in-app notification over SMTP. |

```
rac-inventory-management/
├── index.html                    the website (Supabase URL + public anon key already filled in)
├── *.png, Video Project 9.mp4    logos and intro video
├── README.md
└── supabase/
    ├── config.toml                                    (CLI config: auth URLs, Gmail SMTP, rate limits)
    ├── migrations/20261118000000_inventory_schema.sql (the whole database)
    ├── migrations/20261119000000_email_webhook.sql    (emails every new notification)
    └── functions/notify-email/index.ts                (email sender)
```

**Updating the live site:** drag the website files (`index.html`, the images and the video) onto your site's **Deploys** page at app.netlify.com.
The inventory starts empty: admins add components from **Inventory → Add component**.

### What changed from the earlier `schema.sql` / `index.ts`
- **Email function can no longer be abused.** It used to email whatever title and message it was sent, so anyone holding the public anon key could send phishing mail from the club account. It now reads the notification from the database by id, and emails each one only once.
- **Admin rights are granted only after the email is confirmed**, not at sign-up. Adding an address to `admin_emails` later also promotes an existing confirmed account automatically.
- **Returns:** listing the same borrowing twice in one submission could return more than was borrowed. That is now rejected.
- **No duplicate ids** when two people with the same name submit at the same moment (advisory lock).
- Extra validation: the required date can't be in the past, the due date can't be before the issue date, and approve/reject only accepts known actions.
- RLS policies are written so Postgres evaluates `auth.uid()` and `is_admin()` once per query instead of once per row (faster).
- Re-running the migration on a database created from the old `schema.sql` upgrades it in place.

---

## Setup (about 30 minutes)

You need a Supabase account (free tier is fine) and a Gmail (or any SMTP) mailbox to send email from.

### 1. Create the project
1. https://supabase.com → **New project**. Choose the region closest to you (Mumbai) and save the database password.
2. **Database → Extensions** → enable **pg_cron**.

### 2. Create the database
1. Open `supabase/migrations/20261118000000_inventory_schema.sql` and check the admin emails near the top (`admin_emails`).
2. **SQL Editor → New query** → paste the whole file → **Run**.

   *CLI alternative:* `npx supabase login`, `npx supabase link --project-ref <your-ref>`, then `npx supabase db push`.

### 3. Login and confirmation emails
- **Authentication → Providers → Email**: enabled, **Confirm email ON**. This is what stops someone from claiming an admin address.
- **Authentication → URL Configuration**: set **Site URL** to where the portal is hosted, and add it to **Redirect URLs**.
- **Authentication → Emails → SMTP Settings**: turn on **custom SMTP** with the mailbox from step 4. The built-in sender only reaches project members, so students would never get their confirmation links without this.

### 4. Email notifications
1. Gmail: Google Account → Security → 2-Step Verification ON → **App passwords** → create one (16 characters).
2. Deploy the function, named exactly `notify-email`:
   - Dashboard: **Edge Functions → Deploy a new function → via Editor**, paste `supabase/functions/notify-email/index.ts`, Deploy. **or**
   - CLI: `npx supabase functions deploy notify-email`
3. **Edge Functions → Secrets** (or `npx supabase secrets set NAME=value`):

   | Secret | Example |
   |---|---|
   | `SMTP_HOST` | `smtp.gmail.com` |
   | `SMTP_PORT` | `465` |
   | `SMTP_USER` | `yourclub@gmail.com` |
   | `SMTP_PASS` | the 16-character app password |
   | `SMTP_FROM` | `Robotics and Automation Club <yourclub@gmail.com>` |
   | `PORTAL_URL` | the hosted portal address |

4. No dashboard webhook is needed: `migrations/20261119000000_email_webhook.sql` adds a database trigger (pg_net)
   that calls `notify-email` for every new notification. Run that file after the main schema.

### 5. Connect the portal
1. **Project Settings → API**: copy the **Project URL** and the **anon / publishable** key.
2. In `inventory-portal.html`, last `<script>` block, replace `PASTE_YOUR_SUPABASE_URL_HERE` and `PASTE_YOUR_SUPABASE_ANON_KEY_HERE`.
   The anon key is meant to be public; the database rules protect the data. **Never** put the `service_role` key in the HTML.
3. Keep the logo images and the intro video in the same folder as the HTML.

### 6. Host it
Any static host works: Netlify (drag the folder onto app.netlify.com/drop), GitHub Pages or Vercel.
Put the final address into **Site URL** (step 3) and `PORTAL_URL` (step 4).

### 7. First run
1. Each admin: **Admin Login → Create an account** with the listed `@kct.ac.in` email → click the confirmation link → sign in.
2. Students: **User Login → Create an account** → confirm by email → sign in.
3. End-to-end check: student requests → admin approves (the borrowing appears) → admin records issue (stock goes down) →
   student returns → admin acknowledges → admin approves the return (stock goes back up). Confirm the emails arrive.

---

## Admin tasks (SQL Editor)

```sql
-- add an admin (promotes them at once if they have already confirmed their account)
insert into admin_emails values ('name.24ec@kct.ac.in');

-- remove an admin
delete from admin_emails where email = 'name.24ec@kct.ac.in';
update profiles set role = 'user' where email = 'name.24ec@kct.ac.in';

-- recent activity
select * from activity_log order by at desc limit 50;
```

### Testing the late-return ladder without waiting
```sql
update borrowings set due_date = current_date - 3 where issued and returnable and outstanding > 0;
select public.check_overdue();                                                   -- Warning 1
update profiles set last_warning_at = current_date - 8  where late_return_level = 1;
select public.check_overdue();                                                   -- Warning 2 + suspension
update profiles set last_warning_at = current_date - 15 where late_return_level = 2;
select public.check_overdue();                                                   -- permanent block
```
Admins can undo this from a user's profile with **Lift restrictions**.

## Good to know
- The overdue check runs on the server, so warnings go out even if nobody opens the portal.
- The portal refreshes its data every 30 seconds while someone is signed in.
- Free-tier projects pause after about a week with no activity. The daily cron job and normal use keep the project awake.
- Gmail allows roughly 500 emails a day.
- Missing emails? Check **Edge Functions → notify-email → Logs** and **Database → Webhooks**. A notification whose email failed
  completely keeps `emailed_at = null`.
- Notifications older than 24 hours are never emailed, so old backlog cannot be re-sent.
