// Vercel Cron → GitHub Actions workflow_dispatch trigger
// Runs daily in hour 05 UTC via vercel.json cron (Vercel fires it ~05:24 UTC); the workflow then waits until 11:20 IST
// Requires GITHUB_PAT env var in Vercel project settings (fine-grained token with Actions:write)

export default async function handler(req, res) {
  // Vercel cron sends GET requests with Authorization header
  // Verify it's a cron invocation or manual trigger
  const authHeader = req.headers['authorization'];
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}` && req.method !== 'GET') {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const token = process.env.GITHUB_PAT;
  if (!token) {
    return res.status(500).json({ error: 'GITHUB_PAT not configured' });
  }

  try {
    const response = await fetch(
      'https://api.github.com/repos/sanyamsingla-a11y/csp-metric-tracker/actions/workflows/daily_refresh.yml/dispatches',
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json',
        },
        // The workflow waits until 11:20 IST before querying, so the 11:00 IST CleverTap sync is in.
        body: JSON.stringify({ ref: 'master', inputs: { start_not_before_ist: '11:20' } }),
      }
    );

    if (response.status === 204) {
      console.log('Workflow triggered successfully');
      return res.status(200).json({
        success: true,
        message: 'GitHub Actions workflow triggered',
        timestamp: new Date().toISOString(),
      });
    } else {
      const body = await response.text();
      console.error(`GitHub API error: ${response.status} ${body}`);
      return res.status(response.status).json({
        success: false,
        status: response.status,
        error: body,
      });
    }
  } catch (err) {
    console.error('Failed to trigger workflow:', err);
    return res.status(500).json({ success: false, error: err.message });
  }
}
