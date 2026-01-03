# Mautic Cron Worker

A separate Railway service that runs Mautic cron jobs for segment updates and campaign rebuilds.

## SAFE MODE (Current Configuration)

This worker is configured in **SAFE MODE**:
- Segments are updated every 5 minutes
- Contacts are added to campaigns from segments
- **NO EMAILS ARE SENT** (trigger commands are disabled)

## Deployment Instructions

### 1. Deploy to Railway

```bash
cd /Users/evanpaliotta/Desktop/199OS\ GTM/09-email-sequencing/mautic-cron-worker

# Login to Railway
railway login

# Link to Mautic project
railway link

# Deploy as a new service
railway up --service mautic-cron
```

### 2. Configure Environment Variables

The cron worker needs the same database connection as your main Mautic instance.
Copy these environment variables from your main Mautic service:

- `MAUTIC_DB_HOST`
- `MAUTIC_DB_NAME`
- `MAUTIC_DB_USER`
- `MAUTIC_DB_PASSWORD`
- `MAUTIC_SECRET_KEY`
- `MAUTIC_URL`

### 3. Verify Cron is Running

Check the logs in Railway dashboard or run:
```bash
railway logs --service mautic-cron
```

You should see output every 5 minutes showing segment and campaign updates.

## Enabling Email Sending

When you're ready to start sending emails, edit the `crontab` file and uncomment:

```cron
# Uncomment these lines:
*/5 * * * * www-data cd /var/www/html && php bin/console mautic:campaigns:trigger --env=prod
*/5 * * * * www-data cd /var/www/html && php bin/console mautic:messages:send --env=prod
*/5 * * * * www-data cd /var/www/html && php bin/console mautic:emails:send --env=prod
```

Then redeploy:
```bash
railway up --service mautic-cron
```

## Cron Jobs Explained

| Command | Frequency | Purpose | Status |
|---------|-----------|---------|--------|
| `mautic:segments:update` | Every 5 min | Updates segment membership | ENABLED |
| `mautic:campaigns:rebuild` | Every 5 min | Adds contacts to campaigns | ENABLED |
| `mautic:import` | Every 5 min | Processes queued imports | ENABLED |
| `mautic:campaigns:trigger` | Every 5 min | Triggers campaign actions (sends emails) | DISABLED |
| `mautic:messages:send` | Every 5 min | Sends queued messages | DISABLED |
| `mautic:emails:send` | Every 5 min | Sends scheduled emails | DISABLED |

## Monitoring

Logs are stored in `/var/log/mautic/`:
- `segments.log` - Segment update logs
- `campaigns.log` - Campaign rebuild logs
- `import.log` - Import processing logs
