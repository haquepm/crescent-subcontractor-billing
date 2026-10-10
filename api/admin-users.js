// Admin-only user, project assignment, and signature management.
// Requires SUPABASE_URL, SUPABASE_SECRET_KEY, and SUPABASE_ANON_KEY in Vercel server env.
const json = (res, status, body) => res.status(status).json(body);
const baseUrl = () => (process.env.SUPABASE_URL || '').replace(/\/$/, '');
async function rest(path, method='GET', body=null, prefer='') {
  const key = process.env.SUPABASE_SECRET_KEY;
  const r = await fetch(`${baseUrl()}/rest/v1/${path}`, {
    method,
    headers: {
      apikey: key, Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...(prefer ? {Prefer: prefer} : {})
    },
    ...(body === null ? {} : {body: JSON.stringify(body)})
  });
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) {
    const e = new Error(data?.message || data?.hint || 'Database operation failed.');
    e.status = r.status; throw e;
  }
  return data;
}
async function authContext(req) {
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) throw Object.assign(new Error('Sign in is required.'), {status:401});
  const auth = await fetch(`${baseUrl()}/auth/v1/user`, {
    headers: {apikey: process.env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}`}
  });
  if (!auth.ok) throw Object.assign(new Error('Your session is invalid. Sign in again.'), {status:401});
  const current = await auth.json();
  const rows = await rest(`user_profiles?select=user_id,is_admin,is_active,display_name,username&user_id=eq.${encodeURIComponent(current.id)}&limit=1`);
  const profile = rows?.[0];
  if (!profile || profile.is_active !== true) throw Object.assign(new Error('Your profile is inactive or missing.'), {status:403});
  return {user: current, profile, token};
}
async function requireAdmin(req) {
  const ctx = await authContext(req);
  if (ctx.profile.is_admin !== true) throw Object.assign(new Error('System Admin permission is required.'), {status:403});
  return ctx;
}
const safeUsername = s => typeof s === 'string' && /^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(s) && s.length <= 80;
const roles = new Set(['quantity_surveyor','site_engineer','project_manager','senior_quantity_surveyor','accounts','director']);
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (req.method !== 'POST') { res.setHeader('Allow','POST'); return json(res,405,{error:'Method not allowed.'}); }
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SECRET_KEY || !process.env.SUPABASE_ANON_KEY) return json(res,500,{error:'Admin service is not configured.'});
  try {
    const action = req.body?.action;
    if (action === 'signatures') {
      const ctx = await authContext(req);
      const billId = String(req.body?.billId || '');
      if (!/^[0-9a-f-]{36}$/i.test(billId)) return json(res,400,{error:'A valid bill ID is required.'});
      const bills = await rest(`ra_bills?select=id,subcontractor_id&id=eq.${encodeURIComponent(billId)}&limit=1`);
      if (!bills?.length) return json(res,404,{error:'Bill not found.'});
      const subs = await rest(`subcontractors?select=id,project_id&id=eq.${encodeURIComponent(bills[0].subcontractor_id)}&limit=1`);
      const projectId = subs?.[0]?.project_id;
      if (!projectId) return json(res,404,{error:'Bill project not found.'});
      if (ctx.profile.is_admin !== true) {
        const access = await rest(`project_assignments?select=user_id&project_id=eq.${encodeURIComponent(projectId)}&user_id=eq.${encodeURIComponent(ctx.user.id)}&is_active=eq.true&limit=1`);
        if (!access?.length) return json(res,403,{error:'You do not have access to this bill.'});
      }
      const approvals = await rest(`ra_bill_approvals?select=approval_round,stage,assigned_to,status,acted_at&ra_bill_id=eq.${encodeURIComponent(billId)}&order=approval_round.desc,stage_order.asc`);
      if (!approvals?.length) return json(res,200,{signatures:{}});
      const latestRound = Math.max(...approvals.map(a => Number(a.approval_round)||0));
      const approved = approvals.filter(a => Number(a.approval_round)===latestRound && a.status==='approved');
      const ids = [...new Set(approved.map(a=>a.assigned_to).filter(Boolean))];
      if (!ids.length) return json(res,200,{signatures:{}});
      const profiles = await rest(`user_profiles?select=user_id,display_name,username,signature_data_url&user_id=in.(${ids.join(',')})`);
      const byId = new Map(profiles.map(p=>[p.user_id,p]));
      const signatures = {};
      for (const a of approved) {
        const p = byId.get(a.assigned_to);
        signatures[a.stage] = {
          name: p?.display_name || p?.username || '',
          image: p?.signature_data_url || null,
          acted_at: a.acted_at || null
        };
      }
      return json(res,200,{signatures});
    }

    await requireAdmin(req);
    if (action === 'list') {
      const [profiles, projects, assignments] = await Promise.all([
        rest('user_profiles?select=user_id,username,display_name,is_admin,is_active,signature_data_url&order=display_name.asc'),
        rest('projects?select=id,name,is_active&order=name.asc'),
        rest('project_assignments?select=id,project_id,user_id,role,is_active&order=project_id.asc')
      ]);
      return json(res,200,{
        users:(profiles||[]).map(p=>({...p,has_signature:!!p.signature_data_url,signature_data_url:undefined})),
        projects:projects||[], assignments:assignments||[]
      });
    }
    if (action === 'create') {
      const {email,password,username,display_name,role,project_id} = req.body || {};
      const cleanEmail = typeof email==='string' ? email.trim().toLowerCase() : '';
      const cleanName = typeof display_name==='string' ? display_name.trim() : '';
      const cleanUsername = typeof username==='string' ? username.trim().toLowerCase() : '';
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail) || cleanEmail.length>254) return json(res,400,{error:'Enter a valid email address.'});
      if (typeof password!=='string' || password.length<12 || password.length>1024) return json(res,400,{error:'Temporary password must be at least 12 characters.'});
      if (!safeUsername(cleanUsername)) return json(res,400,{error:'Username must use lowercase letters, numbers, dots, underscores or hyphens.'});
      if (!cleanName || cleanName.length>120) return json(res,400,{error:'Enter a valid display name.'});
      if (!roles.has(role)) return json(res,400,{error:'Choose a valid project role.'});
      if (!/^[0-9a-f-]{36}$/i.test(String(project_id||''))) return json(res,400,{error:'Choose a project.'});
      const project = await rest(`projects?select=id&id=eq.${encodeURIComponent(project_id)}&is_active=eq.true&limit=1`);
      if (!project?.length) return json(res,400,{error:'Selected project is missing or inactive.'});
      const existing = await rest(`user_profiles?select=user_id&username=eq.${encodeURIComponent(cleanUsername)}&limit=1`);
      if (existing?.length) return json(res,409,{error:'That username is already in use.'});
      const createRes = await fetch(`${baseUrl()}/auth/v1/admin/users`,{
        method:'POST',
        headers:{apikey:process.env.SUPABASE_SECRET_KEY,Authorization:`Bearer ${process.env.SUPABASE_SECRET_KEY}`,'Content-Type':'application/json'},
        body:JSON.stringify({email:cleanEmail,password,email_confirm:true,user_metadata:{display_name:cleanName}})
      });
      const created = await createRes.json().catch(()=>null);
      if (!createRes.ok || !created?.id) return json(res,createRes.status||502,{error:created?.msg||created?.message||'Could not create authentication account.'});
      try {
        await rest('user_profiles','POST',{user_id:created.id,username:cleanUsername,display_name:cleanName,is_active:true,is_admin:false},'return=minimal');
        await rest('project_assignments','POST',{project_id,user_id:created.id,role,is_active:true},'return=minimal');
      } catch (e) {
        await fetch(`${baseUrl()}/auth/v1/admin/users/${encodeURIComponent(created.id)}`,{method:'DELETE',headers:{apikey:process.env.SUPABASE_SECRET_KEY,Authorization:`Bearer ${process.env.SUPABASE_SECRET_KEY}`}});
        throw e;
      }
      return json(res,201,{ok:true,user_id:created.id,username:cleanUsername});
    }
    if (action === 'assign') {
      const {user_id,project_id,role} = req.body || {};
      if (!/^[0-9a-f-]{36}$/i.test(String(user_id||'')) || !/^[0-9a-f-]{36}$/i.test(String(project_id||'')) || !roles.has(role)) return json(res,400,{error:'Select a valid user, project and role.'});
      const profiles = await rest(`user_profiles?select=user_id,is_active,is_admin&user_id=eq.${encodeURIComponent(user_id)}&limit=1`);
      if (!profiles?.length || profiles[0].is_active!==true || profiles[0].is_admin===true) return json(res,400,{error:'Choose an active non-admin user.'});
      const projects = await rest(`projects?select=id&id=eq.${encodeURIComponent(project_id)}&is_active=eq.true&limit=1`);
      if (!projects?.length) return json(res,400,{error:'Selected project is missing or inactive.'});
      const found = await rest(`project_assignments?select=user_id&project_id=eq.${encodeURIComponent(project_id)}&user_id=eq.${encodeURIComponent(user_id)}&limit=1`);
      if (found?.length) await rest(`project_assignments?project_id=eq.${encodeURIComponent(project_id)}&user_id=eq.${encodeURIComponent(user_id)}`,'PATCH',{role,is_active:true},'return=minimal');
      else await rest('project_assignments','POST',{project_id,user_id,role,is_active:true},'return=minimal');
      return json(res,200,{ok:true});
    }
    if (action === 'signature') {
      const {user_id,data_url} = req.body || {};
      if (!/^[0-9a-f-]{36}$/i.test(String(user_id||''))) return json(res,400,{error:'Select a user.'});
      if (typeof data_url!=='string' || data_url.length>2_000_000 || !/^data:image\/png;base64,[A-Za-z0-9+/=\r\n]+$/.test(data_url)) return json(res,400,{error:'Upload a PNG signature under approximately 1.5 MB.'});
      const profiles = await rest(`user_profiles?select=user_id,is_admin&user_id=eq.${encodeURIComponent(user_id)}&limit=1`);
      if (!profiles?.length || profiles[0].is_admin===true) return json(res,400,{error:'Choose a valid non-admin user.'});
      await rest(`user_profiles?user_id=eq.${encodeURIComponent(user_id)}`,'PATCH',{signature_data_url:data_url},'return=minimal');
      return json(res,200,{ok:true});
    }
    return json(res,400,{error:'Unknown admin action.'});
  } catch (e) {
    console.error('Admin API error:',e?.message||'unknown');
    return json(res,e.status||500,{error:e.status && e.status<500 ? e.message : 'Admin operation failed. Check server logs and database schema.'});
  }
}
