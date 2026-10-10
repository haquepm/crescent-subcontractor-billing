Crescent Subcontractor Billing Portal — Admin user/project/signature update

Included changes:
- Admin Portal navigation is visible only to profiles with is_admin = true.
- System Admin can create staff Auth accounts, create user_profiles, and assign an initial project role.
- System Admin can add/update a user's role on a selected project.
- System Admin can upload an authorized PNG signature for a staff user.
- Approved signature images are fetched server-side for the bill's latest approval round and shown on the A4 landscape RA Bill. Pending stages remain unsigned.
- Signature history/audit records remain in the database; the printed bill shows the signature blocks, not the approval-history table.
- New API: api/admin-users.js. It verifies the caller's Supabase access token and checks active System Admin profile for admin actions. It never sends the service key to the browser.

BEFORE DEPLOYMENT:
1. In Supabase SQL Editor, run:
   supabase/migrations/20261010_admin_user_signatures.sql
   This adds public.user_profiles.signature_data_url.
2. Confirm Vercel environment variables exist (server-side only):
   SUPABASE_URL
   SUPABASE_SECRET_KEY
   SUPABASE_ANON_KEY
3. Deploy the project to Vercel.
4. Sign in as System Admin and open Admin Portal.
5. Create or assign staff users; upload each authorized PNG signature.
6. Test with a non-production/test bill first, including approval and return scenarios.

SECURITY NOTES:
- Do not put SUPABASE_SECRET_KEY in index.html or any client-side environment variable.
- User creation is restricted to active System Admin profiles at the API.
- The API does not support creating System Admin accounts or assigning the admin role.
- PNG signatures are stored in user_profiles as data URLs and returned only through the protected signature API after checking the caller can access the bill's project. Because these are sensitive personal signature images, review RLS policies and restrict direct reads of signature_data_url. The browser should never select this column directly.
- Admin API service-key operations bypass RLS, so endpoint authorization is essential. Review Vercel logs and add rate limiting before broad production use.
- This package has a syntax-checked index.html and serverless endpoint, but the complete flow must still be tested against your actual Supabase schema and Vercel deployment before production use.
