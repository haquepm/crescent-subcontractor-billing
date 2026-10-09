// Vercel serverless function: username + password authentication via Supabase Auth.
// Required server-side environment variables: SUPABASE_URL, SUPABASE_SECRET_KEY, SUPABASE_ANON_KEY
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed.' });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!supabaseUrl || !secretKey || !anonKey) {
    return res.status(500).json({ error: 'Login service is not configured.' });
  }

  const username = typeof req.body?.username === 'string' ? req.body.username.trim().toLowerCase() : '';
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  // Current username convention: lowercase letters/numbers separated by dots, underscores or hyphens.
  if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(username) || username.length > 80 || !password || password.length > 1024) {
    return res.status(401).json({ error: 'Invalid username or password.' });
  }

  try {
    const base = supabaseUrl.replace(/\/$/, '');
    const profileUrl = new URL('/rest/v1/user_profiles', base);
    profileUrl.searchParams.set('select', 'user_id,is_active,username');
    profileUrl.searchParams.set('username', `eq.${username}`);
    profileUrl.searchParams.set('limit', '1');
    const profileResponse = await fetch(profileUrl, {
      headers: { apikey: secretKey, Authorization: `Bearer ${secretKey}` }
    });
    if (!profileResponse.ok) throw new Error('Profile lookup failed');
    const profiles = await profileResponse.json();
    const profile = profiles?.[0];
    if (!profile || !profile.is_active) {
      return res.status(401).json({ error: 'Invalid username or password.' });
    }

    const userResponse = await fetch(`${base}/auth/v1/admin/users/${encodeURIComponent(profile.user_id)}`, {
      headers: { apikey: secretKey, Authorization: `Bearer ${secretKey}` }
    });
    if (!userResponse.ok) throw new Error('Authentication account lookup failed');
    const authUser = await userResponse.json();
    if (!authUser?.email || authUser.id !== profile.user_id) {
      return res.status(401).json({ error: 'Invalid username or password.' });
    }

    const signInResponse = await fetch(`${base}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: anonKey },
      body: JSON.stringify({ email: authUser.email, password })
    });
    const session = await signInResponse.json().catch(() => null);
    if (!signInResponse.ok || !session?.access_token || !session?.refresh_token) {
      return res.status(401).json({ error: 'Invalid username or password.' });
    }

    return res.status(200).json({
      session: {
        access_token: session.access_token,
        refresh_token: session.refresh_token,
        expires_in: session.expires_in,
        token_type: session.token_type
      }
    });
  } catch (error) {
    // Keep internal details out of the response. Inspect Vercel function logs for diagnosis.
    console.error('Username login failed:', error?.message || 'unknown error');
    return res.status(500).json({ error: 'Unable to sign in right now. Please try again.' });
  }
}
