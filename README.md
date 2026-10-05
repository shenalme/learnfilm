# Story to Screen: setup guide

A free online filmmaking course website (5 sections, 15 lessons, 5 quizzes) with accounts, progress tracking, a downloadable certificate and digital badge, certificate verification, and Film Academy enquiries. The backend is Supabase.

## What's in this folder

- `index.html`: the whole website (one file). Open it in a browser to try it in demo mode.
- `supabase/schema.sql`: database tables, security rules and functions for Supabase.

## 1. Create the Supabase project (about 10 minutes)

1. Sign up at supabase.com and create a new project. Choose the Singapore or Mumbai region (closest to Sri Lanka).
2. Open **SQL Editor > New query**, paste the whole of `supabase/schema.sql`, and click **Run**.
3. Open **Authentication > URL Configuration**:
   - **Site URL**: your website address, for example `https://learn.yourfilmacademy.lk/`
   - **Redirect URLs**: add the same address.
4. Open **Authentication > Sign In / Providers > Email**:
   - For the smoothest onboarding, turn **Confirm email** off. Students start lesson 2 the moment they sign up.
   - If you keep it on, students see a "check your email" screen and continue after clicking the link.
   - Before launch, set up custom SMTP (Authentication > Emails) so emails come from your own address. Supabase's built-in email service has a low hourly limit.
5. Optional: enable **Google** under Providers so students can sign up with one tap, then set `googleLogin: true` in `index.html`.

## 2. Connect the website

Open `index.html` and edit the `CONFIG` block near the top of the script:

```js
supabaseUrl: "https://xxxx.supabase.co",      // Project Settings > API > Project URL
supabaseAnonKey: "eyJ...",                     // Project Settings > API > anon public key
org: "The Film Academy",                       // your organisation name
academy: { location, nextIntake, format, outcome, email, phone }
```

The anon key is safe to put in a website; the security rules in `schema.sql` protect the data.

## 3. Put it online

Upload `index.html` to any static host: Netlify, Vercel, Cloudflare Pages, GitHub Pages or your existing web hosting. Netlify Drop (app.netlify.com/drop) is the quickest: drag the folder in. Then add the address to Supabase (step 1.3).

## 4. Adding lesson videos

Upload each video to YouTube (public or unlisted). In `index.html`, find the lesson and set its video ID, for example `video: "dQw4w9WgXcQ"`.

## 5. Where to find your students and Academy leads

In Supabase **SQL Editor**, run:

```sql
select * from admin.academy_leads;     -- everyone who asked about the Academy
select * from admin.student_funnel;    -- every student: progress, district, certificate, opt-in, film link
select * from admin.student_funnel where academy_optin and certificate_id is not null;  -- warmest leads
```

You can export any result as CSV. Update an enquiry's status (for example to `called` or `enrolled`) in **Table Editor > academy_enquiries**.

## How it's secured

- Students can only read and change their own data (row level security).
- Quizzes are graded in the database against an answer key students can't read.
- Certificates are issued by the database only when all 15 lessons are done and all 5 quizzes are passed.
- Anyone can verify a certificate ID at `yoursite/#/verify/STS-2026-XXXXXXXX`, which shows only the name and date.
- Academy enquiries can be sent by anyone but read only by your team.

## Editing the course

Lesson text and quizzes are in the `SECTIONS` list in `index.html`. If you change a lesson ID, add or remove lessons, or change a quiz's correct answer, update the seed section at the bottom of `schema.sql` to match and run it again. It's safe to re-run.

## Before launch

- Have native speakers review the Sinhala and Tamil interface text, and add translated lesson text.
- Replace the placeholder Academy details, signatory and contact information.
- Add a privacy notice, since many students will be under 18.
