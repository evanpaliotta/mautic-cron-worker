# Mautic Cron Worker - PRODUCTION MODE
# Handles segment updates, campaign triggers, email sending, and daily backups
# Fixed: Creates local.php config before starting cron
FROM mautic/mautic:5-apache

# Install cron, supervisord, and mysql-client for backups
USER root
RUN apt-get update && apt-get install -y cron supervisor default-mysql-client && \
    rm -rf /var/lib/apt/lists/*

# Create cron job file (email sending ENABLED, daily backups at 2 AM)
COPY crontab /etc/cron.d/mautic-cron
RUN chmod 0644 /etc/cron.d/mautic-cron && \
    crontab /etc/cron.d/mautic-cron

# Create supervisord config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create log directories
RUN mkdir -p /var/log/mautic /var/log/supervisor && \
    chown -R www-data:www-data /var/log/mautic

# Create entrypoint script that sets up local.php before starting cron
RUN cat > /usr/local/bin/cron-entrypoint.sh << 'CRONENTRY'
#!/bin/bash
echo "=== Mautic Cron Worker Starting ==="

# Create local.php with database and mailer configuration from env vars
LOCAL_PHP="/var/www/html/config/local.php"
mkdir -p /var/www/html/config

echo "Creating Mautic local.php configuration..."
cat > "$LOCAL_PHP" << LOCALPHP
<?php
return array(
    'db_driver' => 'pdo_mysql',
    'db_host' => '${MAUTIC_DB_HOST}',
    'db_port' => '${MAUTIC_DB_PORT}',
    'db_name' => '${MAUTIC_DB_NAME}',
    'db_user' => '${MAUTIC_DB_USER}',
    'db_password' => '${MAUTIC_DB_PASSWORD}',
    'db_table_prefix' => null,
    'db_backup_tables' => true,
    'db_backup_prefix' => 'bak_',
    'mailer_dsn' => '${MAUTIC_MAILER_DSN}',
    'mailer_from_name' => '${MAUTIC_MAILER_FROM_NAME}',
    'mailer_from_email' => '${MAUTIC_MAILER_FROM_EMAIL}',
    'site_url' => 'https://mautic-production-3ceb.up.railway.app',
    'secret_key' => 'mautic_cron_worker_secret_key_199os',
);
LOCALPHP

chown www-data:www-data "$LOCAL_PHP"
chmod 644 "$LOCAL_PHP"

echo "Configuration created at $LOCAL_PHP"
echo "Database host: ${MAUTIC_DB_HOST}"

# Export environment variables so cron jobs can access them
printenv | grep -E '^(MAUTIC_|MYSQL_|RAILWAY_)' >> /etc/environment

# Clear Mautic cache
echo "Clearing Mautic cache..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>&1 || echo "Cache clear done"

echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
CRONENTRY

RUN chmod +x /usr/local/bin/cron-entrypoint.sh

# Use custom entrypoint that creates config before starting cron
ENTRYPOINT ["/usr/local/bin/cron-entrypoint.sh"]
CMD []
