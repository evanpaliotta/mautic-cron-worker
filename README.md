# Mautic Cron Worker

A separate Railway service that runs Mautic cron jobs for segment updates, campaign processing, email sending, and database backups.

**Version:** v5 (January 2026) - Fixed container stability and database resilience

## PRODUCTION MODE (Current Configuration)

This worker is configured in **PRODUCTION MODE**:
- Segments are updated every 5 minutes
- Contacts are added to campaigns from segments
- **EMAILS ARE SENT** (all trigger commands enabled)
- **DAILY BACKUPS** at 2 AM with 7-day rotation

## Required Environment Variables

The cron worker needs this variable set in Railway:

```
MYSQL_ROOT_PASSWORD=IfDvyzhQlghCluRzeklkbWUFiLwoqwLQ
```

## Cron Jobs

### Every 5 Minutes

| Command | Purpose | Status |
|---------|---------|--------|
| `mautic:segments:update` | Updates segment membership | ENABLED |
| `mautic:campaigns:rebuild` | Adds contacts to campaigns | ENABLED |
| `mautic:import` | Processes queued imports | ENABLED |
| `mautic:campaigns:trigger` | Triggers campaign actions (sends emails) | ENABLED |
| `mautic:messages:send` | Sends queued messages | ENABLED |
| `mautic:emails:send` | Sends scheduled emails | ENABLED |
| `mautic:broadcasts:send` | Sends broadcast emails | ENABLED |

### Daily/Weekly Maintenance

| Schedule | Command | Purpose |
|----------|---------|---------|
| 2 AM Daily | mysqldump | Database backup (7-day rotation) |
| 3 AM Sunday | mautic:iplookup:download | Update geo IP data |
| 4 AM Daily | mautic:maintenance:cleanup | Clean data older than 365 days |

## Backups

Backups are stored at `/var/www/html/var/backup-{dayname}.sql`

Files rotate weekly:
- `backup-Monday.sql`
- `backup-Tuesday.sql`
- ... etc

To restore from backup:
```bash
mysql -h mysql.railway.internal -u root -p railway < /var/www/html/var/backup-Monday.sql
```

## Deployment

Changes are deployed automatically via GitHub integration.

To manually redeploy:
```bash
cd /Users/evanpaliotta/Desktop/199OS\ GTM/09-email-sequencing/mautic-cron-worker
git add . && git commit -m "Update cron config" && git push
```

## Monitoring

Logs are stored in `/var/log/mautic/`:
- `segments.log` - Segment update logs
- `campaigns.log` - Campaign rebuild logs
- `import.log` - Import processing logs
- `trigger.log` - Campaign trigger logs
- `messages.log` - Message sending logs
- `emails.log` - Email sending logs
- `broadcasts.log` - Broadcast logs
- `backup.log` - Backup errors (if any)

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Container with cron + mysql-client |
| `crontab` | Scheduled job definitions |
| `supervisord.conf` | Process supervisor config |
| `railway.json` | Railway deployment config |

---

*See `/09-email-sequencing/MAUTIC-SETUP.md` for complete Mautic documentation.*
# Trigger rebuild Wed Jan 14 16:00:10 EST 2026
