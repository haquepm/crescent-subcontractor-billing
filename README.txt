Crescent Subcontractor Billing Portal - Username Login Update

Files:
- index.html: login form changed to username + password; all other app source retained.
- api/login.js: Vercel server-side username lookup and Supabase Auth login.

Required Vercel environment variables (server-side):
- SUPABASE_URL
- SUPABASE_SECRET_KEY (never expose this in index.html)
- SUPABASE_ANON_KEY

IMPORTANT:
1. Do not deploy this update until the System Admin profile has a username set in public.user_profiles.
2. Assign the existing System Admin username as 'admin' using a one-time SQL update:
   UPDATE public.user_profiles SET username = 'admin' WHERE user_id = '907ef723-9196-42d3-98e7-22bffc156f47' AND is_admin = true;
3. Verify the result before deployment.
4. Ensure all usernames are lowercase and unique.
5. Test admin login before creating staff accounts.
6. This function relies on Supabase Auth's password protection/rate limits. For production, add edge/WAF rate limiting and monitor Vercel logs.
7. No staff accounts are created by these files.
