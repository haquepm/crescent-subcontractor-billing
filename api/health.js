
export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!supabaseUrl || !secretKey) {
    return res.status(500).json({
      ok: false,
      message: "Server environment variables are missing."
    });
  }

  try {
    const response = await fetch(
      `${supabaseUrl}/rest/v1/subcontractors?select=id&limit=1`,
      {
        method: "GET",
        headers: {
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`
        }
      }
    );

    if (!response.ok) {
      return res.status(502).json({
        ok: false,
        message: "Database connection failed.",
        status: response.status
      });
    }

    return res.status(200).json({
      ok: true,
      message: "Supabase connection successful."
    });
  } catch {
    return res.status(502).json({
      ok: false,
      message: "Unable to reach Supabase."
    });
  }
}
