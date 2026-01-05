# Mautic Cron Worker - PRODUCTION MODE
# Handles segment updates, campaign triggers, email sending, and daily backups
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

# Override entrypoint to skip Apache startup - we only need cron
ENTRYPOINT []

# Start supervisord (runs cron daemon only)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
